import Foundation

public enum SignalStyle: String, CaseIterable, Identifiable, Codable, Sendable {
  case off, dim, steady, breathe, pulse, heartbeat, doubleBlink, tripleBlink, custom
  public var id: String { rawValue }
  public var isAnimated: Bool {
    switch self {
    case .off, .dim, .steady: return false
    default: return true
    }
  }
  public var title: String {
    switch self {
    case .off: return "Off"
    case .dim: return "Dim"
    case .steady: return "Steady"
    case .breathe: return "Breathe"
    case .pulse: return "Pulse"
    case .heartbeat: return "Heartbeat"
    case .doubleBlink: return "Double blink"
    case .tripleBlink: return "Triple blink"
    case .custom: return "Custom pattern"
    }
  }
  public var symbol: String {
    switch self {
    case .off: return "power"
    case .dim: return "sun.min"
    case .steady: return "sun.max"
    case .breathe: return "wind"
    case .pulse: return "waveform.path"
    case .heartbeat: return "heart"
    case .doubleBlink: return "2.circle"
    case .tripleBlink: return "3.circle"
    case .custom: return "slider.horizontal.3"
    }
  }
  public init(from decoder: Decoder) throws {
    self =
      (try? decoder.singleValueContainer().decode(String.self)).flatMap(Self.init(rawValue:))
      ?? .off
  }
}

public enum ConcurrentBehavior: String, CaseIterable, Identifiable, Codable, Sendable {
  case priority, alternate, count
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .priority: return "Use priority"
    case .alternate: return "Alternate tasks"
    case .count: return "Blink task count"
    }
  }
  public var details: String {
    switch self {
    case .priority: return "Show your preferred provider, then its most recent task."
    case .alternate: return "Rotate through working sessions in a stable order."
    case .count: return "Blink once per working task, up to five blinks."
    }
  }
  public init(from decoder: Decoder) throws {
    self =
      (try? decoder.singleValueContainer().decode(String.self)).flatMap(Self.init(rawValue:))
      ?? .priority
  }
}

public enum AgentPriority: String, CaseIterable, Identifiable, Codable, Sendable {
  case mostRecent, claude, codex
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .mostRecent: return "Most recent task"
    case .claude: return "Prefer Claude"
    case .codex: return "Prefer Codex"
    }
  }
  public init(from decoder: Decoder) throws {
    self =
      (try? decoder.singleValueContainer().decode(String.self)).flatMap(Self.init(rawValue:))
      ?? .mostRecent
  }
}

public struct SignalRule: Codable, Equatable, Sendable {
  public static let defaultPattern = "100:0.2, 0:0.2, 40:0.6"
  public var style: SignalStyle
  public var pattern: String
  public init(style: SignalStyle = .steady, pattern: String = Self.defaultPattern) {
    self.style = style
    self.pattern = pattern
  }
  private enum CodingKeys: String, CodingKey { case style, pattern }
  public init(from decoder: Decoder) throws {
    self = Self.decode(decoder, fallback: SignalRule(style: .off))
  }
  fileprivate static func decode(_ decoder: Decoder, fallback: SignalRule) -> SignalRule {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return fallback }
    return SignalRule(
      style: (try? c.decode(SignalStyle.self, forKey: .style)) ?? fallback.style,
      pattern: (try? c.decode(String.self, forKey: .pattern)) ?? fallback.pattern)
  }
}

