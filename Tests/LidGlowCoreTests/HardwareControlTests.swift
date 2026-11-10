import Darwin
import Foundation
import LidGlowCore

/// All writes below go to a fake daemon, never to CoreBrightness.
@MainActor
enum HardwareControlChecks {
  static func runAll() {
    Check.run(
      "Hardware construction and invalid preconditions make no writes", testReadOnlyAndPreconditions
    )
    Check.run("Recovery-save failure prevents the first hardware write", testRecoverySaveFailure)
    Check.run("Settled hardware consumes zero backend polls", testNoSteadyPolling)
    Check.run(
      "Rapid reversal, endpoints and bounded finite requests settle", testReversalsAndEndpoints)
    Check.run("Accepted-but-ignored mode and fade commands fail closed", testIgnoredCommands)
    Check.run(
      "Rejected property writes stop work and preserve a retryable recovery", testRejectedWrites)
    Check.run(
      "Lost factor readback fails release verification and recovers on retry", testLostReadback)
    Check.run("Keyboard correction failure stops control and retains recovery", testKeyboardFailure)
    Check.run(
      "Sleep during a fade clears holds and never relights the keyboard", testSleepDuringFade)
    Check.run("Repeated sleep/wake preserves original disabled mode", testRepeatedSleepWake)
    Check.run("Wake readiness retries without losing ownership intent", testWakeReadiness)
    Check.run(
      "Wake during release verification resumes without an animation timer", testWakeDuringRelease)
    Check.run(
      "Release verifies factor, detects a stuck hold and permits retry", testReleaseVerification)
    Check.run("Forced-exit recovery is explicit and does not write at launch", testCrashRecovery)
    Check.run("Disconnect stops animation requests from reacquiring hardware", testDisconnect)
    Check.run(
      "Recovery files reject symlinks, FIFOs, hard links and corrupt data", testRecoveryFiles)
    Check.run(
      "Concurrent controllers cannot write, restore or steal suspended ownership",
      testConcurrentControllers)
    Check.run("Actual recovery stores use a nonblocking stable ownership lock", testFileOwnership)
  }

  private static func testReadOnlyAndPreconditions() throws {
    let backend = FakeHardwareBackend()
    let control = HardwareControl(backend: backend)
    Check.equal(backend.calls, 0)
    Check.equal(backend.writes.count, 0)
    backend.awake = false
    Check.throwsError(try control.connect(now: 0))
    Check.equal(backend.writes.count, 0)
    backend.awake = true
    backend.mode = 1
    Check.throwsError(try control.connect(now: 0))
    Check.equal(backend.writes.count, 0)
    backend.mode = 2
    backend.factorAvailable = false
    Check.throwsError(try control.connect(now: 0))
    Check.equal(backend.writes.count, 0)
  }

  private static func testRecoverySaveFailure() throws {
    let backend = FakeHardwareBackend()
    let recovery = FakeHardwareRecovery()
    recovery.rejectSave = true
    let control = HardwareControl(backend: backend, recoveryStore: recovery)
    Check.throwsError(try control.connect(now: 0))
    Check.equal(backend.writes.count, 0)
    Check.isTrue(!control.isControlling)
  }

  private static func testNoSteadyPolling() throws {
    let b = FakeHardwareBackend()
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    c.requestBrightness(0.4, now: 0)
    drive(c, b)
    Check.equal(c.nextPollDelay, nil)
    Check.isTrue(abs(b.currentFactor - 0.4) < 0.07)
    let calls = b.calls
    let writes = b.writes.count
    for i in 1...10_000 {
      c.requestBrightness(0.4, now: Double(i))
      c.advance(now: Double(i))
    }
    Check.equal(b.calls, calls, "A stable target must cause no XPC/display probes.")
    Check.equal(b.writes.count, writes)
    c.requestBrightness(1, now: b.time)
    drive(c, b)
    let endpointCalls = b.calls
    for i in 1...1_000 {
      c.requestBrightness(1, now: Double(i))
      c.advance(now: Double(i))
    }
    Check.equal(b.calls, endpointCalls)
  }

