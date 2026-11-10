import Darwin
import Foundation

public struct AgentSnapshot: Codable, Equatable {
  public let source: String
  public let session_id: String
  public let state: AgentState
  public let timestamp: Double

  public init(source: String, sessionID: String, state: AgentState, timestamp: Double) {
    self.source = source
    self.session_id = sessionID
    self.state = state
    self.timestamp = timestamp
  }

  public var id: String { source + ":" + session_id }

  public func isValid(at now: Date) -> Bool {
    ["claude", "codex", "custom"].contains(source) && !session_id.isEmpty && session_id.count <= 128
      && timestamp.isFinite && timestamp > 0 && timestamp <= now.timeIntervalSince1970 + 60
  }

  public func effectiveState(at now: Date, completionDuration: TimeInterval = 8) -> AgentState {
    let age = max(0, now.timeIntervalSince1970 - timestamp)
    if age > 1800 && (state == .working || state == .attention) { return .stale }
    let duration = completionDuration.isFinite ? min(86400, max(0, completionDuration)) : 8
    if state == .complete && age >= duration { return .idle }
    if state == .error && age > 30 { return .idle }
    return state
  }
}

public enum ActivityReader {
  /// Reads only small regular files in the expected local spool. Never follows links.
  public static func snapshots(in directory: URL, now: Date = Date()) -> [AgentSnapshot] {
    guard safeAncestors(directory) else { return [] }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return [] }
    guard let stream = fdopendir(fd) else {
      close(fd)
      return []
    }
    defer { closedir(stream) }
    var snapshots: [AgentSnapshot] = []
    var visited = 0
    var attempted = 0
    // Streaming bounds enumeration itself, not only JSON decoding afterwards.
    while visited < 4096, attempted < 512, let entry = readdir(stream) {
      visited += 1
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      guard !name.hasPrefix("."), name.hasSuffix(".json") else { continue }
      attempted += 1
      guard let data = readSnapshot(name, directory: fd),
        let snapshot = try? JSONDecoder().decode(AgentSnapshot.self, from: data),
        snapshot.isValid(at: now), now.timeIntervalSince1970 - snapshot.timestamp < 86400
      else { continue }
      snapshots.append(snapshot)
    }
    var unique: [String: AgentSnapshot] = [:]
    for snapshot in snapshots {
      if (unique[snapshot.id]?.timestamp ?? 0) < snapshot.timestamp {
        unique[snapshot.id] = snapshot
      }
    }
    return unique.values.sorted { $0.timestamp > $1.timestamp }
  }

  public static func aggregate(_ snapshots: [AgentSnapshot], at now: Date = Date()) -> AgentState {
    snapshots.map { $0.effectiveState(at: now) }.max(by: { $0.priority < $1.priority }) ?? .idle
  }

  private static func safeAncestors(_ url: URL) -> Bool {
    guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".")
    else { return false }
    var path = ""
    for component in url.pathComponents.dropFirst() {
      path += "/" + component
      var metadata = stat()
      if lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK { return false }
    }
    return true
  }

  private static func readSnapshot(_ name: String, directory: Int32) -> Data? {
    // Nonblocking open and descriptor validation close the check/open race:
    // a replaced symlink/FIFO must never block the application's main thread.
    let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(), metadata.st_size >= 0, metadata.st_size <= 4096
    else { return nil }
    var buffer = [UInt8](repeating: 0, count: 4097)
    let length = read(fd, &buffer, buffer.count)
    guard length >= 0, length <= 4096 else { return nil }
    return Data(buffer.prefix(length))
  }
}