public struct ProviderRules: Codable, Equatable, Sendable {
  public var working: SignalRule
  public var completed: SignalRule
  public var attention: SignalRule
  public var error: SignalRule
  public var idle: SignalRule
  /// Zero retains completion until another event (the spool still has a 24h cap).
  public var completionSeconds: Double
  public init(
    working: SignalRule = SignalRule(style: .breathe),
    completed: SignalRule = SignalRule(style: .tripleBlink),
    attention: SignalRule = SignalRule(style: .doubleBlink),
    error: SignalRule = SignalRule(style: .tripleBlink),
    idle: SignalRule = SignalRule(style: .dim), completionSeconds: Double = 8
  ) {
    self.working = working
    self.completed = completed
    self.attention = attention
    self.error = error
    self.idle = idle
    self.completionSeconds = completionSeconds
  }
  public static let claudeDefault = ProviderRules()
  public static let codexDefault = ProviderRules(working: SignalRule(style: .heartbeat))
  public func rule(for state: AgentState) -> SignalRule {
    switch state {
    case .working: return working
    case .complete: return completed
    case .attention: return attention
    case .error: return error
    case .idle, .stale: return idle
    }
  }
  public func normalized() -> ProviderRules {
    var copy = self
    copy.completionSeconds = completionSeconds.isFinite ? min(86400, max(0, completionSeconds)) : 8
    copy.working.pattern = InputLimits.text(working.pattern, characters: 2048, utf8Bytes: 2048)
    copy.completed.pattern = InputLimits.text(completed.pattern, characters: 2048, utf8Bytes: 2048)
    copy.attention.pattern = InputLimits.text(attention.pattern, characters: 2048, utf8Bytes: 2048)
    copy.error.pattern = InputLimits.text(error.pattern, characters: 2048, utf8Bytes: 2048)
    copy.idle.pattern = InputLimits.text(idle.pattern, characters: 2048, utf8Bytes: 2048)
    return copy
  }
  private enum CodingKeys: String, CodingKey {
    case working, completed, attention, error, idle, completionSeconds
  }
  public init(from decoder: Decoder) throws {
    self = Self.decode(decoder, fallback: .claudeDefault)
  }
  fileprivate static func decode(_ decoder: Decoder, fallback: ProviderRules) -> ProviderRules {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return fallback }
    func rule(_ key: CodingKeys, _ fallback: SignalRule) -> SignalRule {
      guard c.contains(key), let nested = try? c.superDecoder(forKey: key) else { return fallback }
      return SignalRule.decode(nested, fallback: fallback)
    }
    return ProviderRules(
      working: rule(.working, fallback.working), completed: rule(.completed, fallback.completed),
      attention: rule(.attention, fallback.attention), error: rule(.error, fallback.error),
      idle: rule(.idle, fallback.idle),
      completionSeconds: (try? c.decode(Double.self, forKey: .completionSeconds))
        ?? fallback.completionSeconds
    ).normalized()
  }
}

public struct AgentPreferences: Codable, Equatable, Sendable {
  public var claude: ProviderRules
  public var codex: ProviderRules
  public var priority: AgentPriority
  public var concurrent: ConcurrentBehavior
  public var alertsTakePriority: Bool
  public var rotationSeconds: Double
  public static let `default` = AgentPreferences()
  public init(
    claude: ProviderRules = .claudeDefault, codex: ProviderRules = .codexDefault,
    priority: AgentPriority = .mostRecent, concurrent: ConcurrentBehavior = .priority,
    alertsTakePriority: Bool = true, rotationSeconds: Double = 2
  ) {
    self.claude = claude
    self.codex = codex
    self.priority = priority
    self.concurrent = concurrent
    self.alertsTakePriority = alertsTakePriority
    self.rotationSeconds = rotationSeconds
  }
  /// Custom/unknown event sources use the Claude rule set as the fallback.
  public func rules(for source: String) -> ProviderRules { source == "codex" ? codex : claude }
  public func normalized() -> AgentPreferences {
    var copy = self
    copy.claude = claude.normalized()
    copy.codex = codex.normalized()
    copy.rotationSeconds = rotationSeconds.isFinite ? min(10, max(0.5, rotationSeconds)) : 2
    return copy
  }
  private enum CodingKeys: String, CodingKey {
    case claude, codex, priority, concurrent, alertsTakePriority, rotationSeconds
  }
  public init(from decoder: Decoder) throws {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
      self = .default
      return
    }
    func provider(_ key: CodingKeys, _ fallback: ProviderRules) -> ProviderRules {
      guard c.contains(key), let nested = try? c.superDecoder(forKey: key) else { return fallback }
      return ProviderRules.decode(nested, fallback: fallback)
    }
    self.init(
      claude: provider(.claude, .claudeDefault), codex: provider(.codex, .codexDefault),
      priority: (try? c.decode(AgentPriority.self, forKey: .priority)) ?? .mostRecent,
      concurrent: (try? c.decode(ConcurrentBehavior.self, forKey: .concurrent)) ?? .priority,
      alertsTakePriority: (try? c.decode(Bool.self, forKey: .alertsTakePriority)) ?? true,
      rotationSeconds: (try? c.decode(Double.self, forKey: .rotationSeconds)) ?? 2)
    self = normalized()
  }
}

public struct AgentSignalSession: Equatable {
  public var id: String
  public var source: String
  public var state: AgentState
  public var timestamp: Date
  public init(id: String, source: String, state: AgentState, timestamp: Date) {
    self.id = id
    self.source = source
    self.state = state
    self.timestamp = timestamp
  }
}