  private static func testReversalsAndEndpoints() throws {
    let b = FakeHardwareBackend()
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    var seed: UInt64 = 77123
    for _ in 0..<300 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      let target = Double(seed >> 32) / Double(UInt32.max)
      c.requestBrightness(target, now: b.time)
      b.time += 0.03
      c.advance(now: b.time)
      Check.isTrue(b.currentFactor.isFinite && (0...1).contains(b.currentFactor))
    }
    c.requestBrightness(.nan, now: b.time)
    c.requestBrightness(.infinity, now: b.time)
    for target in [0.7, 0.25, 0.8, 0.01, 0, 0.99, 1] {
      c.requestBrightness(target, now: b.time)
      drive(c, b)
      Check.isTrue(c.isControlling, c.status)
      Check.equal(c.nextPollDelay, nil)
      b.time += 0.5  // The final native endpoint fade completes unpolled.
      Check.isTrue(
        abs(b.currentFactor - target) < (target == 0 || target == 1 ? 0.005 : 0.07),
        "target \(target), factor \(b.currentFactor)")
    }
  }

  private static func testIgnoredCommands() throws {
    let modeBackend = FakeHardwareBackend(mode: 0)
    modeBackend.ignored.insert(.mode)
    let c = HardwareControl(backend: modeBackend)
    Check.throwsError(try c.connect(now: 0))
    Check.isTrue(!c.isControlling)
    let b = FakeHardwareBackend()
    let recovery = FakeHardwareRecovery()
    let stalled = HardwareControl(backend: b, recoveryStore: recovery)
    try stalled.connect(now: 0)
    b.freezeFactor = true
    stalled.requestBrightness(0.3, now: 0)
    drive(stalled, b, limit: 4)
    Check.isTrue(!stalled.isControlling)
    Check.equal(stalled.nextPollDelay, nil)
    Check.isTrue(stalled.status.contains("restored") || stalled.status.contains("confirmed"))
  }

  private static func testKeyboardFailure() throws {
    let b = FakeHardwareBackend()
    let recovery = FakeHardwareRecovery()
    let c = HardwareControl(backend: b, recoveryStore: recovery)
    try c.connect(now: 0)
    b.rejectKeyboard = true
    c.requestBrightness(0.3, now: 0)
    drive(c, b)
    Check.isTrue(!c.isControlling)
    Check.isTrue(c.hasPendingRecovery)
    Check.isTrue(recovery.record != nil)
    Check.equal(c.nextPollDelay, nil)
    b.rejectKeyboard = false
    c.restore(now: b.time)
    drive(c, b)
    Check.equal(recovery.record, nil)
  }

  private static func testRejectedWrites() throws {
    for property in [HardwareProperty.mode, .duration, .logical] {
      let b = FakeHardwareBackend(mode: 0)
      let recovery = FakeHardwareRecovery()
      let c = HardwareControl(backend: b, recoveryStore: recovery)
      if property == .mode {
        b.rejected.insert(property)
        Check.throwsError(try c.connect(now: 0))
      } else {
        try c.connect(now: 0)
        b.rejected.insert(property)
        c.requestBrightness(0.3, now: 0)
        drive(c, b)
      }
      Check.isTrue(!c.isControlling)
      Check.isTrue(c.hasPendingRecovery)
      Check.equal(c.nextPollDelay, nil)
      b.rejected.removeAll()
      c.restore(now: b.time)
      drive(c, b)
      Check.equal(b.mode, 0)
      Check.equal(recovery.record, nil)
      Check.equal(b.duration, 0)
    }
  }

  private static func testLostReadback() throws {
    let b = FakeHardwareBackend()
    let recovery = FakeHardwareRecovery()
    let c = HardwareControl(backend: b, recoveryStore: recovery)
    try c.connect(now: 0)
    c.requestBrightness(0.4, now: 0)
    b.factorAvailable = false
    drive(c, b)
    Check.isTrue(!c.isControlling && c.hasPendingRecovery)
    Check.equal(c.nextPollDelay, nil)
    b.factorAvailable = true
    c.restore(now: b.time)
    drive(c, b)
    Check.equal(recovery.record, nil)
    Check.isTrue(c.diagnosticSummary.contains("logical 2"))
  }

  private static func testSleepDuringFade() throws {
    let b = FakeHardwareBackend()
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    c.requestBrightness(0.2, now: 0)
    b.time = 0.03
    c.advance(now: b.time)
    b.awake = false
    let count = b.writes.count
    b.time = 0.06
    c.advance(now: b.time)
    Check.isTrue(!c.isControlling && c.isSuspended)
    Check.equal(c.nextPollDelay, nil)
    Check.equal(b.duration, 0)
    Check.equal(b.lightLogical, 1)
    Check.isTrue(!b.writes.dropFirst(count).contains("keyboard:2"))
    let reads = b.calls
    c.advance(now: 100)
    Check.equal(b.calls, reads)
  }

  private static func testRepeatedSleepWake() throws {
    let b = FakeHardwareBackend(mode: 0)
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    for _ in 0..<50 {
      c.requestBrightness(0.6, now: b.time)
      drive(c, b)
      b.awake = false
      c.suspend(now: b.time)
      Check.equal(b.mode, 0)
      Check.isTrue(c.isSuspended)
      b.awake = true
      b.reportedLogical = 2
      c.resume(now: b.time)
      Check.isTrue(c.isControlling)
    }
    c.restore(now: b.time)
    drive(c, b)
    Check.equal(b.mode, 0)
    Check.equal(b.duration, 0)
    Check.isTrue(!c.isControlling && !c.isSuspended)
  }

  private static func testWakeReadiness() throws {
    let b = FakeHardwareBackend(mode: 0)
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    b.awake = false
    c.suspend(now: 0)
    b.awake = true
    b.reportedLogical = 1
    c.resume(now: 1)
    Check.isTrue(c.isSuspended && !c.isControlling)
    b.reportedLogical = 2
    b.time = 1.1
    c.resume(now: 1.1)
    drive(c, b)
    Check.isTrue(c.isControlling && !c.isSuspended)
    c.restore(now: 2)

    let unavailable = FakeHardwareBackend(mode: 0)
    let blocked = HardwareControl(backend: unavailable)
    try blocked.connect(now: 0)
    unavailable.awake = false
    blocked.suspend(now: 0)
    unavailable.awake = true
    unavailable.reportedLogical = 1
    blocked.resume(now: 0)
    drive(blocked, unavailable)
    Check.isTrue(!blocked.isSuspended && !blocked.isControlling)
    let count = unavailable.calls
    blocked.advance(now: 100)
    Check.equal(unavailable.calls, count, "Wake retry must stop after its deadline.")
  }

  private static func testReleaseVerification() throws {
    let b = FakeHardwareBackend()
    let recovery = FakeHardwareRecovery()
    let c = HardwareControl(backend: b, recoveryStore: recovery)
    try c.connect(now: 0)
    c.requestBrightness(0.25, now: 0)
    drive(c, b)
    b.freezeFactor = true
    c.restore(now: b.time)
    Check.isTrue(c.status.contains("verifying"))
    drive(c, b, limit: 2)
    Check.isTrue(c.hasPendingRecovery)
    Check.isTrue(c.status.contains("could not be confirmed"))
    Check.isTrue(recovery.record != nil)
    b.freezeFactor = false
    c.restore(now: b.time)
    drive(c, b)
    Check.equal(recovery.record, nil)
    Check.isTrue(c.status.contains("is restored"))
    Check.isTrue(
      c.diagnosticSummary.contains("factor 0.99") || c.diagnosticSummary.contains("factor 1.0000"))
  }

  private static func testWakeDuringRelease() throws {
    let b = FakeHardwareBackend()
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    c.requestBrightness(0.4, now: 0)
    drive(c, b)
    // A fast lock/unlock or willSleep/didWake pair can overlap the 300 ms
    // automatic relight. The resume request must survive that verification.
    c.suspend(now: b.time)
    Check.isTrue(c.isSuspended && c.nextPollDelay != nil)
    c.resume(now: b.time)
    drive(c, b)
    Check.isTrue(c.isControlling && !c.isSuspended)
    c.restore(now: b.time)
    drive(c, b)
  }

  private static func testCrashRecovery() throws {
    let b = FakeHardwareBackend(mode: 0)
    let recovery = FakeHardwareRecovery()
    var first: HardwareControl? = HardwareControl(backend: b, recoveryStore: recovery)
    try first!.connect(now: 0)
    first!.requestBrightness(0.4, now: 0)
    drive(first!, b)
    first = nil  // Represents an interrupted process: no deinit hardware writes.
    Check.equal(b.mode, 2)
    Check.equal(recovery.record?.mode, 0)
    let writes = b.writes.count
    let relaunched = HardwareControl(backend: b, recoveryStore: recovery)
    Check.equal(b.writes.count, writes, "Launch must never silently control the LED.")
    Check.isTrue(relaunched.hasPendingRecovery)
    relaunched.restore(now: b.time)
    drive(relaunched, b)
    Check.equal(b.mode, 0)
    Check.equal(recovery.record, nil)
    let bad = FakeHardwareRecovery()
    bad.rejectLoad = true
    let blocked = HardwareControl(backend: b, recoveryStore: bad)
    let baseline = b.writes.count
    Check.throwsError(try blocked.connect(now: b.time))
    Check.equal(b.writes.count, baseline)
  }

  private static func testDisconnect() throws {
    let b = FakeHardwareBackend()
    let c = HardwareControl(backend: b)
    try c.connect(now: 0)
    c.requestBrightness(0.5, now: 0)
    c.advance(now: 0.03)
    c.restore(now: 0.04)
    drive(c, b)
    let count = b.calls
    for i in 0..<100 {
      c.requestBrightness(Double(i) / 100, now: Double(i))
      c.advance(now: Double(i))
    }
    Check.equal(b.calls, count)
    Check.isTrue(!c.isControlling)
    Check.equal(b.duration, 0)
  }

  private static func testRecoveryFiles() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/lidglow-hardware-check-\(UUID().uuidString)")
    try fm.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let url = root.appendingPathComponent("recovery.json")
    let store = HardwareRecoveryFile(url: url)
    let record = HardwareRecovery(mode: 0, logicalState: 2)
    Check.equal(try store.load(), nil)
    try store.acquireOwnership()
    defer { store.releaseOwnership() }
    try store.save(record)
    Check.equal(try store.load(), record)
    Check.equal(
      (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try store.clear()
    Check.isTrue(!fm.fileExists(atPath: url.path))

    let target = root.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    try fm.createSymbolicLink(at: url, withDestinationURL: target)
    Check.throwsError(try store.load())
    Check.throwsError(try store.save(record))
    Check.throwsError(try store.clear())
    Check.equal(try String(contentsOf: target, encoding: .utf8), "untouched")
    try fm.removeItem(at: url)

    let directory = root.appendingPathComponent("real")
    let linkDirectory = root.appendingPathComponent("link")
    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: linkDirectory, withDestinationURL: directory)
    let linkedStore = HardwareRecoveryFile(
      url: linkDirectory.appendingPathComponent("recovery.json"))
    Check.throwsError(try linkedStore.load())
    Check.throwsError(try linkedStore.acquireOwnership())
    Check.throwsError(try linkedStore.save(record))
    Check.isTrue(!fm.fileExists(atPath: directory.appendingPathComponent("recovery.json").path))

    Check.equal(mkfifo(url.path, 0o600), 0)
    Check.throwsError(try store.load(), "FIFO must be rejected without blocking.")
    try fm.removeItem(at: url)
    for data in [
      Data(repeating: 32, count: 4097), Data("not json".utf8),
      Data("{\"version\":1,\"mode\":99,\"logicalState\":2}".utf8),
    ] {
      try data.write(to: url)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      Check.throwsError(try store.load())
      try fm.removeItem(at: url)
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    Check.equal(link(target.path, url.path), 0)
    Check.throwsError(try store.load(), "A hard link is not a private recovery file.")
    try fm.removeItem(at: url)
    let missingDirectory = root.appendingPathComponent("not-created")
    Check.equal(
      try HardwareRecoveryFile(url: missingDirectory.appendingPathComponent("recovery.json"))
        .load(), nil)
    Check.isTrue(
      !fm.fileExists(atPath: missingDirectory.path), "Read-only load must not create its parent.")
  }

  private static func testConcurrentControllers() throws {
    let gate = FakeHardwareOwnership()
    let b = FakeHardwareBackend(mode: 0)
    let firstStore = FakeHardwareRecovery(gate: gate)
    let secondStore = FakeHardwareRecovery(gate: gate)
    let first = HardwareControl(backend: b, recoveryStore: firstStore)
    try first.connect(now: 0)
    let second = HardwareControl(backend: b, recoveryStore: secondStore)
    var writes = b.writes.count
    Check.throwsError(try second.connect(now: 0))
    Check.equal(b.writes.count, writes)
    Check.isTrue(second.status.contains("ownership"))
    // A later-launched app can see the other app's recovery record. That is
    // not permission to restore it while the owning process is still alive.
    secondStore.record = firstStore.record
    let loaded = HardwareControl(backend: b, recoveryStore: secondStore)
    loaded.restore(now: 0)
    Check.equal(b.writes.count, writes)
    Check.isTrue(loaded.hasPendingRecovery)
    b.awake = false
    first.suspend(now: 0)
    b.awake = true
    b.reportedLogical = 2
    writes = b.writes.count
    Check.throwsError(try second.connect(now: 0))
    Check.equal(b.writes.count, writes, "A suspended owner retains its lock.")
    first.resume(now: b.time)
    drive(first, b)
    first.restore(now: b.time)
    drive(first, b)
    Check.equal(gate.owner, nil)
    secondStore.record = nil
    try second.connect(now: b.time)
    Check.isTrue(second.isControlling)
    b.rejectKeyboard = true
    second.requestBrightness(0.3, now: b.time)
    drive(second, b)
    Check.isTrue(second.hasPendingRecovery)
    writes = b.writes.count
    Check.throwsError(try first.connect(now: b.time))
    Check.equal(b.writes.count, writes, "Failed restoration retains ownership until a safe retry.")
    b.rejectKeyboard = false
    second.restore(now: b.time)
    drive(second, b)
    Check.equal(gate.owner, nil)

    let failing = FakeHardwareRecovery(gate: gate)
    failing.rejectSave = true
    let rejected = HardwareControl(backend: b, recoveryStore: failing)
    Check.throwsError(try rejected.connect(now: b.time))
    Check.equal(gate.owner, nil, "A save failure before hardware writes must unlock.")
  }

  private static func testFileOwnership() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/lidglow-owner-check-\(UUID().uuidString)")
    let url = root.appendingPathComponent("recovery.json")
    defer { try? fm.removeItem(at: root) }
    let one = HardwareRecoveryFile(url: url)
    let two = HardwareRecoveryFile(url: url)
    let record = HardwareRecovery(mode: 2, logicalState: 2)
    Check.isTrue(
      !fm.fileExists(atPath: root.path), "Construction must not create a lock directory.")
    try one.acquireOwnership()
    try one.acquireOwnership()  // Idempotent for its own retained descriptor.
    try one.save(record)
    Check.equal(try two.load(), record)
    let before = ProcessInfo.processInfo.systemUptime
    Check.throwsError(try two.acquireOwnership())
    Check.isTrue(
      ProcessInfo.processInfo.systemUptime - before < 1, "Ownership contention must not block.")
    Check.throwsError(try two.save(HardwareRecovery(mode: 0, logicalState: 2)))
    Check.throwsError(try two.clear())
    Check.equal(try one.load(), record)
    one.releaseOwnership()
    try two.acquireOwnership()
    try two.clear()
    two.releaseOwnership()
    // Releasing does not unlink the inode: contenders continue to coordinate
    // on the same stable lock file across repeated connections.
    let lockURL = root.appendingPathComponent("hardware-owner.lock")
    Check.isTrue(fm.fileExists(atPath: lockURL.path))
    var interrupted: HardwareRecoveryFile? = HardwareRecoveryFile(url: url)
    try interrupted!.acquireOwnership()
    interrupted = nil
    try two.acquireOwnership()
    two.releaseOwnership()
    try fm.removeItem(at: lockURL)
    let target = root.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    try fm.createSymbolicLink(at: lockURL, withDestinationURL: target)
    Check.throwsError(try one.acquireOwnership())
    Check.equal(try String(contentsOf: target, encoding: .utf8), "untouched")
    try fm.removeItem(at: lockURL)
    Check.equal(mkfifo(lockURL.path, 0o600), 0)
    Check.throwsError(try one.acquireOwnership(), "An ownership FIFO must not block.")
    try fm.removeItem(at: lockURL)
    try Data([1]).write(to: lockURL)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
    Check.throwsError(try one.acquireOwnership(), "An unexpected nonempty lock is rejected.")
  }

  private static func drive(_ c: HardwareControl, _ b: FakeHardwareBackend, limit: Double = 3) {
    let deadline = b.time + limit
    while let delay = c.nextPollDelay, b.time < deadline {
      b.time += delay
      c.advance(now: b.time)
    }
    Check.equal(c.nextPollDelay, nil, "Work did not stop by fake-clock deadline: \(c.status)")
  }
}

