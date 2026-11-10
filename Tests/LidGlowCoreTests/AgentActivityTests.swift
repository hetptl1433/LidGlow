import Foundation
import LidGlowCore

enum AgentActivityChecks {
  static func runAll() {
    Check.run(
      "Custom completion durations and persistent per-provider finish reset", testCompletionLeases)
  }
  private static func testCompletionLeases() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let completed = AgentSnapshot(
      source: "claude", sessionID: "one", state: .complete,
      timestamp: now.timeIntervalSince1970 - 10)
    var preferences = AgentPreferences.default
    Check.equal(
      AgentActivity.sessions(from: [completed], preferences: preferences, now: now).first?.state,
      .idle)
    preferences.claude.completionSeconds = 30
    Check.equal(
      AgentActivity.sessions(from: [completed], preferences: preferences, now: now).first?.state,
      .complete)
    preferences.claude.completionSeconds = 0
    Check.equal(
      AgentActivity.sessions(from: [completed], preferences: preferences, now: now).first?.state,
      .complete)
    let other = AgentSnapshot(
      source: "codex", sessionID: "other", state: .working, timestamp: now.timeIntervalSince1970)
    Check.equal(
      AgentActivity.sessions(from: [completed, other], preferences: preferences, now: now).first?
        .state, .complete)
    let newer = AgentSnapshot(
      source: "claude", sessionID: "new", state: .working, timestamp: now.timeIntervalSince1970)
    Check.equal(
      AgentActivity.sessions(from: [completed, newer], preferences: preferences, now: now).first?
        .state, .idle)
    let veryOld = AgentSnapshot(
      source: "claude", sessionID: "old", state: .complete,
      timestamp: now.timeIntervalSince1970 - 86401)
    Check.equal(
      AgentActivity.sessions(from: [veryOld], preferences: preferences, now: now).count, 0)
    let invalid = AgentSnapshot(
      source: "unknown", sessionID: "bad", state: .working, timestamp: now.timeIntervalSince1970)
    Check.equal(
      AgentActivity.sessions(from: [invalid], preferences: preferences, now: now).count, 0)
    preferences.codex.completionSeconds = 15
    let codexDone = AgentSnapshot(
      source: "codex", sessionID: "done", state: .complete,
      timestamp: now.timeIntervalSince1970 - 16)
    Check.equal(
      AgentActivity.sessions(from: [codexDone], preferences: preferences, now: now).first?.state,
      .idle)
  }
}
