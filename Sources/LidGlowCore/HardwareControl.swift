import Foundation

/// The only CoreBrightness properties the controller may change.
public enum HardwareProperty: String, Codable {
  case mode = "LEBacklightMode"
  case duration = "LEPWMFactorFadeDuration"
  case logical = "DisplayLogicalState"
}

/// Injected for deterministic tests. The production implementation is main-thread
/// confined and unsandboxed; test implementations never touch macOS hardware.
@MainActor
public protocol HardwareControlBackend: AnyObject {
  var canPreserveKeyboard: Bool { get }
  var displayAwake: Bool { get }
  func readMode() -> Int?
  func readLogicalState() -> Int?
  func readFactor() -> Double?
  func write(_ value: Double, property: HardwareProperty) -> Bool
  func correctKeyboard(logicalState: Int) -> Bool
}

public struct HardwareRecovery: Codable, Equatable {
  public let version: Int
  public let mode: Int
  public let logicalState: Int
  public init(mode: Int, logicalState: Int) {
    version = 1
    self.mode = mode
    self.logicalState = logicalState
  }
  public var isValid: Bool {
    version == 1 && (mode == 0 || mode == 2) && [2, 4, 6].contains(logicalState)
  }
}

@MainActor
public protocol HardwareRecoveryStore: AnyObject {
  func acquireOwnership() throws
  func releaseOwnership()
  func load() throws -> HardwareRecovery?
  func save(_ record: HardwareRecovery) throws
  func clear() throws
}

extension HardwareRecoveryStore {
  public func acquireOwnership() throws {}
  public func releaseOwnership() {}
}

/// A deterministic state machine. It has no timer, task, filesystem, or framework
/// dependency. The wrapper schedules advance() only while nextPollDelay is non-nil.
/// A settled hold/endpoint causes zero backend calls until a new request or event.
@MainActor
public final class HardwareControl {
  public enum ControlError: LocalizedError {
    case unavailable(String)
    case operation(String)
    public var errorDescription: String? {
      switch self {
      case .unavailable(let text), .operation(let text): return text
      }
    }
  }

  private enum Work {
    case idle
    case moving
    case waitingForWake(deadline: Double)
    case verifyingRelease(deadline: Double, expectedMode: Int, expectedFactor: Double?)
  }
  private let backend: HardwareControlBackend
  private let recoveryStore: HardwareRecoveryStore?
  private var snapshot: HardwareRecovery?
  private var work = Work.idle
  private var requestedLevel = 1.0
  private var settledTarget: Double?
  private var headingLit: Bool?
  private var held = false
  private var previousFactor: Double?
  private var lastMovementFactor = 0.0
  private var lastMovementTime = 0.0
  private var restorationFailed = false
  private var recoveryLoadFailed = false
  private var resumeRequestedDuringRelease = false
  private var ownsHardware = false

  public private(set) var isControlling = false
  public private(set) var isSuspended = false
  public private(set) var status = "Ready to connect."
  public private(set) var diagnosticSummary = "No hardware write has been made."
  public var onStateChange: (() -> Void)?
  public var hasPendingRecovery: Bool { snapshot != nil && !isControlling && !isSuspended }
  public var nextPollDelay: Double? {
    switch work {
    case .idle: return nil
    case .waitingForWake: return 0.2
    case .moving, .verifyingRelease: return 0.03
    }
  }

  public init(backend: HardwareControlBackend, recoveryStore: HardwareRecoveryStore? = nil) {
    self.backend = backend
    self.recoveryStore = recoveryStore
    do {
      if let record = try recoveryStore?.load() {
        guard record.isValid else {
          throw ControlError.operation("Invalid hardware recovery record.")
        }
        snapshot = record
        status =
          "A previous session ended before release was verified. Connect or Restore to recover its setting."
      }
    } catch {
      recoveryLoadFailed = true
      status =
        "Hardware recovery data could not be read safely. Control is disabled: \(error.localizedDescription)"
    }
  }

  public func connect(now: Double) throws {
    do { try connectImpl(now: now) } catch {
      if snapshot == nil, !isControlling, !isSuspended { setStatus(error.localizedDescription) }
      throw error
    }
  }