@MainActor
private final class FakeHardwareRecovery: HardwareRecoveryStore {
  enum Failure: Error { case injected }
  var record: HardwareRecovery?
  var rejectSave = false
  var rejectLoad = false
  private let gate: FakeHardwareOwnership?
  private let id = UUID()
  init(gate: FakeHardwareOwnership? = nil) { self.gate = gate }
  func acquireOwnership() throws {
    if let gate {
      guard gate.owner == nil || gate.owner == id else { throw OwnershipFailure.held }
      gate.owner = id
    }
  }
  func releaseOwnership() { if gate?.owner == id { gate?.owner = nil } }
  func load() throws -> HardwareRecovery? {
    if rejectLoad { throw Failure.injected }
    return record
  }
  func save(_ record: HardwareRecovery) throws {
    if rejectSave { throw Failure.injected }
    self.record = record
  }
  func clear() throws { record = nil }
  enum OwnershipFailure: LocalizedError {
    case held
    var errorDescription: String? { "Hardware ownership belongs to another instance." }
  }
}

@MainActor
private final class FakeHardwareOwnership { var owner: UUID? }

@MainActor
private final class FakeHardwareBackend: HardwareControlBackend {
  var canPreserveKeyboard = true
  var awake = true
  var mode: Int?
  var reportedLogical: Int? = 2
  var lightLogical = 2
  var time = 0.0
  var duration = 0.0
  var factorAvailable = true
  var freezeFactor = false
  var rejectKeyboard = false
  var ignored: Set<HardwareProperty> = []
  var rejected: Set<HardwareProperty> = []
  var writes: [String] = []
  private(set) var calls = 0
  private var factor = 1.0
  private var from = 1.0
  private var target = 1.0
  private var started = 0.0
  private var activeDuration = 0.3
  init(mode: Int = 2) { self.mode = mode }
  var displayAwake: Bool {
    calls += 1
    return awake
  }
  var currentFactor: Double {
    if !freezeFactor {
      let u = max(0, (time - started) / activeDuration)
      let progress = u >= 1 ? 1 : 1 - (1 + 6.51 * u) * exp(-6.51 * u)
      factor = min(max(from + (target - from) * progress, 0), 1)
    }
    return factor
  }
  func readMode() -> Int? {
    calls += 1
    return mode
  }
  func readLogicalState() -> Int? {
    calls += 1
    return reportedLogical
  }
  func readFactor() -> Double? {
    calls += 1
    return factorAvailable ? currentFactor : nil
  }
  func write(_ value: Double, property: HardwareProperty) -> Bool {
    calls += 1
    writes.append("\(property.rawValue):\(value)")
    if rejected.contains(property) { return false }
    if ignored.contains(property) { return true }
    switch property {
    case .mode: mode = Int(value)
    case .duration: duration = value
    case .logical:
      reportedLogical = Int(value)
      if lightLogical != Int(value) {
        from = currentFactor
        target = value == 2 ? 1 : 0
        started = time
        activeDuration = duration > 0 ? duration : 0.3
        lightLogical = Int(value)
      }
    }
    return true
  }
  func correctKeyboard(logicalState: Int) -> Bool {
    calls += 1
    writes.append("keyboard:\(logicalState)")
    reportedLogical = logicalState
    return !rejectKeyboard
  }
}
