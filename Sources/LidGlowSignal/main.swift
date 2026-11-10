import CryptoKit
import Darwin
import Foundation

// Short-lived, local-only activity writer. Every failure deliberately exits zero:
// a status light must never decide or block a coding agent's actions.
private let maxInput = 1_048_576
private let maxSnapshots = 256
private let sources = Set(["claude", "codex", "custom"])
private let states = Set(["working", "attention", "complete", "idle", "error"])
private let fm = FileManager.default

private enum SignalError: Error { case invalid, unavailable }

private struct Arguments {
  var source: String
  var state: String
  var session: String?
  var readsInput: Bool
  var preserveFinish: Bool
}

// Decode only the one allowed input field. Tool arguments, prompts and other
// payload values are never materialized as an application object graph.
private struct Incoming: Decodable { let session_id: String }

private func arguments() -> Arguments? {
  let input = Array(CommandLine.arguments.dropFirst())
  guard let command = input.first, command == "event" || command == "emit" else { return nil }
  var values: [String: String] = [:]
  var preserveFinish = false
  var index = 1
  while index < input.count {
    if input[index] == "--lidglow-hook" {
      index += 1
      continue
    }
    if input[index] == "--preserve-finish" {
      preserveFinish = true
      index += 1
      continue
    }
    let split = input[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let option = String(split[0])
    let value: String
    if split.count == 2 {
      value = String(split[1])
      index += 1
    } else {
      guard index + 1 < input.count else { return nil }
      value = input[index + 1]
      index += 2
    }
    guard ["--source", "--state", "--session"].contains(option),
      option != "--session" || command == "emit"
    else { return nil }
    values[option] = value
  }
  guard let source = values["--source"], sources.contains(source),
    let state = values["--state"], states.contains(state)
  else { return nil }
  return Arguments(
    source: source, state: state,
    session: command == "emit" ? (values["--session"] ?? "default") : nil,
    readsInput: command == "event", preserveFinish: preserveFinish)
}

private func safePath(_ url: URL) throws {
  var current = URL(fileURLWithPath: "/", isDirectory: true)
  // Foundation's standardizedFileURL can rewrite /private/var as /var, which
  // is itself a symlink on macOS. Inspect the actual supplied components.
  for component in url.pathComponents.dropFirst() {
    guard component != ".", component != ".." else { throw SignalError.invalid }
    current.appendPathComponent(component)
    var info = stat()
    if lstat(current.path, &info) == 0 {
      guard (info.st_mode & S_IFMT) != S_IFLNK else { throw SignalError.invalid }
    } else if errno != ENOENT {
      throw SignalError.unavailable
    }
  }
}

private func ensureDirectory(_ url: URL) throws {
  try safePath(url)
  try fm.createDirectory(
    at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try safePath(url)
  var info = stat()
  guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
    throw SignalError.invalid
  }
}

private func smallFile(_ url: URL, limit: Int = 4096) throws -> Data {
  try safePath(url)
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard fd >= 0 else { throw SignalError.unavailable }
  defer { close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
    info.st_nlink == 1,
    info.st_size >= 0, info.st_size <= limit
  else { throw SignalError.invalid }
  var content = Data()
  var buffer = [UInt8](repeating: 0, count: min(limit + 1, 4096))
  while content.count <= limit {
    let count = read(fd, &buffer, min(buffer.count, limit + 1 - content.count))
    if count < 0 {
      if errno == EINTR { continue }
      throw SignalError.unavailable
    }
    if count == 0 { return content }
    content.append(buffer, count: count)
  }
  throw SignalError.invalid
}

private func readInput() throws -> Data {
  let deadline = ProcessInfo.processInfo.systemUptime + 0.5
  var content = Data()
  var buffer = [UInt8](repeating: 0, count: 65536)
  while content.count <= maxInput {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else { throw SignalError.unavailable }
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
    if ready < 0, errno == EINTR { continue }
    guard ready > 0 else { throw SignalError.unavailable }
    let count = read(STDIN_FILENO, &buffer, min(buffer.count, maxInput + 1 - content.count))
    if count < 0 {
      if errno == EINTR { continue }
      throw SignalError.unavailable
    }
    if count == 0 { return content }
    content.append(buffer, count: count)
  }
  throw SignalError.invalid
}

private func locked<T>(_ directory: URL, body: (Int32, stat) throws -> T) throws -> T {
  let url = directory.appendingPathComponent(".lidglow.lock")
  try safePath(url)
  let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
  guard fd >= 0 else { throw SignalError.unavailable }
  defer { close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
    throw SignalError.invalid
  }
  let deadline = ProcessInfo.processInfo.systemUptime + 0.25
  while flock(fd, LOCK_EX | LOCK_NB) != 0 {
    guard errno == EWOULDBLOCK || errno == EAGAIN,
      ProcessInfo.processInfo.systemUptime < deadline
    else { throw SignalError.unavailable }
    usleep(5_000)
  }
  guard fstat(fd, &info) == 0 else { throw SignalError.unavailable }
  return try body(fd, info)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
  try safePath(url)
  var existing = stat()
  if lstat(url.path, &existing) == 0,
    (existing.st_mode & S_IFMT) != S_IFREG || existing.st_nlink != 1
  {
    throw SignalError.invalid
  }
  let temporary = url.deletingLastPathComponent().appendingPathComponent(
    ".lidglow-" + UUID().uuidString)
  let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard fd >= 0 else { throw SignalError.unavailable }
  var descriptorOpen = true
  defer {
    if descriptorOpen { close(fd) }
    unlink(temporary.path)
  }
  try data.withUnsafeBytes { bytes in
    guard let base = bytes.baseAddress else { throw SignalError.invalid }
    var offset = 0
    while offset < bytes.count {
      let count = write(fd, base.advanced(by: offset), bytes.count - offset)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw SignalError.unavailable }
      offset += count
    }
  }
  // These are ephemeral signals, so no disk-wide fsync is needed. Closing the
  // complete private file before rename still guarantees readers see full JSON.
  guard close(fd) == 0 else {
    descriptorOpen = false
    throw SignalError.unavailable
  }
  descriptorOpen = false
  try safePath(url)
  guard rename(temporary.path, url.path) == 0 else { throw SignalError.unavailable }
}

private func prune(_ directory: URL, now: Double, keeping destination: URL) {
  guard let stream = opendir(directory.path) else { return }
  defer { closedir(stream) }
  var files: [(Double, String)] = []
  let deadline = ProcessInfo.processInfo.systemUptime + 0.1
  // Normal use holds at most 256 snapshots. Bound work if another same-user
  // process fills this private directory with unrelated files.
  var visited = 0
  while let entry = readdir(stream), visited < 4096 {
    visited += 1
    if ProcessInfo.processInfo.systemUptime > deadline { break }
    let name = withUnsafePointer(to: &entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
    }
    guard !name.hasPrefix("."), name.hasSuffix(".json") else { continue }
    let path = directory.appendingPathComponent(name).path
    if path == destination.path { continue }
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
    let modified =
      Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    if now - modified > 86400 { unlink(path) } else { files.append((modified, path)) }
  }
  for file in files.sorted(by: { $0.0 < $1.0 }).prefix(max(0, files.count - (maxSnapshots - 1))) {
    unlink(file.1)
  }
}

private func run() throws {
  guard let args = arguments() else { return }
  let session: String
  if args.readsInput {
    session = try JSONDecoder().decode(Incoming.self, from: readInput()).session_id
  } else {
    session = args.session ?? "default"
  }
  guard !session.isEmpty, session.unicodeScalars.count <= 4096 else { return }
  let hash = SHA256.hash(data: Data(session.utf8)).prefix(12).map { String(format: "%02x", $0) }
    .joined()
  let environment = ProcessInfo.processInfo.environment
  let home =
    environment["LIDGLOW_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? fm.homeDirectoryForCurrentUser
  let dataDirectory =
    environment["LIDGLOW_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? home.appendingPathComponent("Library/Application Support/LidGlow", isDirectory: true)
  let directory = dataDirectory.appendingPathComponent("events", isDirectory: true)
  try ensureDirectory(directory)
  let destination = directory.appendingPathComponent(args.source + "-" + hash + ".json")
  let now = Date().timeIntervalSince1970
  try locked(directory) { lock, lockInfo in
    var isNew = true
    var info = stat()
    if lstat(destination.path, &info) == 0 { isNew = false }
    if let data = try? smallFile(destination),
      let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      previous["source"] as? String == args.source, previous["session_id"] as? String == hash,
      let old = previous["timestamp"] as? Double, old.isFinite
    {
      // SessionEnd often follows Stop immediately. Keep the original finish
      // and time so the app can apply its configured completion duration.
      if args.preserveFinish, args.state == "idle", old > 0, old <= now + 60, now - old < 86400,
        let state = previous["state"] as? String, state == "complete" || state == "error"
      {
        return
      }
      if now < old && old <= now + 60 { return }
      if args.state == "working", previous["state"] as? String == args.state, now - old >= 0,
        now - old < 30
      {
        return
      }
    }
    let snapshot: [String: Any] = [
      "source": args.source, "session_id": hash, "state": args.state, "timestamp": now,
    ]
    let content = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    try atomicWrite(content, to: destination)
    let lastPrune = Double(lockInfo.st_mtimespec.tv_sec)
    if isNew || lockInfo.st_size == 0 || now - lastPrune >= 60 {
      prune(directory, now: now, keeping: destination)
      var marker: UInt8 = 1
      _ = ftruncate(lock, 0)
      _ = write(lock, &marker, 1)
    }
  }
}

do { try run() } catch { /* Deliberately silent and non-blocking on failure. */  }