  private func connectImpl(now: Double) throws {
    guard !isControlling else { return }
    guard !recoveryLoadFailed else { throw ControlError.operation(status) }
    guard backend.canPreserveKeyboard, backend.displayAwake else {
      throw ControlError.unavailable(
        "Open the lid and wake the built-in display before connecting.")
    }
    // Explicit Connect can repair a record left by a crash. The launch path
    // never writes hardware. A repair must be verified before new acquisition.
    if snapshot != nil {
      if case .verifyingRelease = work {
        throw ControlError.unavailable("The previous release is still being verified.")
      }
      restore(now: now)
      if snapshot != nil { throw ControlError.unavailable(status) }
    }
    guard let mode = backend.readMode(), mode == 0 || mode == 2,
      let logical = backend.readLogicalState(), [2, 4, 6].contains(logical),
      let factor = backend.readFactor(), Self.validFactor(factor)
    else {
      throw ControlError.unavailable(
        "Logo state could not be read safely. Hardware control was not started.")
    }
    let record = HardwareRecovery(mode: mode, logicalState: logical)
    try acquireOwnership()
    do { try recoveryStore?.save(record) } catch {
      isSuspended = false
      releaseOwnershipIfSafe()
      throw ControlError.operation(
        "The recovery record could not be saved; no hardware changes were made.")
    }
    snapshot = record
    do {
      try write(2, .mode)
      guard backend.readMode() == 2 else {
        throw ControlError.operation("macOS did not confirm logo control.")
      }
      isControlling = true
      isSuspended = false
      resumeRequestedDuringRelease = false
      restorationFailed = false
      headingLit = nil
      held = false
      settledTarget = nil
      previousFactor = factor
      lastMovementFactor = factor
      lastMovementTime = now
      work = .moving
      setStatus("Connected — controlling the logo's white light.")
    } catch {
      let reason = error.localizedDescription
      restore(now: now)
      setStatus("Connection failed: \(reason) \(status)")
      throw error
    }
  }

  public func requestBrightness(_ value: Double, now: Double) {
    guard value.isFinite else { return }
    let value = min(max(value, 0), 1)
    requestedLevel = value
    guard isControlling else { return }
    // Endpoints always finish a true native fade, even if close to a hold.
    let endpoint = value == 0 || value == 1
    if let target = settledTarget,
      endpoint ? target == value : abs(target - value) < 0.015
    {
      return
    }
    if case .idle = work {
      previousFactor = nil
      lastMovementTime = now
      work = .moving
    }
  }

  public func advance(now: Double) {
    switch work {
    case .idle: return
    case .waitingForWake(let deadline):
      if now >= deadline {
        work = .idle
        isSuspended = false
        releaseOwnershipIfSafe()
        setStatus("The display did not become ready to resume logo control. Connect can retry.")
      } else {
        work = .idle
        attemptResume(now: now, deadline: deadline)
      }
    case .verifyingRelease(let deadline, let expectedMode, let expectedFactor):
      verifyRelease(now: now, deadline: deadline, mode: expectedMode, factor: expectedFactor)
    case .moving:
      guard isControlling else {
        work = .idle
        return
      }
      guard backend.displayAwake else {
        suspend(now: now)
        return
      }
      do { try advanceFade(now: now) } catch {
        let reason = error.localizedDescription
        restore(now: now)
        isSuspended = false
        setStatus("Hardware control stopped: \(reason) \(status)")
      }
    }
  }

  public func suspend(now: Double) {
    guard isControlling else { return }
    resumeRequestedDuringRelease = false
    release(now: now, suspend: true)
  }

  public func resume(now: Double) {
    if isSuspended, case .verifyingRelease = work {
      resumeRequestedDuringRelease = true
      return
    }
    if case .waitingForWake = work { return }
    attemptResume(now: now, deadline: now + 2)
  }

  private func attemptResume(now: Double, deadline: Double) {
    guard isSuspended, backend.displayAwake else { return }
    if case .verifyingRelease = work { return }
    // A verified suspension keeps the original snapshot on disk. Remove its
    // in-memory reservation before acquiring the current restored preference.
    guard !restorationFailed else {
      isSuspended = false
      notify()
      return
    }
    snapshot = nil
    isSuspended = false
    do { try connect(now: now) } catch ControlError.unavailable(let reason) {
      isSuspended = true
      // If recovery verification is pending, preserve that work. Otherwise
      // retry bounded wake readiness even when the selected mode is static.
      if case .idle = work { work = .waitingForWake(deadline: deadline) }
      setStatus("Waiting for logo control to resume: \(reason)")
    } catch {
      isSuspended = false
      releaseOwnershipIfSafe()
      setStatus("Could not resume logo control: \(error.localizedDescription)")
    }
  }

