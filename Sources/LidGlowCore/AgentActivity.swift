import Foundation

/// Resolves stored events using the user's per-provider completion lease.
/// Persistent completion ends at the next event from that same provider.
public enum AgentActivity {
  public static func sessions(
    from snapshots: [AgentSnapshot], preferences: AgentPreferences, now: Date
  ) -> [AgentSignalSession] {
    let valid = snapshots.prefix(512).filter {
      $0.isValid(at: now) && now.timeIntervalSince1970 - $0.timestamp < 86400
    }
    var latest: [String: Double] = [:]
    for snapshot in valid {
      latest[snapshot.source] = max(latest[snapshot.source] ?? 0, snapshot.timestamp)
    }
    let normalized = preferences.normalized()
    return valid.map {
      let duration = normalized.rules(for: $0.source).completionSeconds
      var state = $0.effectiveState(at: now, completionDuration: duration == 0 ? 86400 : duration)
      if duration == 0 && state == .complete && (latest[$0.source] ?? 0) > $0.timestamp {
        state = .idle
      }
      return AgentSignalSession(
        id: $0.id, source: $0.source, state: state,
        timestamp: Date(timeIntervalSince1970: $0.timestamp))
    }
  }
}
