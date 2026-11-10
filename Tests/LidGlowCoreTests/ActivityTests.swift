import Darwin
import Foundation
import LidGlowCore

final class ActivityChecks {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testOneCompletedSessionDoesNotHideAnotherWorkingSession() {
    let working = AgentSnapshot(
      source: "claude", sessionID: "one", state: .working, timestamp: now.timeIntervalSince1970)
    let complete = AgentSnapshot(
      source: "codex", sessionID: "two", state: .complete, timestamp: now.timeIntervalSince1970)
    Check.equal(ActivityReader.aggregate([working, complete], at: now), .working)
    let attention = AgentSnapshot(
      source: "claude", sessionID: "three", state: .attention, timestamp: now.timeIntervalSince1970)
    Check.equal(ActivityReader.aggregate([working, complete, attention], at: now), .attention)
  }

  func testMissingStopEventsExpireAndFinishSignalIsTemporary() {
    let stale = AgentSnapshot(
      source: "claude", sessionID: "one", state: .working,
      timestamp: now.timeIntervalSince1970 - 1801)
    Check.equal(stale.effectiveState(at: now), .stale)
    let done = AgentSnapshot(
      source: "codex", sessionID: "two", state: .complete, timestamp: now.timeIntervalSince1970 - 9)
    Check.equal(done.effectiveState(at: now), .idle)
  }

  func testReaderRejectsLinksOversizeAndInvalidSnapshots() throws {
    let folder = try canonicalFixtureFolder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let good = AgentSnapshot(
      source: "claude", sessionID: "one", state: .working, timestamp: now.timeIntervalSince1970)
    try JSONEncoder().encode(good).write(to: folder.appendingPathComponent("one.json"))
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("link.json"),
      withDestinationURL: folder.appendingPathComponent("one.json"))
    try Data(repeating: 32, count: 5000).write(to: folder.appendingPathComponent("huge.json"))
    let future = AgentSnapshot(
      source: "codex", sessionID: "two", state: .attention,
      timestamp: now.timeIntervalSince1970 + 600)
    try JSONEncoder().encode(future).write(to: folder.appendingPathComponent("future.json"))
    Check.equal(ActivityReader.snapshots(in: folder, now: now), [good])
    let directoryAlias = folder.appendingPathComponent("directory-alias")
    try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: folder)
    Check.equal(
      ActivityReader.snapshots(in: directoryAlias, now: now), [],
      "A valid spool through a directory symlink must still be rejected.")
    // Make sure Foundation has not silently turned the fixture back into a
    // Finder-friendly /var alias after files appeared in the directory.
    let canonical = realpath(folder.path, nil)
    defer { if let canonical { free(canonical) } }
    Check.equal(canonical.map { String(cString: $0) }, folder.path)
  }

  func testDuplicateSessionFilesUseNewestSnapshot() throws {
    let folder = try canonicalFixtureFolder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = AgentSnapshot(
      source: "claude", sessionID: "one", state: .working, timestamp: now.timeIntervalSince1970 - 1)
    let new = AgentSnapshot(
      source: "claude", sessionID: "one", state: .complete, timestamp: now.timeIntervalSince1970)
    try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("old.json"))
    try JSONEncoder().encode(new).write(to: folder.appendingPathComponent("new.json"))
    Check.equal(ActivityReader.snapshots(in: folder, now: now), [new])
  }

  private func canonicalFixtureFolder() throws -> URL {
    // On this macOS release Foundation's resolvingSymlinksInPath still returns
    // /var/folders. POSIX realpath supplies /private/var/folders, which does not
    // traverse the /var alias that the production reader deliberately rejects.
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved) + "/" + UUID().uuidString)
  }
}
