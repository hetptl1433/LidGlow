import Darwin
import Foundation
import LidGlowCore

/// Integration checks of the production kernel watcher, not a fake scheduler.
/// All files live in a canonical temporary directory; no user data is accessed.
@MainActor
enum DirectoryObserverChecks {
  static func runAll() {
    Check.run("Directory watcher coalesces an actual atomic-write burst", testAtomicWriteBurst)
    Check.run(
      "Directory rename/delete recreation observes completion promptly", testRecreatedDirectory)
    Check.run(
      "Stopping directory observation cancels queued debounce and retry",
      testStopSuppressesCallbacks)
    Check.run(
      "Directory watcher rejects symlinks without changing their target", testSymlinkRejection)
  }

  private static func testAtomicWriteBurst() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let events = root.appendingPathComponent("events")
    var callbacks = 0
    var observed = 0
    let watcher = DirectoryObserver(directory: events) {
      callbacks += 1
      observed = ActivityReader.snapshots(in: events).count
    }
    defer { watcher.stop() }
    for i in 0..<24 { try writeSnapshot(to: events, session: "burst-\(i)", state: .working) }
    Check.isTrue(
      pump(until: { observed == 24 }, timeout: 2.5),
      "Actual directory events did not deliver the complete burst.")
    pump(for: 0.2)
    Check.isTrue(
      callbacks >= 1 && callbacks <= 3,
      "24 atomic writes produced \(callbacks) callbacks; expected coalescing.")
    Check.equal(observed, 24)
  }

  private static func testRecreatedDirectory() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let events = root.appendingPathComponent("events")
    var completed: Set<String> = []
    let watcher = DirectoryObserver(directory: events) {
      for row in ActivityReader.snapshots(in: events) where row.state == .complete {
        completed.insert(row.session_id)
      }
    }
    defer { watcher.stop() }
    // A retained descriptor observes the old inode after rename. The production
    // parent watch/fast retry must discover this newly created events directory.
    try FileManager.default.moveItem(at: events, to: root.appendingPathComponent("events.old"))
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
    try writeSnapshot(to: events, session: "after-rename", state: .complete)
    Check.isTrue(
      pump(until: { completed.contains("after-rename") }, timeout: 2.5),
      "Rename/recreate completion was missed; the old 30-second retry would fail here.")

    try FileManager.default.removeItem(at: events)
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
    try writeSnapshot(to: events, session: "after-delete", state: .complete)
    Check.isTrue(
      pump(until: { completed.contains("after-delete") }, timeout: 2.5),
      "Delete/recreate completion was missed.")
    // Ensure the replacement is actually watched after rearming, rather than
    // only being read by the one retry callback.
    pump(for: 0.2)
    try writeSnapshot(to: events, session: "on-replacement", state: .complete)
    Check.isTrue(
      pump(until: { completed.contains("on-replacement") }, timeout: 2.5),
      "The replacement directory was not armed.")
  }

  private static func testStopSuppressesCallbacks() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let events = root.appendingPathComponent("events")
    var callbacks = 0
    let watcher = DirectoryObserver(directory: events) { callbacks += 1 }
    try writeSnapshot(to: events, session: "queued", state: .working)
    pump(for: 0.025)  // DispatchSource delivery queues the 100 ms debounce.
    watcher.stop()
    pump(for: 0.25)
    Check.equal(callbacks, 0, "A pending debounce escaped stop().")
    try writeSnapshot(to: events, session: "after-stop", state: .complete)
    pump(for: 0.15)
    Check.equal(callbacks, 0)

    let retryEvents = root.appendingPathComponent("retry-events")
    let retryWatcher = DirectoryObserver(directory: retryEvents) { callbacks += 1 }
    try FileManager.default.moveItem(at: retryEvents, to: root.appendingPathComponent("retry-old"))
    pump(for: 0.025)  // Removal has queued the short rearm retry.
    retryWatcher.stop()
    pump(for: 0.25)
    Check.equal(callbacks, 0, "A pending retry escaped stop().")
    Check.isTrue(
      !FileManager.default.fileExists(atPath: retryEvents.path),
      "A stopped retry recreated its directory.")
  }

  private static func testSymlinkRejection() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let sentinel = target.appendingPathComponent("sentinel")
    try Data("unchanged".utf8).write(to: sentinel)
    let alias = root.appendingPathComponent("events")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    var callbacks = 0
    let watcher = DirectoryObserver(directory: alias) { callbacks += 1 }
    defer { watcher.stop() }
    pump(for: 0.2)
    Check.equal(callbacks, 0)
    Check.equal(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
    Check.equal(try FileManager.default.contentsOfDirectory(atPath: target.path), ["sentinel"])
    // Ancestor symlinks are rejected as well as the final directory component.
    let nested = DirectoryObserver(directory: alias.appendingPathComponent("nested")) {
      callbacks += 1
    }
    defer { nested.stop() }
    pump(for: 0.15)
    Check.isTrue(
      !FileManager.default.fileExists(atPath: target.appendingPathComponent("nested").path))
    Check.equal(callbacks, 0)
  }

  private static func fixtureRoot() throws -> URL {
    guard let real = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    defer { free(real) }
    let root = URL(fileURLWithPath: String(cString: real) + "/lidglow-watch-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return root
  }
  private static func writeSnapshot(to events: URL, session: String, state: AgentState) throws {
    let snapshot = AgentSnapshot(
      source: "custom", sessionID: session, state: state,
      timestamp: Date().timeIntervalSince1970)
    try JSONEncoder().encode(snapshot).write(
      to: events.appendingPathComponent(session + ".json"), options: .atomic)
  }
  @discardableResult
  private static func pump(until condition: () -> Bool, timeout: Double) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }
  private static func pump(for duration: Double) {
    let deadline = ProcessInfo.processInfo.systemUptime + duration
    while ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
  }
}
