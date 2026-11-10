import Foundation
import LidGlowCore

final class EffectsChecks {
  func testEveryEffectStaysInsideConfiguredPeak() {
    for mode in LightMode.allCases {
      for state in AgentState.allCases {
        var input = EffectInput()
        input.mode = mode
        input.agentState = state
        input.brightness = 0.43
        input.morse = Patterns.morse("SOS")
        input.custom = try! Patterns.parse("100:0.1, 25:0.2, 0:0.1")
        for frame in 0..<400 {
          input.elapsed = Double(frame) * 0.037
          let value = EffectEngine.value(input)
          Check.isTrue(value.isFinite)
          Check.isTrue((0...0.43).contains(value), "\(mode) / \(state): \(value)")
        }
      }
    }
  }

  func testCustomPatternBoundariesAndLoop() throws {
    let steps = try Patterns.parse("100:0.5,0:0.5,50:1")
    Check.equal(Patterns.value(steps, at: 0.1), 1)
    Check.equal(Patterns.value(steps, at: 0.6), 0)
    Check.equal(Patterns.value(steps, at: 1.5), 0.5)
    Check.equal(Patterns.value(steps, at: 2.1), 1)
  }

  func testInvalidPatternsFailClosed() {
    for text in [
      "", "100:0", "101:1", "0:-1", "nan:1", "10:inf", "10:1,", "10:1:2",
      String(repeating: "50:20,", count: 10) + "50:20",
    ] {
      Check.throwsError(try Patterns.parse(text), text)
    }
    Check.equal(Patterns.value([], at: 1), 0)
  }

  func testMorseUsesInternationalTimingAndDropsUnsupportedCharacters() {
    let sos = Patterns.morse("S O S")
    Check.equal(sos.filter { $0.level == 1 }.count, 9)
    Check.equal(sos.filter { $0.level == 0 && abs($0.duration - 1.26) < 0.0001 }.count, 2)
    Check.equal(Patterns.morse("😀"), [])
    Check.equal(Patterns.morse("E").first?.duration, 0.18)
    Check.equal(Patterns.morse("T").first?.duration, 0.54)
  }

  func testAgentPatternsAreDistinctAndAttentionWins() {
    var input = EffectInput()
    input.mode = .agents
    input.agentState = .working
    input.elapsed = 0.4
    input.agentSource = "claude"
    let claude = EffectEngine.value(input)
    input.agentSource = "codex"
    Check.notEqual(EffectEngine.value(input), claude)
    Check.greaterThan(AgentState.attention.priority, AgentState.working.priority)
    Check.greaterThan(AgentState.working.priority, AgentState.complete.priority)
  }

  func testBatteryUnknownDoesNotPretendToBeFull() {
    var input = EffectInput()
    input.mode = .battery
    input.brightness = 1
    Check.equal(EffectEngine.value(input), 0)
    input.batteryLevel = 0.2
    Check.equal(EffectEngine.value(input), 0.2)
  }
}