public struct AgentSignalOutput: Equatable {
  public var level: Double
  public var state: AgentState
  public var source: String
  public var activeCount: Int
  public var caption: String
  public var isAnimated: Bool
  public init(
    level: Double, state: AgentState, source: String, activeCount: Int, caption: String,
    isAnimated: Bool = false
  ) {
    self.level = level
    self.state = state
    self.source = source
    self.activeCount = activeCount
    self.caption = caption
    self.isAnimated = isAnimated
  }
}

/// Immutable settings snapshot. Patterns are compiled here once, never per frame.
/// Default/priority rendering makes one bounded scan and no session-array copies.
public struct AgentSignalRenderer {
  private let preferences: AgentPreferences
  private let claude: CompiledProvider
  private let codex: CompiledProvider
  public init(preferences: AgentPreferences = .default) {
    self.preferences = preferences.normalized()
    claude = CompiledProvider(self.preferences.claude)
    codex = CompiledProvider(self.preferences.codex)
  }
  public func render(
    sessions: [AgentSignalSession], now: Date, elapsed: Double,
    brightness: Double, minimum: Double, speed: Double
  ) -> AgentSignalOutput {
    // Leases and completion durations belong to ActivityReader/AppModel. This
    // renderer obeys the effective state supplied by that layer.
    _ = now
    var working: AgentSignalSession?
    var alert: AgentSignalSession?
    var other: AgentSignalSession?
    var count = 0
    var alternating: [AgentSignalSession] = []
    if preferences.concurrent == .alternate { alternating.reserveCapacity(min(32, sessions.count)) }
    for session in sessions.prefix(256) {
      switch session.state {
      case .working:
        count += 1
        if preferred(session, over: working) { working = session }
        if preferences.concurrent == .alternate { alternating.append(session) }
      case .attention, .error:
        if preferred(session, over: alert, compareState: true) { alert = session }
      case .complete, .idle, .stale:
        if preferred(session, over: other, compareState: true) { other = session }
      }
    }
    let peak = Self.clamp(brightness)
    let floor = Self.clamp(minimum)
    let speed = speed.isFinite ? min(4, max(0.25, speed)) : 1
    let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
    let selected: AgentSignalSession
    let isWorking: Bool
    if let alert, preferences.alertsTakePriority || working == nil {
      selected = alert
      isWorking = false
    } else if let working {
      if count > 1, preferences.concurrent == .alternate {
        alternating.sort(by: Self.stableOrder)
        let cycle = preferences.rotationSeconds * Double(count)
        let position = elapsed.truncatingRemainder(dividingBy: cycle)
        let index = min(count - 1, Int(position / preferences.rotationSeconds))
        selected = alternating[index]
      } else {
        selected = working
      }
      isWorking = true
    } else if let other {
      selected = other
      isWorking = false
    } else {
      let level = claude.idle.value(
        elapsed: elapsed, peak: peak, floor: floor, speed: speed, state: .idle)
      return AgentSignalOutput(
        level: level, state: .idle, source: "", activeCount: 0,
        caption: "No active agent sessions", isAnimated: claude.idle.isAnimated)
    }
    let label = Self.label(selected.source)
    let rule = (selected.source == "codex" ? codex : claude).rule(selected.state)
    let level: Double
    let caption: String
    if isWorking, count > 1, preferences.concurrent == .count {
      let blinks = min(5, count)
      level =
        Self.flashes(
          elapsed, count: blinks, period: Double(blinks) * 0.28 + 1.5,
          speed: speed, floor: floor) * peak
      caption = "\(count) tasks working · \(blinks) blinks"
    } else {
      level = rule.value(
        elapsed: elapsed, peak: peak, floor: floor, speed: speed, state: selected.state)
      caption =
        count > 1
        ? "\(label) · \(selected.state.title) · \(count) tasks working"
        : "\(label) · \(selected.state.title)"
    }
    return AgentSignalOutput(
      level: Self.clamp(level), state: selected.state, source: selected.source,
      activeCount: count, caption: caption,
      isAnimated: rule.isAnimated || isWorking && count > 1 && preferences.concurrent != .priority)
  }

