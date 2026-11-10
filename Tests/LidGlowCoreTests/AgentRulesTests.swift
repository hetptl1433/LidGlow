import Foundation
import LidGlowCore

enum AgentRulesChecks {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static func runAll() {
    Check.run(
      "Agent rule defaults preserve provider identities and exact static styles",
      testDefaultsAndStyles)
    Check.run("Running sessions beat completion and provider priority breaks ties", testPriority)
    Check.run("Attention/error priority can yield to running sessions", testAlerts)
    Check.run(
      "Each provider and effective state uses its configured signal", testProviderStateRules)
    Check.run("Alternation is stable across reordered and same-provider sessions", testAlternate)
    Check.run("Concurrent count blinks match task count with a readable five-blink cap", testCount)
    Check.run(
      "Custom patterns compile as immutable renderer settings and fail dark", testCustomPatterns)
    Check.run("All agent signal styles stay finite and within the selected peak", testBounds)
    Check.run("Agent preferences round-trip and tolerate unknown saved values", testPersistence)
    Check.run(
      "Agent timing settings normalize and renderer work is bounded", testNormalizationAndBound)
  }
  private static func session(
    _ id: String, _ source: String, _ state: AgentState = .working, age: Double = 0
  ) -> AgentSignalSession {
    AgentSignalSession(
      id: id, source: source, state: state, timestamp: now.addingTimeInterval(-age))
  }
  private static func render(
    _ preferences: AgentPreferences = .default, _ sessions: [AgentSignalSession],
    elapsed: Double = 0.4,
    brightness: Double = 0.8, minimum: Double = 0.1, speed: Double = 1
  ) -> AgentSignalOutput {
    AgentSignalRenderer(preferences: preferences).render(
      sessions: sessions, now: now, elapsed: elapsed,
      brightness: brightness, minimum: minimum, speed: speed)
  }

  private static func testDefaultsAndStyles() {
    Check.equal(AgentPreferences.default.claude.working.style, .breathe)
    Check.equal(AgentPreferences.default.codex.working.style, .heartbeat)
    Check.equal(AgentPreferences.default.claude.completionSeconds, 8)
    Check.notEqual(
      render(.default, [session("c", "claude")]).level,
      render(.default, [session("x", "codex")]).level)
    var p = AgentPreferences.default
    for (style, expected) in [(SignalStyle.off, 0.0), (.dim, 0.08), (.steady, 0.8)] {
      p.claude.working.style = style
      Check.isTrue(abs(render(p, [session("one", "claude")]).level - expected) < 0.000001)
      Check.isTrue(!render(p, [session("one", "claude")]).isAnimated)
    }
    p.claude.idle.style = .steady
    let empty = render(p, [])
    Check.equal(empty.activeCount, 0)
    Check.equal(empty.state, .idle)
    Check.equal(empty.level, 0.8)
    Check.isTrue(!empty.isAnimated)
    p.claude.idle = SignalRule(style: .custom, pattern: "100:0.5,0:0.5")
    Check.isTrue(render(p, [], elapsed: 0.1).isAnimated)
    Check.notEqual(render(p, [], elapsed: 0.1).level, render(p, [], elapsed: 0.6).level)
  }

  private static func testPriority() {
    var p = AgentPreferences.default
    let older = session("old", "claude", age: 200)
    let newer = session("new", "codex")
    let completed = session("done", "claude", .complete, age: -10)
    Check.equal(render(p, [older, completed, newer]).source, "codex")
    Check.equal(render(p, [older, completed, newer]).state, .working)
    p.priority = .claude
    Check.equal(render(p, [older, completed, newer]).source, "claude")
    p.priority = .codex
    Check.equal(render(p, [older, completed, newer]).source, "codex")
    p.priority = .mostRecent
    let tied = [session("z", "codex"), session("a", "claude")]
    Check.equal(render(p, tied), render(p, Array(tied.reversed())))
    Check.equal(render(p, tied).source, "claude")
    let sameProvider = [session("a", "claude", age: 10), session("b", "claude")]
    Check.equal(render(p, sameProvider).activeCount, 2)
    Check.equal(render(p, sameProvider), render(p, Array(sameProvider.reversed())))
  }

