import Foundation

/// Chooses work only while a physical effect or a visible preview needs frames.
public enum RuntimePolicy {
  public static func frameInterval(
    mode: LightMode, enabled: Bool, connected: Bool,
    visible: Bool, suspended: Bool, agent: AgentState,
    charging: Bool, focusFinished: Bool, lowPower: Bool, agentAnimated: Bool? = nil,
    brightness: Double = 1
  ) -> Double? {
    guard enabled, brightness.isFinite, brightness > 0, !suspended, connected || visible else {
      return nil
    }
    switch mode {
    case .steady: return nil
    case .battery where !charging: return nil
    case .focus where !focusFinished: return nil
    case .agents where !(agentAnimated ?? (agent != .idle && agent != .stale)): return nil
    default: return lowPower ? 1.0 / 12 : 1.0 / 20
    }
  }
}

public struct FocusClock {
  public private(set) var duration: TimeInterval = 1500
  public private(set) var pausedRemaining: TimeInterval = 1500
  public private(set) var deadline: Date?
  public private(set) var completedAt: Date?
  public var isRunning: Bool { deadline != nil }
  public init() {}

  public mutating func configure(minutes: Double) {
    let minutes = minutes.isFinite ? min(180, max(1, minutes)) : 25
    duration = minutes * 60
    reset()
  }
  public func remaining(at now: Date) -> TimeInterval {
    deadline.map { min(duration, max(0, $0.timeIntervalSince(now))) } ?? pausedRemaining
  }
  public func progress(at now: Date) -> Double { remaining(at: now) / max(1, duration) }
  public mutating func start(at now: Date) {
    guard !isRunning else { return }
    if pausedRemaining <= 0 { pausedRemaining = duration }
    deadline = now.addingTimeInterval(pausedRemaining)
    completedAt = nil
  }
  public mutating func pause(at now: Date) {
    pausedRemaining = remaining(at: now)
    deadline = nil
  }
  public mutating func reset() {
    deadline = nil
    completedAt = nil
    pausedRemaining = duration
  }
  @discardableResult
  public mutating func advance(to now: Date) -> Bool {
    guard let deadline, deadline <= now else { return false }
    self.deadline = nil
    pausedRemaining = 0
    completedAt = now
    return true
  }
}
