import Foundation

public enum LightMode: String, CaseIterable, Identifiable, Codable {
  case steady, breathe, pulse, heartbeat, agents, focus, battery, morse, custom
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .steady: return "Steady"
    case .breathe: return "Breathe"
    case .pulse: return "Pulse"
    case .heartbeat: return "Heartbeat"
    case .agents: return "Agent signal"
    case .focus: return "Focus timer"
    case .battery: return "Battery"
    case .morse: return "Morse code"
    case .custom: return "Your pattern"
    }
  }
  public var symbol: String {
    switch self {
    case .steady: return "sun.max"
    case .breathe: return "wind"
    case .pulse: return "waveform.path"
    case .heartbeat: return "heart"
    case .agents: return "sparkles"
    case .focus: return "timer"
    case .battery: return "battery.75percent"
    case .morse: return "ellipsis"
    case .custom: return "slider.horizontal.3"
    }
  }
  public var detail: String {
    switch self {
    case .steady: return "A little light, exactly how you like it."
    case .breathe: return "A slow inhale. A soft exhale."
    case .pulse: return "A clean, repeating flash."
    case .heartbeat: return "Two beats. One familiar glow."
    case .agents: return "Know when your AI is working, finished, or needs you."
    case .focus: return "Let the light count down your next deep work session."
    case .battery: return "Your remaining charge, at a glance."
    case .morse: return "Give your light something to say."
    case .custom: return "Write a rhythm of your own."
    }
  }
}

public enum AgentState: String, Codable, CaseIterable {
  case idle, working, attention, complete, error, stale
  public var title: String {
    switch self {
    case .idle: return "Ready"
    case .working: return "Working"
    case .attention: return "Needs you"
    case .complete: return "Finished"
    case .error: return "Error"
    case .stale: return "No recent signal"
    }
  }
  public var symbol: String {
    switch self {
    case .idle: return "circle.dotted"
    case .working: return "sparkles"
    case .attention: return "hand.raised"
    case .complete: return "checkmark.circle"
    case .error: return "exclamationmark.triangle"
    case .stale: return "clock.badge.questionmark"
    }
  }
  public var priority: Int {
    switch self {
    case .attention: return 5
    case .error: return 4
    case .working: return 3
    case .complete: return 2
    case .idle: return 1
    case .stale: return 0
    }
  }
}

public struct PatternStep: Equatable {
  public var level: Double
  public var duration: Double
  public init(level: Double, duration: Double) {
    self.level = level
    self.duration = duration
  }
}

public enum PatternError: Error, LocalizedError {
  case invalid
  public var errorDescription: String? {
    "Use up to 64 steps like 100:0.3, 0:0.2. Brightness is 0–100; duration is 0.05–20 seconds; total is at most 180 seconds."
  }
}

public enum Patterns {
  public static func parse(_ text: String) throws -> [PatternStep] {
    guard text.utf8.count <= 2048 else { throw PatternError.invalid }
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 64 else { throw PatternError.invalid }
    let steps = try parts.map { part -> PatternStep in
      let values = part.split(separator: ":", omittingEmptySubsequences: false)
      guard values.count == 2,
        let percent = Double(values[0].trimmingCharacters(in: .whitespacesAndNewlines)),
        let seconds = Double(values[1].trimmingCharacters(in: .whitespacesAndNewlines)),
        percent.isFinite, seconds.isFinite,
        (0...100).contains(percent), (0.05...20).contains(seconds)
      else { throw PatternError.invalid }
      return PatternStep(level: percent / 100, duration: seconds)
    }
    guard steps.reduce(0, { $0 + $1.duration }) <= 180 else { throw PatternError.invalid }
    return steps
  }

  public static func value(_ steps: [PatternStep], at elapsed: Double) -> Double {
    let duration = steps.reduce(0) { $0 + $1.duration }
    guard duration > 0, duration.isFinite, elapsed.isFinite else { return 0 }
    var position = max(0, elapsed).truncatingRemainder(dividingBy: duration)
    for step in steps {
      if position < step.duration { return min(1, max(0, step.level)) }
      position -= step.duration
    }
    return steps.last?.level ?? 0
  }

  private static let alphabet: [Character: String] = [
    "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.",
    "G": "--.", "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..",
    "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
    "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
    "Y": "-.--", "Z": "--..", "0": "-----", "1": ".----", "2": "..---",
    "3": "...--", "4": "....-", "5": ".....", "6": "-....", "7": "--...",
    "8": "---..", "9": "----.", ".": ".-.-.-", ",": "--..--", "?": "..--..", "!": "-.-.--",
  ]

