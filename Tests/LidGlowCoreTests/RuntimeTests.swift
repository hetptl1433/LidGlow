import Foundation
import LidGlowCore

enum RuntimeChecks {
  static func runAll() {
    Check.run("Hidden disconnected effects schedule no frame work", testHidden)
    Check.run("Steady, idle, disabled and suspended states schedule no frames", testIdle)
    Check.run("Low Power Mode reduces the necessary animation cadence", testLowPower)
    Check.run("Focus pause, resume, reconfigure and repeated start", testFocus)
    Check.run("Focus completes once after sleep and clamps invalid lengths", testFocusEdgeCases)
    Check.run("Pattern parser tolerates deterministic malformed input fuzzing", testPatternFuzz)
    Check.run("Input storage stays bounded even for a giant Unicode grapheme", testInputStorage)
  }
  private static func interval(
    _ mode: LightMode, enabled: Bool = true, connected: Bool = false, visible: Bool = true,
    suspended: Bool = false, state: AgentState = .working, charging: Bool = false,
    finished: Bool = false, lowPower: Bool = false
  ) -> Double? {
    RuntimePolicy.frameInterval(
      mode: mode, enabled: enabled, connected: connected, visible: visible, suspended: suspended,
      agent: state, charging: charging, focusFinished: finished, lowPower: lowPower)
  }
  private static func testHidden() {
    for mode in LightMode.allCases {
      Check.equal(interval(mode, visible: false, charging: true, finished: true), nil)
    }
    Check.isTrue(interval(.breathe, connected: true, visible: false) != nil)
  }
  private static func testIdle() {
    for mode in LightMode.allCases {
      Check.equal(
        interval(mode, enabled: false, connected: true, charging: true, finished: true), nil)
      Check.equal(
        interval(mode, connected: true, suspended: true, charging: true, finished: true), nil)
    }
    Check.equal(interval(.steady, connected: true), nil)
    Check.equal(interval(.agents, connected: true, state: .idle), nil)
    Check.equal(interval(.agents, connected: true, state: .stale), nil)
    Check.equal(interval(.focus, connected: true), nil)
    Check.equal(interval(.battery, connected: true), nil)
    Check.equal(
      RuntimePolicy.frameInterval(
        mode: .breathe, enabled: true, connected: true, visible: true, suspended: false,
        agent: .working, charging: false, focusFinished: false, lowPower: false, brightness: 0), nil
    )
    Check.isTrue(
      RuntimePolicy.frameInterval(
        mode: .agents, enabled: true, connected: true, visible: true, suspended: false,
        agent: .idle, charging: false, focusFinished: false, lowPower: false, agentAnimated: true)
        != nil)
    Check.equal(
      RuntimePolicy.frameInterval(
        mode: .agents, enabled: true, connected: true, visible: true, suspended: false,
        agent: .working, charging: false, focusFinished: false, lowPower: false,
        agentAnimated: false), nil)
  }
  private static func testLowPower() {
    Check.greaterThan(interval(.breathe, lowPower: true)!, interval(.breathe)!)
    Check.equal(interval(.breathe), 0.05)
    Check.isTrue(interval(.battery, charging: true) != nil)
    Check.isTrue(interval(.focus, finished: true) != nil)
  }
  private static func testFocus() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var focus = FocusClock()
    focus.configure(minutes: 10)
    focus.start(at: start)
    Check.equal(focus.remaining(at: start.addingTimeInterval(15)), 585)
    focus.start(at: start.addingTimeInterval(20))
    Check.equal(focus.remaining(at: start.addingTimeInterval(30)), 570)
    focus.pause(at: start.addingTimeInterval(30))
    Check.equal(focus.remaining(at: start.addingTimeInterval(200)), 570)
    focus.start(at: start.addingTimeInterval(200))
    Check.equal(focus.remaining(at: start.addingTimeInterval(210)), 560)
    focus.pause(at: start.addingTimeInterval(210))
    focus.configure(minutes: 25)
    Check.equal(focus.remaining(at: start.addingTimeInterval(220)), 1500)
    Check.isTrue(!focus.isRunning)
  }
  private static func testFocusEdgeCases() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var focus = FocusClock()
    for (input, expected) in [(Double.nan, 1500.0), (.infinity, 1500), (-10, 60), (999, 10800)] {
      focus.configure(minutes: input)
      Check.equal(focus.duration, expected)
    }
    focus.configure(minutes: 1)
    focus.start(at: start)
    Check.equal(focus.remaining(at: start.addingTimeInterval(-3600)), 60)
    Check.isTrue(focus.advance(to: start.addingTimeInterval(3600)))
    Check.isTrue(!focus.advance(to: start.addingTimeInterval(3601)))
    Check.equal(focus.remaining(at: start.addingTimeInterval(3601)), 0)
    focus.start(at: start.addingTimeInterval(4000))
    Check.equal(focus.remaining(at: start.addingTimeInterval(4000)), 60)
  }
  private static func testPatternFuzz() {
    let alphabet = Array("0123456789:,. -+eNaNInfinity😀\n")
    var seed: UInt64 = 0x6258193
    for _ in 0..<2000 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      let count = Int(seed % 120)
      var text = ""
      for _ in 0..<count {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        text.append(alphabet[Int(seed % UInt64(alphabet.count))])
      }
      if let steps = try? Patterns.parse(text) {
        Check.isTrue(steps.count <= 64)
        for step in steps {
          Check.isTrue(step.level.isFinite && (0...1).contains(step.level))
          Check.isTrue(step.duration.isFinite && (0.05...20).contains(step.duration))
        }
      }
    }
    Check.throwsError(try Patterns.parse(String(repeating: "100:0.1,", count: 500)))
  }
  private static func testInputStorage() throws {
    let text = "a" + String(repeating: "\u{0301}", count: 100_000)
    Check.equal(text.count, 1)
    let bounded = InputLimits.text(text, characters: 160, utf8Bytes: 1024)
    Check.isTrue(bounded.utf8.count <= 1024)
    Check.isTrue(!bounded.contains("\u{FFFD}"))
    Check.equal(InputLimits.text("hello", characters: 3, utf8Bytes: 100), "hel")
    Check.equal(InputLimits.text("😀", characters: 1, utf8Bytes: 3), "")
    var preferences = AgentPreferences.default
    preferences.claude.working.pattern = text
    preferences.codex.completed.pattern = text
    let normalized = preferences.normalized()
    Check.isTrue(normalized.claude.working.pattern.utf8.count <= 2048)
    let encoded = try JSONEncoder().encode(normalized)
    Check.isTrue(encoded.count < 65536)
    Check.throwsError(try Patterns.parse(text))
  }
}