  private func preferred(
    _ candidate: AgentSignalSession, over current: AgentSignalSession?, compareState: Bool = false
  ) -> Bool {
    guard let current else { return true }
    if compareState, candidate.state != current.state {
      return candidate.state.priority > current.state.priority
    }
    func rank(_ source: String) -> Int {
      switch preferences.priority {
      case .mostRecent: return 0
      case .claude: return source == "claude" ? 1 : 0
      case .codex: return source == "codex" ? 1 : 0
      }
    }
    if rank(candidate.source) != rank(current.source) {
      return rank(candidate.source) > rank(current.source)
    }
    let a = candidate.timestamp.timeIntervalSince1970
    let b = current.timestamp.timeIntervalSince1970
    let left = a.isFinite ? a : -Double.infinity
    let right = b.isFinite ? b : -Double.infinity
    if left != right { return left > right }
    return Self.stableOrder(candidate, current)
  }
  private static func stableOrder(_ a: AgentSignalSession, _ b: AgentSignalSession) -> Bool {
    if a.source != b.source { return a.source < b.source }
    if a.id != b.id { return a.id < b.id }
    let x = a.timestamp.timeIntervalSince1970
    let y = b.timestamp.timeIntervalSince1970
    return (x.isFinite ? x : -Double.infinity) < (y.isFinite ? y : -Double.infinity)
  }
  private static func label(_ source: String) -> String {
    switch source {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "custom": return "Custom"
    default: return "Agent"
    }
  }
  private static func clamp(_ number: Double) -> Double {
    number.isFinite ? min(1, max(0, number)) : 0
  }
  private static func flashes(
    _ elapsed: Double, count: Int, period: Double, speed: Double, floor: Double
  ) -> Double {
    let phase = elapsed.truncatingRemainder(dividingBy: period / speed) * speed
    for i in 0..<count where phase >= Double(i) * 0.28 && phase < Double(i) * 0.28 + 0.13 {
      return 1
    }
    return floor
  }
  private struct CompiledRule {
    let style: SignalStyle
    let pattern: [PatternStep]
    let duration: Double
    let isAnimated: Bool
    init(_ rule: SignalRule) {
      style = rule.style
      let parsed = rule.style == .custom ? ((try? Patterns.parse(rule.pattern)) ?? []) : []
      pattern = parsed
      duration = parsed.reduce(0) { $0 + $1.duration }
      let firstLevel = parsed.first?.level
      isAnimated =
        rule.style == .custom ? parsed.contains { $0.level != firstLevel } : rule.style.isAnimated
    }
    func value(elapsed: Double, peak: Double, floor: Double, speed: Double, state: AgentState)
      -> Double
    {
      switch style {
      case .off: return 0
      case .dim: return floor * peak
      case .steady: return peak
      case .custom: return customValue(elapsed: elapsed, speed: speed) * peak
      case .doubleBlink:
        return AgentSignalRenderer.flashes(elapsed, count: 2, period: 2, speed: speed, floor: floor)
          * peak
      case .tripleBlink:
        return AgentSignalRenderer.flashes(
          elapsed, count: 3, period: state == .error ? 1.8 : 3, speed: speed, floor: floor) * peak
      case .breathe, .pulse, .heartbeat:
        var input = EffectInput()
        let period: Double
        switch style {
        case .breathe:
          input.mode = .breathe
          period = 4
        case .pulse:
          input.mode = .pulse
          period = 1.4
        default:
          input.mode = .heartbeat
          period = 1.8
        }
        input.elapsed = elapsed.truncatingRemainder(dividingBy: period / speed)
        input.speed = speed
        input.brightness = peak
        input.minimum = floor
        return EffectEngine.value(input)
      }
    }
    private func customValue(elapsed: Double, speed: Double) -> Double {
      guard duration > 0 else { return 0 }
      var position = elapsed.truncatingRemainder(dividingBy: duration / speed) * speed
      for step in pattern {
        if position < step.duration { return step.level }
        position -= step.duration
      }
      return pattern.last?.level ?? 0
    }
  }
  private struct CompiledProvider {
    let working, completed, attention, error, idle: CompiledRule
    init(_ rules: ProviderRules) {
      working = CompiledRule(rules.working)
      completed = CompiledRule(rules.completed)
      attention = CompiledRule(rules.attention)
      error = CompiledRule(rules.error)
      idle = CompiledRule(rules.idle)
    }
    func rule(_ state: AgentState) -> CompiledRule {
      switch state {
      case .working: return working
      case .complete: return completed
      case .attention: return attention
      case .error: return error
      case .idle, .stale: return idle
      }
    }
  }
}
