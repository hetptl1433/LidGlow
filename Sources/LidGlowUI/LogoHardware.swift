import CoreGraphics
import Darwin
import Foundation
import IOKit
import LidGlowCore
import ObjectiveC

/// Native shell around the tested state machine. Construction is read-only;
/// preview never loads a bridge. Polling runs only during transitions or release
/// checks. Private selectors/fade technique derive from LogoLight (MIT); see notices.
@MainActor
final class LogoHardware {
  private var controller: HardwareControl?
  private var polling: Task<Void, Never>?
  private let baseStatus: String
  private(set) var isAvailable = false
  var isControlling: Bool { controller?.isControlling ?? false }
  var isSuspended: Bool { controller?.isSuspended ?? false }
  var hasPendingRecovery: Bool { controller?.hasPendingRecovery ?? false }
  var isRestoring: Bool { !isControlling && controller?.nextPollDelay != nil }
  var status: String {
    guard let controller, controller.status != "Ready to connect." else { return baseStatus }
    return controller.status
  }
  /// Cached; reading diagnostics performs no XPC or filesystem I/O.
  var diagnosticSummary: String { controller?.diagnosticSummary ?? "No hardware writes made." }
  var onStateChange: (() -> Void)?

  init(previewOnly: Bool = false, recoveryURL: URL? = nil) {
    if previewOnly {
      baseStatus = "Preview only — hardware control is disabled."
      return
    }
    guard Self.hasLogoPWM else {
      baseStatus = "No compatible illuminated logo was detected. Preview is available."
      return
    }
    guard let bridge = BrightnessBridge() else {
      baseStatus = "The required CoreBrightness interface is unavailable."
      return
    }
    guard bridge.canPreserveKeyboard,
      let mode = bridge.readMode(), mode == 0 || mode == 2,
      let factor = bridge.readFactor(), factor.isFinite, (0...1).contains(factor)
    else {
      baseStatus =
        "Logo hardware is present, but macOS did not expose all controls needed for safe brightness changes."
      return
    }
    baseStatus = "Compatible logo detected. Connect to control its white light."
    isAvailable = true
    let recovery = recoveryURL.map(HardwareRecoveryFile.init(url:))
    controller = HardwareControl(backend: bridge, recoveryStore: recovery)
    controller?.onStateChange = { [weak self] in
      self?.scheduleIfNeeded()
      self?.onStateChange?()
    }
  }
  func connect() throws {
    guard let controller else { throw HardwareControl.ControlError.unavailable(status) }
    defer {
      scheduleIfNeeded()
      onStateChange?()
    }
    try controller.connect(now: Self.now)
  }
  func setBrightness(_ value: Double) {
    controller?.requestBrightness(value, now: Self.now)
    scheduleIfNeeded()
  }
  func suspend() {
    controller?.suspend(now: Self.now)
    scheduleIfNeeded()
  }
  func resume() {
    controller?.resume(now: Self.now)
    scheduleIfNeeded()
  }
  func restore() {
    controller?.restore(now: Self.now)
    scheduleIfNeeded()
    onStateChange?()
  }

  private func scheduleIfNeeded() {
    guard polling == nil, controller?.nextPollDelay != nil else { return }
    polling = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, let delay = self.controller?.nextPollDelay else { break }
        do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { break }
        guard !Task.isCancelled else { break }
        self.controller?.advance(now: Self.now)
      }
      self?.polling = nil
    }
  }
  private static var now: Double { ProcessInfo.processInfo.systemUptime }
  private static var hasLogoPWM: Bool {
    // @0 is an ioreg location suffix, not the registered name.
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceNameMatching("bklb-backlight"))
    guard service != IO_OBJECT_NULL else { return false }
    IOObjectRelease(service)
    return true
  }
}

@MainActor
private final class BrightnessBridge: HardwareControlBackend {
  private typealias CopyFunction =
    @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
  private typealias SetFunction = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
  private typealias KeyboardSetFunction =
    @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool
  private let client: NSObject
  private let copySelector = NSSelectorFromString("copyPropertyForKey:")
  private let setSelector = NSSelectorFromString("setProperty:forKey:")
  private let keyboardSelector = NSSelectorFromString("setProperty:withKey:keyboardID:")
  private let copyFunction: CopyFunction
  private let setFunction: SetFunction
  private let keyboardFunction: KeyboardSetFunction?
  private let keyboardIDs: [UInt64]
  var canPreserveKeyboard: Bool { keyboardFunction != nil && !keyboardIDs.isEmpty }
  var displayAwake: Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return false }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
    return displays.prefix(Int(count)).contains {
      CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0
    }
  }
  init?() {
    guard
      dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        != nil,
      let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
      type.instancesRespond(to: copySelector), type.instancesRespond(to: setSelector)
    else { return nil }
    client = type.init()
    copyFunction = unsafeBitCast(client.method(for: copySelector), to: CopyFunction.self)
    setFunction = unsafeBitCast(client.method(for: setSelector), to: SetFunction.self)
    keyboardFunction =
      type.instancesRespond(to: keyboardSelector)
      ? unsafeBitCast(client.method(for: keyboardSelector), to: KeyboardSetFunction.self) : nil
    let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
    if let keyboardType = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
      keyboardType.instancesRespond(to: selector),
      let ids = keyboardType.init().perform(selector)?.takeRetainedValue() as? [NSNumber]
    {
      keyboardIDs = ids.map(\.uint64Value)
    } else {
      keyboardIDs = []
    }
  }
  private func value(_ key: String) -> Any? {
    // Objective-C copy ownership is +1, including the returned dictionary.
    copyFunction(client, copySelector, key as NSString)?.takeRetainedValue()
  }
  func readMode() -> Int? { (value("LEBacklightMode") as? NSNumber)?.intValue }
  func readLogicalState() -> Int? { (value("DisplayLogicalState") as? NSNumber)?.intValue }
  func readFactor() -> Double? {
    ((value("LEPWMState") as? [String: Any])?["Factor"] as? NSNumber)?.doubleValue
  }
  func write(_ value: Double, property: HardwareProperty) -> Bool {
    setFunction(client, setSelector, NSNumber(value: value), property.rawValue as NSString)
  }
  func correctKeyboard(logicalState: Int) -> Bool {
    guard let keyboardFunction, !keyboardIDs.isEmpty else { return false }
    var success = true
    for id in keyboardIDs {
      success =
        keyboardFunction(
          client, keyboardSelector, NSNumber(value: logicalState),
          "DisplayLogicalState" as NSString, id) && success
    }
    return success
  }
}