  public func restore(now: Double) {
    isSuspended = false
    resumeRequestedDuringRelease = false
    release(now: now, suspend: false)
  }

  private func advanceFade(now: Double) throws {
    guard let current = backend.readFactor(), Self.validFactor(current) else {
      throw ControlError.operation("The logo stopped reporting its brightness.")
    }
    let previous = previousFactor ?? current
    defer { previousFactor = current }
    if abs(current - lastMovementFactor) > 0.002 {
      lastMovementFactor = current
      lastMovementTime = now
    }
    let delta = requestedLevel - current
    let endpoint = requestedLevel == 0 || requestedLevel == 1
    let closeEnough = abs(delta) <= (endpoint ? 0.004 : 0.025)
    let crossed =
      !held && !endpoint
      && headingLit.map {
        $0
          ? previous < requestedLevel && current >= requestedLevel
          : previous > requestedLevel && current <= requestedLevel
      } == true
    if closeEnough || crossed {
      if endpoint {
        if held {
          try move(toward: requestedLevel, from: current)
          return
        }
        // Leave the last native fade to complete; never leave an endless
        // duration at an endpoint. Its automatic finish needs no polling.
        try write(0, .duration)
      } else if !held {
        try hold()
      }
      settledTarget = requestedLevel
      work = .idle
      let logical = backend.readLogicalState().map(String.init) ?? "unavailable"
      diagnosticSummary =
        "mode 2 · factor \(Self.format(current)) · logical \(logical) · target \(Self.format(requestedLevel))"
      notify()
      return
    }
    let up = delta > 0
    if headingLit != up || held {
      try move(toward: requestedLevel, from: current)
      lastMovementTime = now
    }
    if now - lastMovementTime > 2 {
      throw ControlError.operation("macOS accepted a command but the logo did not respond.")
    }
  }

  private func move(toward target: Double, from current: Double) throws {
    let up = target > current
    if headingLit == nil || headingLit == up { try reverseToHold(from: up) }
    let remaining = up ? 1 - current : current
    let fraction = remaining > 0 ? abs(target - current) / remaining : 1
    let duration = fraction >= 0.95 ? 0.16 : max(0.08, 0.12 / Self.springTime(fraction))
    try write(duration, .duration)
    try setLit(up)
    held = false
    settledTarget = nil
  }

  private func hold() throws {
    if let headingLit {
      try reverseToHold(from: headingLit)
    } else {
      try write(1e9, .duration)
      try setLit(false)
      try setLit(true)
      held = true
    }
  }

  private func reverseToHold(from lit: Bool) throws {
    try write(1e9, .duration)
    try setLit(!lit)
    held = true
  }

  private func setLit(_ lit: Bool) throws {
    try write(lit ? 2 : 1, .logical)
    headingLit = lit
    if !lit {
      guard backend.displayAwake, backend.correctKeyboard(logicalState: 2) else {
        throw ControlError.operation("Keyboard lighting could not be preserved.")
      }
    }
  }

  /// Force a direction change using automatic duration, then end in the real
  /// display state. Merely writing duration=0 would not release an existing hold:
  /// the daemon applies the new duration only to a NEW transition.
  private func release(now: Double, suspend: Bool) {
    isControlling = false
    isSuspended = suspend
    work = .idle
    held = false
    headingLit = nil
    settledTarget = nil
    guard let record = snapshot else {
      releaseOwnershipIfSafe()
      notify()
      return
    }
    do { try acquireOwnership() } catch {
      restorationFailed = true
      isSuspended = false
      setStatus("Restoration was not started: \(error.localizedDescription)")
      return
    }
    let awake = backend.displayAwake
    var success = backend.write(0, property: .duration)
    if awake {
      success = backend.write(1, property: .logical) && success
      success = backend.correctKeyboard(logicalState: record.logicalState) && success
      success = backend.write(2, property: .logical) && success
      success = backend.correctKeyboard(logicalState: record.logicalState) && success
    } else {
      success = backend.write(2, property: .logical) && success
      success = backend.write(1, property: .logical) && success
      success = backend.correctKeyboard(logicalState: 1) && success
    }
    success = backend.write(Double(record.mode), property: .mode) && success
    success = backend.write(0, property: .duration) && success
    let confirmedMode = backend.readMode()
    success = confirmedMode == record.mode && success
    restorationFailed = !success
    let factor = backend.readFactor().map(Self.format) ?? "unavailable"
    let logical = backend.readLogicalState().map(String.init) ?? "unavailable"
    diagnosticSummary =
      "mode \(confirmedMode.map(String.init) ?? "unavailable") · factor \(factor) · logical \(logical) · release target logical \(awake ? 2 : 1)"
    guard success else {
      isSuspended = false
      setStatus(
        "macOS did not confirm restoration. The recovery record is retained; Restore can retry.")
      return
    }
    // Sleeping/disabled LEDs may report a gated Factor. Only the awake, enabled
    // case can establish that normal brightness was actually recovered.
    let expected = awake && record.mode == 2 ? 1.0 : nil
    if expected == nil {
      completeRelease(now: now)
      return
    }
    work = .verifyingRelease(
      deadline: now + 1.0, expectedMode: record.mode, expectedFactor: expected)
    setStatus("Returning the logo to macOS; verifying its brightness…")
  }

