#if DEBUG
  import Darwin
  import Foundation
  import LidGlowCore

  @testable import LidGlowUI

  /// No UserDefaults, filesystem paths, helper processes, or AppKit application.
  private final class MemorySettings: SettingsStore {
    private(set) var values: [String: Any]
    private(set) var writes = 0

    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func bool(forKey key: String) -> Bool {
      if let number = values[key] as? NSNumber { return number.boolValue }
      return ["true", "yes", "1"].contains((values[key] as? String)?.lowercased() ?? "")
    }
    func double(forKey key: String) -> Double {
      if let number = values[key] as? NSNumber { return number.doubleValue }
      return (values[key] as? String).flatMap(Double.init) ?? 0
    }
    func set(_ value: Any?, forKey key: String) {
      writes += 1
      values[key] = value
    }
  }

  private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
  }

  @main
  @MainActor
  private enum LidGlowAppChecks {
    private static var assertions = 0
    private static var cases = 0
    private static var failures = 0

    private static func expect(
      _ condition: @autoclosure () -> Bool, _ message: String,
      file: StaticString = #fileID, line: UInt = #line
    ) throws {
      assertions += 1
      if !condition() { throw CheckFailure(description: "\(file):\(line): \(message)") }
    }

    private static func run(_ name: String, _ check: () throws -> Void) {
      cases += 1
      do {
        try check()
        print("PASS \(name)")
      } catch {
        failures += 1
        FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
      }
    }

    static func main() {
      run("Saved settings and repeated equal assignments do not recurse", savedSettingsRegression)
      run("Unicode and agent preferences normalize before persistence", boundedInputs)
      run("Corrupt saved numbers and preferences fall back safely", corruptSettings)
      run("Focus length, pause, resume and reset use the production model", focusLifecycle)
      run("Preview power persists intent without acquiring hardware", previewPower)
      run("Independent provider rules survive a model restart", settingsRoundtrip)
      run(
        "Production model selects concurrent signals and preserves ongoing work", concurrentSignals)
      run("Automation URLs bound input and never acquire preview hardware", automationURLs)
      run("Headless shutdown is idempotent and starts no helper work", repeatedShutdown)
      print("\(cases) app-model cases · \(assertions) assertions · \(failures) failures")
      exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func makeModel(_ settings: MemorySettings = MemorySettings()) -> AppModel {
      AppModel(previewOnly: true, settings: settings, startServices: false)
    }

    private static func savedSettingsRegression() throws {
      var preferences = AgentPreferences.default
      preferences.claude.working.style = .pulse
      preferences.codex.completed.style = .doubleBlink
      preferences.codex.completionSeconds = 15
      preferences.concurrent = .count
      let pattern = "100:0.2, 0:0.8"
      let store = MemorySettings([
        "morseText": "HELLO", "customPattern": pattern,
        "agentPreferences": try JSONEncoder().encode(preferences),
      ])
      // Loading these values crashed the original @Published property observers.
      let model = makeModel(store)
      defer { model.shutdown() }
      try expect(model.morseText == "HELLO", "Saved Morse text was not loaded")
      try expect(model.customPattern == pattern, "Saved custom pattern was not loaded")
      try expect(model.agentPreferences == preferences, "Saved provider rules changed on load")
      try expect(model.patternError == nil, "A valid loaded pattern was rejected")
      for _ in 0..<128 {
        let morse = model.morseText
        let custom = model.customPattern
        let rules = model.agentPreferences
        model.morseText = morse
        model.customPattern = custom
        model.agentPreferences = rules
      }
      try expect(
        store.string(forKey: "morseText") == "HELLO", "Equal assignment did not persist Morse text")
      try expect(
        store.string(forKey: "customPattern") == pattern, "Equal assignment changed the pattern")
      try expect(
        store.data(forKey: "agentPreferences") != nil, "Provider preferences were not persisted")
      let persisted = try JSONDecoder().decode(
        AgentPreferences.self, from: store.data(forKey: "agentPreferences") ?? Data())
      try expect(persisted == preferences, "Equal rule assignments changed saved preferences")
    }

    private static func boundedInputs() throws {
      let store = MemorySettings()
      let model = makeModel(store)
      defer { model.shutdown() }
      let giantGrapheme = "a" + String(repeating: "\u{301}", count: 20_000)
      model.morseText = giantGrapheme
      try expect(
        model.morseText.count <= 160 && model.morseText.utf8.count <= 1024,
        "A single giant Unicode grapheme escaped the Morse byte limit")
      try expect(
        store.string(forKey: "morseText") == model.morseText, "Unbounded Morse text was persisted")

      model.customPattern = String(repeating: "😀", count: 4096)
      try expect(model.customPattern.utf8.count <= 2048, "Custom text escaped its byte limit")
      try expect(
        model.patternError != nil, "Invalid bounded custom text has no cached validation error")
      let cachedError = model.patternError
      model.dimOnLowPower = false
      model.brightness = 1
      model.mode = .custom
      model.setSurfaceVisible("checks", true)
      try expect(model.output == 0, "An invalid custom pattern produced light")
      try expect(
        model.patternError == cachedError, "Rendering changed the cached validation result")

      var preferences = model.agentPreferences
      preferences.rotationSeconds = 999
      preferences.claude.completionSeconds = -5
      preferences.codex.completionSeconds = .nan
      preferences.claude.working = SignalRule(style: .custom, pattern: giantGrapheme)
      preferences.codex.completed = SignalRule(
        style: .custom, pattern: String(repeating: "😀", count: 4096))
      model.agentPreferences = preferences
      try expect(model.agentPreferences.rotationSeconds == 10, "Rotation was not clamped")
      try expect(
        model.agentPreferences.claude.completionSeconds == 0,
        "Negative completion duration was not clamped")
      try expect(
        model.agentPreferences.codex.completionSeconds == 8,
        "Nonfinite completion duration did not fall back")
      try expect(
        model.agentPreferences.claude.working.pattern.utf8.count <= 2048,
        "Claude custom rule escaped its byte limit")
      try expect(
        model.agentPreferences.codex.completed.pattern.utf8.count <= 2048,
        "Codex custom rule escaped its byte limit")
      try expect(
        store.data(forKey: "agentPreferences") != nil, "Normalized preferences could not be encoded"
      )
      let persisted = try JSONDecoder().decode(
        AgentPreferences.self, from: store.data(forKey: "agentPreferences") ?? Data())
      try expect(persisted == model.agentPreferences, "Normalized preferences were not persisted")
      try expect(
        store.string(forKey: "customPattern") == model.customPattern,
        "Unbounded custom text was persisted")

      model.customPattern = "25:1"
      try expect(model.patternError == nil, "Correcting a pattern did not clear its cached error")
      try expect(
        abs(model.output - 0.25) < 0.001, "Corrected custom pattern was not compiled for rendering")
      model.setSurfaceVisible("checks", false)
    }

    private static func corruptSettings() throws {
      let store = MemorySettings([
        "mode": "not-a-mode", "brightness": Double.nan, "speed": Double.infinity,
        "minimum": -10.0, "focusMinutes": Double.infinity, "enabled": false,
        "agentPreferences": Data("{broken-json".utf8), "customPattern": "not-a-pattern",
      ])
      let model = makeModel(store)
      defer { model.shutdown() }
      try expect(model.mode == .breathe, "Unknown saved mode did not keep the default")
      try expect(
        model.brightness == 0.7 && model.speed == 1,
        "Nonfinite saved lighting values did not fall back")
      try expect(
        model.minimum == 0 && model.focusMinutes == 25, "Saved numeric bounds were not applied")
      try expect(model.agentPreferences == .default, "Corrupt provider JSON changed default rules")
      try expect(!model.enabled, "A valid saved Off setting was discarded")
      try expect(model.patternError != nil, "Invalid saved pattern was not validated")
      try expect(
        !model.isControlling && !model.hasPendingShutdownWork,
        "Corrupt settings started hardware or helper work")
    }

    private static func focusLifecycle() throws {
      let model = makeModel()
      defer { model.shutdown() }
      model.focusMinutes = 3
      try expect(
        model.focusRemaining == 180 && !model.focusRunning,
        "Editing idle focus length did not reset the clock")
      model.startFocus()
      try expect(
        model.mode == .focus && model.focusRunning,
        "Starting focus did not select and run the focus mode")
      try expect(
        model.focusRemaining > 179 && model.focusRemaining <= 180,
        "Focus started with the wrong duration")
      model.pauseFocus()
      let paused = model.focusRemaining
      try expect(
        !model.focusRunning && paused > 0 && paused <= 180,
        "Pausing did not preserve the remaining time")
      model.startFocus()
      try expect(
        model.focusRunning && model.focusRemaining <= paused + 0.01,
        "Resuming restarted the full duration")
      model.focusMinutes = 5
      try expect(
        model.focusRunning && model.focusRemaining <= 180,
        "Editing the next session reset a running focus clock")
      model.pauseFocus()
      model.focusMinutes = 7
      try expect(
        model.focusRemaining == 420 && !model.focusRunning,
        "Changing idle length did not configure the next session")
      model.resetFocus()
      try expect(
        model.focusRemaining == 420 && !model.focusPaused && !model.focusCompleted,
        "Reset left stale pause or completion state")
      try expect(!model.hasPendingShutdownWork, "Headless focus started helper work")
    }

    private static func previewPower() throws {
      let store = MemorySettings(["controlsWanted": true])
      let model = makeModel(store)
      defer { model.shutdown() }
      model.setLogoPower(false)
      try expect(!model.enabled && !store.bool(forKey: "enabled"), "Preview Off was not persisted")
      try expect(
        !model.isControlling && !model.hardwareAvailable && !model.canReleaseHardware,
        "Preview Off acquired or probed hardware")
      try expect(!store.bool(forKey: "controlsWanted"), "Preview power claimed hardware ownership")
      model.turnOnLight()
      try expect(model.enabled && store.bool(forKey: "enabled"), "Preview On was not persisted")
      model.completeWelcome(startLighting: false)
      try expect(
        store.bool(forKey: "hasSeenWelcome") && !model.showWelcome, "Welcome choice did not persist"
      )
      try expect(
        !store.bool(forKey: "controlsWanted"),
        "Explore preview retained a previous acquisition request")
      model.activateSavedLightingIfNeeded()
      model.activateSavedLightingIfNeeded()
      model.useSystemLighting()
      try expect(
        !model.isControlling && !model.needsLightingReset && !model.hasPendingShutdownWork,
        "Preview startup or automatic-lighting action started hardware work")
    }

    private static func settingsRoundtrip() throws {
      let store = MemorySettings()
      let first = makeModel(store)
      var preferences = AgentPreferences.default
      preferences.claude.working = SignalRule(style: .custom, pattern: "15:0.2, 65:0.3")
      preferences.claude.completed = SignalRule(style: .steady)
      preferences.claude.completionSeconds = 0
      preferences.codex.working = SignalRule(style: .heartbeat)
      preferences.codex.completed = SignalRule(style: .custom, pattern: "100:0.1, 0:0.9")
      preferences.codex.completionSeconds = 15
      preferences.concurrent = .alternate
      preferences.priority = .codex
      preferences.alertsTakePriority = false
      preferences.rotationSeconds = 3.5
      first.agentPreferences = preferences
      first.mode = .agents
      first.brightness = 0.63
      first.speed = 1.8
      first.minimum = 0.11
      first.morseText = "ROUNDTRIP"
      first.customPattern = "20:0.5, 80:0.5"
      first.focusMinutes = 19
      first.dimOnLowPower = false
      first.setLogoPower(false)
      first.completeWelcome(startLighting: false)
      first.shutdown()

      let second = makeModel(store)
      defer { second.shutdown() }
      try expect(
        second.agentPreferences == preferences,
        "Independent provider or concurrency rules changed across restart")
      try expect(second.mode == .agents && !second.enabled, "Mode or power did not survive restart")
      try expect(
        second.brightness == 0.63 && second.speed == 1.8 && second.minimum == 0.11,
        "Lighting controls did not survive restart")
      try expect(
        second.morseText == "ROUNDTRIP" && second.customPattern == "20:0.5, 80:0.5",
        "Text settings did not survive restart")
      try expect(
        second.focusMinutes == 19 && second.focusRemaining == 1140 && !second.dimOnLowPower,
        "Focus or low-power settings did not survive restart")
      try expect(store.bool(forKey: "hasSeenWelcome"), "Welcome completion was lost")
      try expect(
        !second.isControlling && !second.hasPendingShutdownWork,
        "Reloading preview settings started hardware work")
    }

    private static func automationURLs() throws {
      let model = makeModel()
      defer { model.shutdown() }
      model.handleURL(URL(string: "lidglow://mode?name=heartbeat&brightness=0.42")!)
      try expect(
        model.mode == .heartbeat && model.brightness == 0.42, "Valid mode URL was not applied")
      for url in [
        "https://mode?name=steady&brightness=1",
        "lidglow://mode?name=unknown&brightness=nan",
        "lidglow://mode?brightness=inf",
        "lidglow://mode?name=steady&padding=" + String(repeating: "x", count: 5000),
        "lidglow://mode?name=steady&" + (0..<33).map { "key\($0)=x" }.joined(separator: "&"),
      ] {
        model.handleURL(URL(string: url)!)
        try expect(
          model.mode == .heartbeat && model.brightness == 0.42,
          "Invalid or oversized automation input changed the model")
      }
      model.handleURL(URL(string: "lidglow://mode?brightness=-5")!)
      try expect(model.brightness == 0, "Negative URL brightness escaped its lower bound")
      model.handleURL(URL(string: "lidglow://mode?brightness=10")!)
      try expect(model.brightness == 1, "URL brightness escaped its upper bound")
      model.handleURL(URL(string: "lidglow://off")!)
      try expect(!model.enabled, "Off URL did not switch the preview off")
      model.handleURL(URL(string: "lidglow://on")!)
      try expect(model.enabled, "On URL did not switch the preview on")
      model.focusMinutes = 3
      model.handleURL(URL(string: "lidglow://focus?minutes=nan")!)
      try expect(
        model.focusMinutes == 3 && model.focusRemaining.isFinite,
        "Nonfinite focus query changed the duration")
      model.handleURL(URL(string: "lidglow://focus?minutes=999999")!)
      try expect(
        model.mode == .focus && model.focusRunning && model.focusMinutes == 180,
        "Focus URL did not start a bounded session")
      try expect(
        !model.isControlling && !model.hasPendingShutdownWork,
        "Preview automation acquired hardware or helper work")
    }

    private static func repeatedShutdown() throws {
      let store = MemorySettings()
      let model = makeModel(store)
      model.setSurfaceVisible("checks", true)
      model.demoAgent("codex", state: .working)
      model.startFocus()
      model.installHooks("claude")
      model.removeHooks("codex")
      try expect(
        !model.installationBusy && !model.hasPendingShutdownWork,
        "Services-disabled model started a helper")
      model.shutdown()
      let writes = store.writes
      model.shutdown()
      model.shutdown()
      try expect(store.writes == writes, "Repeated shutdown wrote preferences again")
      try expect(
        !model.hasPendingShutdownWork && !model.isControlling,
        "Shutdown left hardware or helper work pending")
    }

  private static func concurrentSignals() throws {
    let model = makeModel()
    defer { model.shutdown() }
    model.brightness = 1
    model.minimum = 0.1
    model.dimOnLowPower = false
    model.setSurfaceVisible("checks", true)
    model.demoAgent("claude", state: .working)
    model.demoAgent("codex", state: .working)
    var rules = model.agentPreferences
    rules.priority = .claude
    model.agentPreferences = rules
    try expect(
      model.agentCaption.contains("Claude") && model.aggregateAgentState == .working,
      "The preferred working provider was not selected")
    rules.concurrent = .count
    model.agentPreferences = rules
    try expect(
      model.agentCaption.contains("2 tasks working") && model.agentCaption.contains("2 blinks"),
      "Concurrent task count did not reach the production preview")
    rules.concurrent = .priority
    rules.claude.completed.style = .steady
    rules.claude.completionSeconds = 30
    model.agentPreferences = rules
    model.demoAgent("claude", state: .complete)
    try expect(
      model.aggregateAgentState == .working && model.agentCaption.contains("Codex"),
      "Completion incorrectly hid another working provider")
    model.demoAgent("codex", state: .idle)
    try expect(
      model.aggregateAgentState == .complete && model.agentCaption.contains("Claude"),
      "Configured completion did not become visible after ongoing work ended")
    try expect(
      abs(model.output - 1) < 0.0001, "The configured steady completion did not reach the preview")
    model.clearDemo()
    try expect(
      model.aggregateAgentState == .idle && model.agentCaption.contains("No active"),
      "Clearing simulated signals did not restore the real idle state")
    try expect(
      !model.isControlling && !model.hasPendingShutdownWork, "Signal previews acquired hardware")
    model.setSurfaceVisible("checks", false)
  }
  }

#else
  import Darwin
  import Foundation
  @main
  private enum ReleaseChecksNotice {
    static func main() {
      print(
        "Run LidGlowAppChecks in the default debug configuration to test internal production state."
      )
      exit(64)
    }
  }
#endif
