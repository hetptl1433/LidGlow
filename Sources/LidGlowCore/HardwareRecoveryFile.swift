import Darwin
import Foundation

/// Atomic minimal recovery data saved before the first hardware mutation. A killed
/// process cannot restore itself: the next explicit Connect/Restore uses this record.
/// Initialization only reads it; neither files nor hardware are changed at launch.
@MainActor
public final class HardwareRecoveryFile: HardwareRecoveryStore {
  private let url: URL
  private var ownershipFD: Int32?
  public init(url: URL) { self.url = url }
  deinit { if let ownershipFD { close(ownershipFD) } }
  private enum FileError: LocalizedError {
    case unsafe(String)
    var errorDescription: String? {
      if case .unsafe(let reason) = self { return "Unsafe hardware recovery data: \(reason)" }
      return nil
    }
  }
  public func acquireOwnership() throws {
    guard ownershipFD == nil else { return }
    guard url.isFileURL else { throw FileError.unsafe("not a local file URL") }
    let parent = (url.path as NSString).deletingLastPathComponent
    _ = try validateAncestors(allowMissing: true)
    try FileManager.default.createDirectory(
      atPath: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try validateAncestors(allowMissing: false) else {
      throw FileError.unsafe("missing ownership directory")
    }
    var parentInfo = stat()
    guard lstat(parent, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR,
      parentInfo.st_uid == getuid()
    else { throw FileError.unsafe("ownership directory is not owned") }
    let path = (parent as NSString).appendingPathComponent("hardware-owner.lock")
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FileError.unsafe("cannot open the ownership lock") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
      info.st_size == 0
    else {
      close(fd)
      throw FileError.unsafe("ownership lock is not a private, owned, empty regular file")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let reason = errno
      close(fd)
      if reason == EWOULDBLOCK {
        throw FileError.unsafe("another LidGlow instance owns the logo; release it there first")
      }
      throw FileError.unsafe("the ownership lock could not be acquired")
    }
    ownershipFD = fd
  }
  public func releaseOwnership() {
    guard let fd = ownershipFD else { return }
    ownershipFD = nil
    _ = flock(fd, LOCK_UN)
    close(fd)
    // Never unlink the lock file: all processes must lock the same inode.
  }
  public func load() throws -> HardwareRecovery? {
    guard url.isFileURL else { throw FileError.unsafe("not a local file URL") }
    guard try validateAncestors(allowMissing: true) else { return nil }
    // O_NONBLOCK prevents a hostile FIFO from blocking before fstat rejects it.
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw FileError.unsafe("cannot open the regular file (error \(errno))")
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
      info.st_size >= 0, info.st_size <= 4096
    else {
      throw FileError.unsafe("file ownership, permissions, type or size did not pass validation")
    }
    let data =
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097) ?? Data()
    guard data.count <= 4096 else { throw FileError.unsafe("record exceeds 4096 bytes") }
    let record = try JSONDecoder().decode(HardwareRecovery.self, from: data)
    guard record.isValid else {
      throw FileError.unsafe("unsupported version, mode or logical state")
    }
    return record
  }
  public func save(_ record: HardwareRecovery) throws {
    guard ownershipFD != nil else {
      throw FileError.unsafe("ownership must be acquired before saving recovery data")
    }
    guard url.isFileURL, record.isValid else {
      throw FileError.unsafe("invalid destination or record")
    }
    let parentPath = (url.path as NSString).deletingLastPathComponent
    _ = try validateAncestors(allowMissing: true)
    try FileManager.default.createDirectory(
      atPath: parentPath, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try validateAncestors(allowMissing: false) else {
      throw FileError.unsafe("parent does not exist")
    }
    var info = stat()
    guard lstat(parentPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid()
    else { throw FileError.unsafe("parent is not an owned directory") }
    _ = try load()  // Reject links, nonregular files, wrong owners and oversized data.
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public func clear() throws {
    guard ownershipFD != nil else {
      throw FileError.unsafe("ownership must be acquired before clearing recovery data")
    }
    guard try load() != nil else { return }
    try FileManager.default.removeItem(at: url)
  }
  private func validateAncestors(allowMissing: Bool) throws -> Bool {
    var path = "/"
    // Foundation standardization can rewrite /private/tmp to the /tmp symlink
    // once a file exists. Inspect the exact path; never normalize away a link.
    let components = url.pathComponents
    guard components.first == "/", !components.contains("."), !components.contains("..") else {
      throw FileError.unsafe("path must be absolute and contain no dot components")
    }
    for component in components.dropFirst().dropLast() {
      path = (path as NSString).appendingPathComponent(component)
      var info = stat()
      if lstat(path, &info) != 0 {
        if errno == ENOENT, allowMissing { return false }
        throw FileError.unsafe("ancestor metadata is unavailable")
      }
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw FileError.unsafe("ancestor is a link or not a directory")
      }
    }
    return true
  }
}