  private func verifyRelease(now: Double, deadline: Double, mode: Int, factor expected: Double?) {
    let reportedMode = backend.readMode()
    let logical = backend.readLogicalState()
    let factor = backend.readFactor()
    diagnosticSummary =
      "mode \(reportedMode.map(String.init) ?? "unavailable") · factor \(factor.map(Self.format) ?? "unavailable") · logical \(logical.map(String.init) ?? "unavailable")"
    // A real sleep while verifying a release is not a failed relight. Its new
    // Blank owns the LED; the normal duration and previous mode were restored.
    if !backend.displayAwake, reportedMode == mode {
      completeRelease(now: now)
      return
    }
    if reportedMode == mode, let expected, let factor, Self.validFactor(factor),
      abs(factor - expected) <= 0.005, logical == 2 || logical == 4 || logical == 6
    {
      completeRelease(now: now)
    } else if now >= deadline {
      work = .idle
      restorationFailed = true
      isSuspended = false
      setStatus(
        "The original mode was requested, but normal brightness could not be confirmed. Recovery is retained; Restore can retry."
      )
    }
  }

  private func completeRelease(now: Double) {
    work = .idle
    restorationFailed = false
    do {
      try recoveryStore?.clear()
      snapshot = nil
      releaseOwnershipIfSafe()
      setStatus(
        isSuspended
          ? "Hardware control paused; the system setting is restored."
          : "Released — the previous system setting is restored.")
      if isSuspended, resumeRequestedDuringRelease {
        resumeRequestedDuringRelease = false
        attemptResume(now: now, deadline: now + 2)
      }
    } catch {
      restorationFailed = true
      isSuspended = false
      setStatus(
        "The light was restored, but its recovery record could not be cleared. Restore can retry.")
    }
  }

  private func write(_ value: Double, _ property: HardwareProperty) throws {
    guard ownsHardware else {
      throw ControlError.operation("Hardware ownership has not been acquired.")
    }
    guard backend.write(value, property: property) else {
      throw ControlError.operation("macOS rejected the logo setting \(property.rawValue).")
    }
  }
  private func acquireOwnership() throws {
    guard !ownsHardware else { return }
    do { try recoveryStore?.acquireOwnership() } catch {
      throw ControlError.operation(error.localizedDescription)
    }
    ownsHardware = true
  }
  private func releaseOwnershipIfSafe() {
    guard ownsHardware, !isControlling, !isSuspended, snapshot == nil else { return }
    recoveryStore?.releaseOwnership()
    ownsHardware = false
  }
  private func setStatus(_ value: String) {
    status = value
    notify()
  }
  private func notify() { onStateChange?() }
  private static func validFactor(_ factor: Double) -> Bool {
    factor.isFinite && (0...1).contains(factor)
  }
  private static func format(_ factor: Double) -> String { String(format: "%.4f", factor) }
  private static func springTime(_ fraction: Double) -> Double {
    let goal = min(max(fraction, 0.0001), 0.999)
    var low = 0.0
    var high = 3.0
    for _ in 0..<40 {
      let mid = (low + high) / 2
      if 1 - (1 + 6.51 * mid) * exp(-6.51 * mid) < goal { low = mid } else { high = mid }
    }
    return max(0.0001, (low + high) / 2)
  }
}