  public static func morse(_ text: String) -> [PatternStep] {
    let words = InputLimits.text(text, characters: 160, utf8Bytes: 1024).uppercased().prefix(160)
      .split(whereSeparator: { $0.isWhitespace })
    var steps: [PatternStep] = []
    let unit = 0.18
    let validWords = words.map { $0.compactMap { alphabet[$0] } }.filter { !$0.isEmpty }
    for (wordIndex, letters) in validWords.enumerated() {
      for (letterIndex, code) in letters.enumerated() {
        for (symbolIndex, symbol) in code.enumerated() {
          steps.append(PatternStep(level: 1, duration: unit * (symbol == "." ? 1 : 3)))
          if symbolIndex < code.count - 1 { steps.append(PatternStep(level: 0, duration: unit)) }
        }
        if letterIndex < letters.count - 1 {
          steps.append(PatternStep(level: 0, duration: unit * 3))
        }
      }
      if wordIndex < validWords.count - 1 {
        steps.append(PatternStep(level: 0, duration: unit * 7))
      }
    }
    if !steps.isEmpty { steps.append(PatternStep(level: 0, duration: unit * 10)) }
    return steps
  }
}

public struct EffectInput {
  public var mode: LightMode = .breathe
  public var elapsed: Double = 0
  public var brightness: Double = 0.7
  public var minimum: Double = 0.06
  public var speed: Double = 1
  public var agentState: AgentState = .idle
  public var agentSource = "claude"
  public var focusProgress: Double = 1
  public var focusFinished = false
  public var batteryLevel: Double? = nil
  public var isCharging = false
  public var morse: [PatternStep] = []
  public var custom: [PatternStep] = []
  public init() {}
}

public enum EffectEngine {
  public static func value(_ input: EffectInput) -> Double {
    let t = max(0, input.elapsed.isFinite ? input.elapsed : 0) * clamp(input.speed, 0.25, 4)
    let floor = clamp(input.minimum)
    let wave: Double
    switch input.mode {
    case .steady: wave = 1
    case .breathe: wave = floor + (1 - floor) * (0.5 - 0.5 * cos(t * .pi / 2))
    case .pulse: wave = t.truncatingRemainder(dividingBy: 1.4) < 0.28 ? 1 : floor
    case .heartbeat: wave = heartbeat(t, floor: floor)
    case .agents:
      switch input.agentState {
      case .idle, .stale: wave = floor
      case .working:
        wave =
          input.agentSource == "codex"
          ? heartbeat(t, floor: floor) : floor + (1 - floor) * (0.5 - 0.5 * cos(t * .pi))
      case .attention: wave = flashes(t, count: 2, period: 2, floor: floor)
      case .complete: wave = flashes(t, count: 3, period: 3, floor: floor)
      case .error: wave = flashes(t, count: 3, period: 1.8, floor: floor)
      }
    case .focus:
      wave =
        input.focusFinished
        ? flashes(t, count: 3, period: 3, floor: floor)
        : floor + (1 - floor) * clamp(input.focusProgress)
    case .battery:
      if let charge = input.batteryLevel, charge.isFinite {
        let base = max(floor, clamp(charge))
        wave = input.isCharging ? base * (0.65 + 0.35 * (0.5 - 0.5 * cos(t * .pi / 2))) : base
      } else {
        wave = 0
      }
    case .morse: wave = Patterns.value(input.morse, at: t)
    case .custom: wave = Patterns.value(input.custom, at: t)
    }
    return clamp(wave * clamp(input.brightness))
  }

  private static func heartbeat(_ t: Double, floor: Double) -> Double {
    let p = t.truncatingRemainder(dividingBy: 1.8)
    let first = exp(-pow((p - 0.16) / 0.09, 2))
    let second = 0.75 * exp(-pow((p - 0.43) / 0.11, 2))
    return floor + (1 - floor) * min(1, first + second)
  }

  private static func flashes(_ t: Double, count: Int, period: Double, floor: Double) -> Double {
    let p = t.truncatingRemainder(dividingBy: period)
    for index in 0..<count {
      if p >= Double(index) * 0.28 && p < Double(index) * 0.28 + 0.13 { return 1 }
    }
    return floor
  }

  private static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
    value.isFinite ? min(upper, max(lower, value)) : lower
  }
}