  private static func testAlerts() {
    let rows = [
      session("work", "codex"), session("error", "codex", .error),
      session("attention", "claude", .attention, age: 20),
    ]
    var p = AgentPreferences.default
    Check.equal(render(p, rows).state, .attention)
    Check.equal(render(p, rows).activeCount, 1)
    p.alertsTakePriority = false
    Check.equal(render(p, rows).state, .working)
    Check.equal(render(p, Array(rows.dropFirst())).state, .attention)
    Check.equal(
      render(p, [session("error", "claude", .error), session("done", "codex", .complete)]).state,
      .error)
    Check.equal(
      render(p, [session("idle", "claude", .idle), session("done", "codex", .complete)]).state,
      .complete)
    Check.equal(
      render(p, [session("stale", "claude", .stale), session("idle", "codex", .idle)]).state, .idle)
  }

  private static func testProviderStateRules() {
    var p = AgentPreferences.default
    p.claude = ProviderRules(
      working: custom(10), completed: custom(20), attention: custom(30), error: custom(40),
      idle: custom(50))
    p.codex = ProviderRules(
      working: custom(60), completed: custom(70), attention: custom(80), error: custom(90),
      idle: custom(100))
    let expected: [AgentState: Double] = [
      .working: 0.1, .complete: 0.2, .attention: 0.3, .error: 0.4, .idle: 0.5, .stale: 0.5,
    ]
    for (state, base) in expected {
      let claude = render(p, [session("s", "claude", state)], brightness: 1)
      let codex = render(p, [session("s", "codex", state)], brightness: 1)
      Check.equal(claude.state, state)
      Check.isTrue(abs(claude.level - base) < 0.000001)
      Check.isTrue(abs(codex.level - (base + 0.5)) < 0.000001)
    }
    // The caller supplies effective states: the renderer must not independently
    // expire a persistent completion or a long-running live session.
    Check.equal(render(p, [session("old-done", "claude", .complete, age: 10000)]).state, .complete)
    Check.equal(p.rules(for: "custom"), p.claude)
    Check.equal(p.claude.rule(for: .stale), p.claude.idle)
  }

  private static func testAlternate() {
    var p = AgentPreferences.default
    p.concurrent = .alternate
    p.rotationSeconds = 2
    let rows = [session("x", "codex"), session("z", "claude"), session("a", "claude")]
    for (time, source) in [
      (0.0, "claude"), (1.99, "claude"), (2.0, "claude"), (4.0, "codex"), (6.0, "claude"),
    ] {
      let output = render(p, rows, elapsed: time)
      Check.equal(output.source, source)
      Check.equal(output.activeCount, 3)
      Check.isTrue(output.isAnimated)
      Check.equal(output, render(p, Array(rows.reversed()), elapsed: time))
    }
    p.rotationSeconds = 0
    Check.equal(
      render(p, [session("x", "codex"), session("c", "claude")], elapsed: 0.5).source, "codex")
    Check.isTrue(render(p, rows, elapsed: Double.greatestFiniteMagnitude).level.isFinite)
  }

  private static func testCount() {
    var p = AgentPreferences.default
    p.concurrent = .count
    let two = [session("a", "claude"), session("b", "codex")]
    for t in [0.05, 0.33, 2.11] { Check.equal(render(p, two, elapsed: t, brightness: 1).level, 1) }
    for t in [0.2, 0.48, 1.0, 2.0] {
      Check.equal(render(p, two, elapsed: t, brightness: 1).level, 0.1)
    }
    let many = (0..<7).map { session("task-\($0)", "claude") }
    for t in [0.05, 0.33, 0.61, 0.89, 1.17] {
      Check.equal(render(p, many, elapsed: t, brightness: 1).level, 1)
    }
    let capped = render(p, many, elapsed: 1.45, brightness: 1)
    Check.equal(capped.level, 0.1)
    Check.equal(capped.activeCount, 7)
    Check.isTrue(capped.caption.contains("5 blinks"))
    Check.isTrue(capped.isAnimated)
    let attention = many + [session("need", "codex", .attention)]
    Check.equal(render(p, attention).state, .attention)
  }

  private static func custom(_ percent: Int) -> SignalRule {
    SignalRule(style: .custom, pattern: "\(percent):1")
  }
  private static func testCustomPatterns() {
    var p = AgentPreferences.default
    p.claude.working = SignalRule(style: .custom, pattern: "100:0.5,0:0.5")
    let renderer = AgentSignalRenderer(preferences: p)
    p.claude.working.pattern = "0:1"
    let rows = [session("a", "claude")]
    Check.equal(
      renderer.render(sessions: rows, now: now, elapsed: 0.1, brightness: 1, minimum: 0, speed: 1)
        .level, 1)
    Check.equal(
      renderer.render(sessions: rows, now: now, elapsed: 0.6, brightness: 1, minimum: 0, speed: 1)
        .level, 0)
    Check.equal(render(p, rows, elapsed: 0.1, brightness: 1).level, 0)
    for invalid in [
      "", "100:0", "nan:1", "10:inf", "101:1", "10:1,", String(repeating: "100:1,", count: 100),
    ] {
      p.claude.working.pattern = invalid
      Check.equal(render(p, rows, brightness: 1).level, 0)
      Check.isTrue(!render(p, rows, brightness: 1).isAnimated)
    }
  }

  private static func testBounds() {
    for style in SignalStyle.allCases {
      var p = AgentPreferences.default
      let rule = SignalRule(style: style, pattern: "100:0.1,0:0.1,40:0.2")
      p.claude = ProviderRules(
        working: rule, completed: rule, attention: rule, error: rule, idle: rule)
      p.codex = p.claude
      let renderer = AgentSignalRenderer(preferences: p)
      for state in AgentState.allCases {
        for i in 0..<160 {
          let output = renderer.render(
            sessions: [session("one", i % 2 == 0 ? "claude" : "codex", state)], now: now,
            elapsed: Double(i) * 0.073, brightness: 0.43, minimum: 0.06, speed: 1.7)
          Check.isTrue(
            output.level.isFinite && (0...0.43).contains(output.level),
            "\(style) / \(state): \(output.level)")
        }
      }
      for number in [Double.nan, .infinity, -.infinity, -100, Double.greatestFiniteMagnitude] {
        let output = renderer.render(
          sessions: [session("one", "claude")], now: now, elapsed: number,
          brightness: number, minimum: number, speed: number)
        Check.isTrue(output.level.isFinite && (0...1).contains(output.level))
      }
    }
  }

  private static func testPersistence() throws {
    var p = AgentPreferences.default
    p.claude.working = SignalRule(style: .custom, pattern: "25:1,75:1")
    p.codex.completed.style = .off
    p.claude.completionSeconds = 0
    p.priority = .codex
    p.concurrent = .alternate
    p.rotationSeconds = 0.7
    p.alertsTakePriority = false
    Check.equal(try JSONDecoder().decode(AgentPreferences.self, from: JSONEncoder().encode(p)), p)
    let partial = Data(
      "{\"codex\":{\"completed\":{\"style\":\"steady\"}},\"priority\":\"future-provider\",\"concurrent\":\"future-mode\",\"claude\":{\"working\":{\"style\":\"future-style\"}}}"
        .utf8)
    let restored = try JSONDecoder().decode(AgentPreferences.self, from: partial)
    Check.equal(restored.codex.working.style, .heartbeat)
    Check.equal(restored.codex.completed.style, .steady)
    Check.equal(restored.claude.working.style, .off)
    Check.equal(restored.priority, .mostRecent)
    Check.equal(restored.concurrent, .priority)
    Check.equal(try JSONDecoder().decode(AgentPreferences.self, from: Data("{}".utf8)), .default)
    Check.equal(try JSONDecoder().decode(AgentPreferences.self, from: Data("[1,2]".utf8)), .default)
    let malformedFields = try JSONDecoder().decode(
      AgentPreferences.self,
      from: Data(
        "{\"claude\":null,\"codex\":42,\"rotationSeconds\":\"bad\",\"alertsTakePriority\":\"bad\"}"
          .utf8))
    Check.equal(malformedFields, .default)
  }

  private static func testNormalizationAndBound() {
    var p = AgentPreferences.default
    p.claude.completionSeconds = .infinity
    p.codex.completionSeconds = -1
    p.rotationSeconds = .nan
    Check.equal(p.normalized().claude.completionSeconds, 8)
    Check.equal(p.normalized().codex.completionSeconds, 0)
    Check.equal(p.normalized().rotationSeconds, 2)
    p.claude.completionSeconds = 1e9
    p.rotationSeconds = 100
    Check.equal(p.normalized().claude.completionSeconds, 86400)
    Check.equal(p.normalized().rotationSeconds, 10)
    p.concurrent = .count
    let many = (0..<300).map { session("\($0)", "claude") }
    let output = render(p, many)
    Check.equal(output.activeCount, 256)
    Check.isTrue(output.level.isFinite)
  }
}
