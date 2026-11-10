import AppKit
import LidGlowCore
import QuartzCore
import SwiftUI

extension Color {
  static let lidAmber = Color(red: 1.0, green: 0.70, blue: 0.35)
  static let lidCanvas = Color(red: 0.055, green: 0.060, blue: 0.070)
  static let lidPanel = Color(red: 0.095, green: 0.103, blue: 0.116)
  static let lidMuted = Color(red: 0.57, green: 0.60, blue: 0.65)
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @ViewState(initialValue: Optional<IntegrationGuideSelection>.none) private var setupGuide:
    IntegrationGuideSelection?
  @ViewState(initialValue: "claude") private var rulesProvider: String
  @ViewState(initialValue: false) private var showingAdvancedRules: Bool

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header
          connectionBanner
          previewAndControls
          modeContent
          preferences
        }
        .padding(30)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
      }
      .background(Color.lidCanvas)
    }
    .frame(minWidth: 880, minHeight: 660)
    .preferredColorScheme(.dark)
    .tint(.lidAmber)
    .background(WindowVisibility { model.setSurfaceVisible("main", $0) })
    .onDisappear { model.setSurfaceVisible("main", false) }
    .sheet(isPresented: $model.showWelcome) {
      LightingWelcomeView(model: model)
    }
    .sheet(item: $setupGuide) { selection in
      IntegrationSetupGuide(model: model, initialSource: selection.source)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "sun.max.fill")
          .font(.system(size: 23, weight: .medium))
          .foregroundStyle(Color.lidAmber)
          .shadow(color: .lidAmber.opacity(0.3), radius: 9)
        Text("LidGlow")
          .font(.system(size: 23, weight: .semibold, design: .rounded))
          .tracking(-0.5)
      }
      .padding(.bottom, 7)
      Text("A little light. Your way.")
        .font(.system(size: 11))
        .foregroundStyle(Color.lidMuted)
        .padding(.bottom, 31)

      smallHeading("LIGHT MODES")
        .padding(.leading, 10)
        .padding(.bottom, 10)
      ForEach(LightMode.allCases) { mode in
        modeButton(mode)
      }
      Spacer(minLength: 28)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Circle()
            .fill(model.isControlling ? Color.lidAmber : Color.lidMuted)
            .frame(width: 6, height: 6)
          Text(lightingStateText)
            .font(.system(size: 11, weight: .medium))
        }
        Text("White light. Endless rhythm.")
          .font(.system(size: 10))
          .foregroundStyle(Color.lidMuted)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
      Button { openWindow(id: "about") } label: {
        VStack(alignment: .leading, spacing: 5) {
          Text("About LidGlow").font(.system(size: 10))
          Text("HET PATEL")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(2)
        }
        .foregroundStyle(Color.lidMuted.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.top, 16)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 17)
    .padding(.top, 30)
    .padding(.bottom, 20)
    .frame(width: 196)
    .background(Color(red: 0.073, green: 0.080, blue: 0.092))
  }

  private func modeButton(_ mode: LightMode) -> some View {
    let selected = model.mode == mode
    return Button {
      model.mode = mode
    } label: {
      HStack(spacing: 12) {
        Image(systemName: mode.symbol)
          .font(.system(size: 14, weight: selected ? .semibold : .regular))
          .frame(width: 18)
        Text(mode.title)
          .font(.system(size: 12, weight: selected ? .semibold : .medium))
        Spacer(minLength: 0)
        if selected {
          Circle().fill(Color.lidAmber).frame(width: 4, height: 4)
        }
      }
      .foregroundStyle(selected ? Color.lidAmber : Color.white.opacity(0.62))
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .background(
        selected ? Color.lidAmber.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9)
      )
      .contentShape(RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .padding(.vertical, 2)
    .accessibilityLabel("\(mode.title) light mode")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 7) {
        smallHeading("YOUR MAC, IN A NEW LIGHT")
        Text(model.mode.title)
          .font(.system(size: 30, weight: .semibold))
          .tracking(-0.7)
        Text(model.mode.detail)
          .font(.system(size: 12))
          .foregroundStyle(Color.lidMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 16)
      VStack(alignment: .trailing, spacing: 8) {
        smallHeading("LIDGLOW")
          Toggle(model.isLidGlowEnabled ? "On" : "Off", isOn: lightPower)
            .toggleStyle(.switch)
            .font(.system(size: 12, weight: .medium))
            .accessibilityLabel("LidGlow")
            .accessibilityValue(model.isLidGlowEnabled ? "On" : "Off")
            .disabled(model.isRestoringHardware || model.needsLightingReset)
        Text(model.isLidGlowEnabled ? "Your chosen effect" : "Mac automatic")
          .font(.system(size: 10)).foregroundStyle(Color.lidMuted)
      }
      .padding(.top, 8)
    }
  }

  private var lightPower: Binding<Bool> {
    Binding(get: { model.isLidGlowEnabled }, set: { model.setLidGlowEnabled($0) })
  }

  private var usingMacLighting: Bool { model.isUsingSystemLighting && model.hardwareAvailable }

  private var lightingStateText: String {
    if model.isRestoringHardware { return "Restoring…" }
    if model.needsLightingReset { return "Reset needed" }
    if usingMacLighting { return "Mac lighting" }
    if !model.isControlling { return "Preview mode" }
    return model.enabled ? "Light is on" : "Light is off"
  }

  private var connectionBanner: some View {
    HStack(spacing: 12) {
      Image(
        systemName: model.needsLightingReset
          ? "exclamationmark.circle" : (usingMacLighting ? "laptopcomputer" : "sun.max")
      )
      .font(.system(size: 17))
      .foregroundStyle(model.isControlling ? Color.lidAmber : Color.lidMuted)
      VStack(alignment: .leading, spacing: 4) {
        Text(lightingTitle)
          .font(.system(size: 12, weight: .medium))
        Text(lightingMessage)
          .font(.system(size: 10))
          .foregroundStyle(Color.lidMuted)
          .fixedSize(horizontal: false, vertical: true)
        Text("Quitting restores Mac lighting.")
          .font(.system(size: 9))
          .foregroundStyle(Color.lidMuted.opacity(0.8))
      }
      Spacer(minLength: 12)
      if model.isRestoringHardware || model.needsLightingReset {
        Button(
          model.isRestoringHardware ? "Restoring…" : "Reset lighting",
          action: model.useSystemLighting
        )
        .buttonStyle(QuietButtonStyle())
        .disabled(model.isRestoringHardware)
      }
      Menu {
        Button("Use Mac’s automatic lighting", action: model.useSystemLighting)
        Divider()
        Button("Quick guide") { model.showWelcome = true }
      } label: {
        Image(systemName: "ellipsis").foregroundStyle(Color.lidMuted)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(model.isRestoringHardware)
      .accessibilityLabel("Lighting options")
      .help("Choose automatic Mac lighting or reset the logo.")
    }
    .padding(14)
    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.055)))
  }

  private var lightingTitle: String {
    if model.isRestoringHardware { return "Resetting your lighting…" }
    if model.needsLightingReset { return "Your lighting needs a reset" }
    if !model.hardwareAvailable { return "Explore your light onscreen" }
    if usingMacLighting { return "Mac is managing your logo" }
    return model.enabled ? "Your logo is on" : "Your logo is off"
  }

  private var lightingMessage: String {
    if model.needsLightingReset { return model.hardwareStatus }
    if let notice = model.lightingNotice { return notice }
    if !model.hardwareAvailable {
      return "Try every mode in the preview. Your logo is not available right now."
    }
    if usingMacLighting {
      return "LidGlow is off. macOS handles your logo automatically."
    }
    return "Choose a mode and make it your own. Brightness responds to ambient light."
  }

  private var previewAndControls: some View {
    HStack(alignment: .top, spacing: 16) {
      OutputPreviewPanel(
        preview: model.preview, connected: model.isControlling, enabled: model.enabled,
        caption: outputCaption
      )
      .frame(maxWidth: .infinity)

      Panel {
        VStack(alignment: .leading, spacing: 21) {
          sliderControl(
            "Brightness", symbol: "sun.max", value: $model.brightness, range: 0...1,
            displayed: "\(Int((model.brightness * 100).rounded()))%")
          if model.mode != .steady && model.mode != .battery && model.mode != .focus {
            sliderControl(
              "Speed", symbol: "speedometer", value: $model.speed, range: 0.5...3,
              displayed: String(format: "%.1f×", model.speed))
          }
          if [.breathe, .pulse, .heartbeat, .agents].contains(model.mode) {
            sliderControl(
              "Resting glow", symbol: "moon", value: $model.minimum, range: 0...1,
              displayed: "\(Int((model.minimum * 100).rounded()))%")
          } else {
            Divider().overlay(Color.white.opacity(0.025))
            Text(controlHint)
              .font(.system(size: 11))
              .foregroundStyle(Color.lidMuted)
              .lineSpacing(4)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
        .frame(minHeight: 222, alignment: .top)
      }
      .frame(width: 232)
    }
  }

  private var outputCaption: String {
    let prefix = model.isControlling ? "" : "Preview · "
    guard model.enabled else { return prefix + "Light is off" }
    if model.mode == .agents { return prefix + model.agentCaption }
    if model.mode == .focus {
      return model.focusRunning
        ? "Your focus session is running"
        : (model.focusPaused
          ? "Focus session paused"
          : (model.focusCompleted ? "Focus session finished" : "Ready when you are"))
    }
    return model.isControlling ? "Playing on your MacBook logo" : "Previewing on screen"
  }

  private var controlHint: String {
    switch model.mode {
    case .steady:
      return "A constant glow, at just the right level. Your screen brightness stays independent."
    case .battery:
      return "The glow follows your charge. Brightness sets the highest level it can reach."
    case .focus:
      return "The glow counts down with you. A gentle signal marks the end of your session."
    case .morse:
      return "Brightness sets the flash intensity. Speed changes the time between dots and dashes."
    case .custom:
      return "Create a looping sequence below. Each step sets a brightness and a duration."
    default: return "Make the light feel like yours. Changes appear in the preview immediately."
    }
  }

  private func sliderControl(
    _ title: String, symbol: String, value: Binding<Double>, range: ClosedRange<Double>,
    displayed: String
  ) -> some View {
    VStack(spacing: 11) {
      HStack(spacing: 7) {
        Image(systemName: symbol).foregroundStyle(Color.lidMuted).frame(width: 14)
        Text(title).fontWeight(.medium)
        Spacer()
        Text(displayed)
          .foregroundStyle(Color.lidAmber)
          .monospacedDigit()
      }
      .font(.system(size: 11))
      Slider(value: value, in: range)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityValue(displayed)
    }
  }

  @ViewBuilder private var modeContent: some View {
    switch model.mode {
    case .agents: agentsPanel
    case .focus: focusPanel
    case .battery: batteryPanel
    case .morse: morsePanel
    case .custom: customPanel
    default: presetsPanel
    }
  }

  private var agentsPanel: some View {
    VStack(alignment: .leading, spacing: 16) {
      Panel {
        VStack(alignment: .leading, spacing: 17) {
          HStack {
            panelTitle(
              "Your agents, at a glance",
              subtitle: "Choose what the light does when your agents work or finish.")
            Spacer()
            statePill(model.aggregateAgentState)
            Button {
              setupGuide = IntegrationGuideSelection(source: rulesProvider)
            } label: {
              Image(systemName: "questionmark.circle").foregroundStyle(Color.lidMuted)
            }
            .buttonStyle(.plain)
            .help("Agent setup guide")
            .accessibilityLabel("Open agent setup guide")
          }
          HStack(spacing: 12) {
            integrationTile(
              source: "claude", title: "Claude Code", installed: model.claudeInstalled,
              symbol: "asterisk")
            integrationTile(
              source: "codex", title: "Codex", installed: model.codexInstalled, symbol: "terminal")
          }
          if model.sessions.contains(where: { $0.isDemo }) {
            HStack {
              Label("Simulated signals are active", systemImage: "play.circle")
                .foregroundStyle(Color.lidAmber)
              Spacer()
              Button("Clear simulations", action: model.clearDemo)
                .buttonStyle(.link)
            }
            .font(.system(size: 10))
          }
        }
      }
      agentRulesPanel
      concurrentTasksPanel
      if !model.sessions.isEmpty { sessionsPanel }
      if !model.activity.isEmpty { activityPanel }
    }
  }

  private func integrationTile(source: String, title: String, installed: Bool, symbol: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(Color.lidAmber)
        Text(title).font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 2)
        Circle().fill(installed ? Color.lidAmber : Color.lidMuted.opacity(0.5)).frame(
          width: 5, height: 5)
      }
      Text(installed ? "Hooks added" : "Not set up yet")
        .font(.system(size: 10))
        .foregroundStyle(Color.lidMuted)
      HStack {
        Button(installed ? "Manage" : "Set up") {
          setupGuide = IntegrationGuideSelection(source: source)
        }
        .buttonStyle(QuietButtonStyle())
        Spacer(minLength: 3)
        Menu {
          Button("Working") { model.demoAgent(source, state: .working) }
          Button("Finished") { model.demoAgent(source, state: .complete) }
          Button("Needs your attention") { model.demoAgent(source, state: .attention) }
          Button("Error") { model.demoAgent(source, state: .error) }
        } label: {
          Label("Try a signal", systemImage: "play.circle")
            .font(.system(size: 10))
            .foregroundStyle(Color.lidMuted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Simulate a \(title) signal")
        .accessibilityLabel("Simulate a \(title) signal")
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.04)))
  }

  private var providerRules: Binding<ProviderRules> {
    Binding(
      get: {
        model.agentPreferences.rules(for: rulesProvider)
      },
      set: { updated in
        var preferences = model.agentPreferences
        if rulesProvider == "codex" {
          preferences.codex = updated
        } else {
          preferences.claude = updated
        }
        model.agentPreferences = preferences
      })
  }

  private func signalRule(_ keyPath: WritableKeyPath<ProviderRules, SignalRule>) -> Binding<
    SignalRule
  > {
    Binding(
      get: { providerRules.wrappedValue[keyPath: keyPath] },
      set: { updated in
        var rules = providerRules.wrappedValue
        rules[keyPath: keyPath] = updated
        providerRules.wrappedValue = rules
      })
  }

  private var completionDuration: Binding<Double> {
    Binding(
      get: { providerRules.wrappedValue.completionSeconds },
      set: { updated in
        var rules = providerRules.wrappedValue
        rules.completionSeconds = updated
        providerRules.wrappedValue = rules
      })
  }

  private var keepFinishedSignal: Binding<Bool> {
    Binding(
      get: { completionDuration.wrappedValue == 0 },
      set: { keep in
        completionDuration.wrappedValue = keep ? 0 : 8
      })
  }

  private var agentRulesPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top) {
          panelTitle("Choose your signals", subtitle: "Each agent can have its own rhythm.")
          Spacer()
          Button("Restore defaults") {
            providerRules.wrappedValue = rulesProvider == "codex" ? .codexDefault : .claudeDefault
          }
          .buttonStyle(.link)
          .font(.system(size: 10))
        }
        Picker("Agent", selection: $rulesProvider) {
          Text("Claude Code").tag("claude")
          Text("Codex").tag("codex")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Agent to customize")
        .frame(maxWidth: 320)
        SignalRuleEditor(
          title: "Working", subtitle: "While a task is running", rule: signalRule(\.working))
        SignalRuleEditor(
          title: "Finished", subtitle: "When a task completes", rule: signalRule(\.completed))
        Divider().overlay(Color.white.opacity(0.025))
        completionSettings
        DisclosureGroup(isExpanded: $showingAdvancedRules) {
          VStack(alignment: .leading, spacing: 18) {
            SignalRuleEditor(
              title: "Needs you", subtitle: "A request for your attention",
              rule: signalRule(\.attention))
            SignalRuleEditor(
              title: "Error", subtitle: "When an agent reports a failure", rule: signalRule(\.error)
            )
            SignalRuleEditor(title: "Idle", subtitle: "Between tasks", rule: signalRule(\.idle))
          }
          .padding(.top, 16)
        } label: {
          Text("More activity signals").font(.system(size: 11, weight: .medium))
        }
      }
    }
  }

  private var completionSettings: some View {
    VStack(alignment: .leading, spacing: 13) {
      Toggle("Keep finished signal until next activity", isOn: keepFinishedSignal)
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
      if completionDuration.wrappedValue > 0 {
        HStack(spacing: 12) {
          Text("Show finished signal for")
            .font(.system(size: 11))
            .foregroundStyle(Color.lidMuted)
          Picker("Finished signal duration", selection: completionDuration) {
            Text("8 seconds").tag(8.0)
            Text("15 seconds").tag(15.0)
            Text("30 seconds").tag(30.0)
            Text("Until next activity").tag(0.0)
            if ![0.0, 8, 15, 30].contains(completionDuration.wrappedValue) {
              Text("\(Int(completionDuration.wrappedValue)) seconds").tag(
                completionDuration.wrappedValue)
            }
          }
          .labelsHidden()
          .frame(width: 150)
          Stepper(value: completionDuration, in: 1...60, step: 1) {
            Text("Adjust duration")
          }
          .labelsHidden()
          .fixedSize()
          .accessibilityLabel("Adjust finished signal duration in seconds")
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var concurrentTasksPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 17) {
        panelTitle("When several tasks run", subtitle: "Decide which signal gets the spotlight.")
        HStack {
          Text("Show").font(.system(size: 11)).foregroundStyle(Color.lidMuted)
          Spacer()
          Picker("When several tasks run", selection: $model.agentPreferences.concurrent) {
            ForEach(ConcurrentBehavior.allCases) { behavior in
              Text(behavior.title).tag(behavior)
            }
          }
          .labelsHidden()
          .frame(width: 215)
        }
        Text(model.agentPreferences.concurrent.details)
          .font(.system(size: 10))
          .foregroundStyle(Color.lidMuted)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Text("Prefer").font(.system(size: 11)).foregroundStyle(Color.lidMuted)
          Spacer()
          Picker("Preferred agent", selection: $model.agentPreferences.priority) {
            ForEach(AgentPriority.allCases) { priority in
              Text(priority.title).tag(priority)
            }
          }
          .labelsHidden()
          .frame(width: 215)
        }
        if model.agentPreferences.concurrent == .alternate {
          Stepper(value: $model.agentPreferences.rotationSeconds, in: 0.5...10, step: 0.5) {
            Text(
              "Switch every \(model.agentPreferences.rotationSeconds, specifier: "%.1f") seconds"
            )
            .font(.system(size: 11))
          }
          .fixedSize()
        }
        Toggle(
          "Always show requests for attention first",
          isOn: $model.agentPreferences.alertsTakePriority
        )
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        if model.agentPreferences.concurrent == .count {
          Text("One white light uses short pulses to show the number of working tasks, up to five.")
            .font(.system(size: 10))
            .foregroundStyle(Color.lidMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var sessionsPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 13) {
        smallHeading("CURRENT SESSIONS")
        ForEach(model.sessions.prefix(6)) { session in
          HStack(spacing: 9) {
            Image(systemName: session.state.symbol)
              .font(.system(size: 11))
              .foregroundStyle(Color.lidAmber)
              .frame(width: 14)
            Text(session.source == "claude" ? "Claude Code" : session.source.capitalized)
              .font(.system(size: 11, weight: .medium))
            if session.isDemo {
              Text("SIMULATED")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.lidAmber)
            }
            Spacer()
            Text(session.state.title).font(.system(size: 10)).foregroundStyle(Color.lidMuted)
          }
        }
      }
    }
  }

  private var activityPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 13) {
        smallHeading("RECENT SIGNALS")
        ForEach(model.activity.prefix(4)) { entry in
          HStack(spacing: 10) {
            Image(systemName: entry.state.symbol)
              .font(.system(size: 10))
              .foregroundStyle(Color.lidAmber)
              .frame(width: 14)
            Text(entry.title).font(.system(size: 11))
            Spacer()
            Text(entry.time, style: .time)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(Color.lidMuted)
          }
        }
      }
    }
  }

  private var focusPanel: some View {
    Panel {
      HStack(spacing: 26) {
        ZStack {
          Circle().stroke(Color.white.opacity(0.06), lineWidth: 5)
          Circle()
            .trim(from: 0, to: max(0, min(1, model.focusProgress)))
            .stroke(Color.lidAmber, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(-90))
          VStack(spacing: 4) {
            Text(focusTime)
              .font(.system(size: 26, weight: .light, design: .rounded))
              .monospacedDigit()
            Text(
              model.focusRunning
                ? "FOCUSING"
                : (model.focusPaused ? "PAUSED" : (model.focusCompleted ? "DONE" : "READY"))
            )
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(Color.lidMuted)
          }
        }
        .frame(width: 118, height: 118)
        VStack(alignment: .leading, spacing: 14) {
          panelTitle(
            "Find your flow", subtitle: "A quiet countdown, with a light signal when you're done.")
          HStack(spacing: 12) {
            Text("Session length").font(.system(size: 11)).foregroundStyle(Color.lidMuted)
            Stepper(value: $model.focusMinutes, in: 1...180, step: 1) {
              Text("\(Int(model.focusMinutes)) min")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .fixedSize()
            .disabled(model.focusRunning)
          }
          HStack(spacing: 10) {
            Button(
              model.focusRunning
                ? "Pause session" : (model.focusPaused ? "Resume focus" : "Start focus")
            ) {
              if model.focusRunning { model.pauseFocus() } else { model.startFocus() }
            }
            .buttonStyle(AmberButtonStyle())
            Button("Reset", action: model.resetFocus)
              .buttonStyle(QuietButtonStyle())
          }
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var focusTime: String {
    let seconds = max(0, Int(model.focusRemaining))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  private var batteryPanel: some View {
    Panel {
      HStack(spacing: 23) {
        Image(
          systemName: model.batteryLevel == nil
            ? "questionmark.circle" : (model.isCharging ? "battery.100percent.bolt" : batterySymbol)
        )
        .font(.system(size: 49, weight: .ultraLight))
        .foregroundStyle(Color.lidAmber)
        .frame(width: 100)
        VStack(alignment: .leading, spacing: 10) {
          panelTitle(
            model.batteryDescription, subtitle: "Your logo becomes an ambient charge indicator.")
          Text("Full battery, fuller glow. As your charge drops, the light gently dims.")
            .font(.system(size: 11))
            .foregroundStyle(Color.lidMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var batterySymbol: String {
    let level = model.batteryLevel ?? 1
    if level < 0.15 { return "battery.0percent" }
    if level < 0.4 { return "battery.25percent" }
    if level < 0.7 { return "battery.50percent" }
    if level < 0.9 { return "battery.75percent" }
    return "battery.100percent"
  }

  private var morsePanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 15) {
        panelTitle(
          "Say it with light", subtitle: "Turn a short message into a repeating Morse signal.")
        TextField("Enter a message", text: $model.morseText)
          .textFieldStyle(.plain)
          .font(.system(size: 18, weight: .medium, design: .monospaced))
          .padding(14)
          .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
          .accessibilityLabel("Morse code message")
        HStack(spacing: 16) {
          Label("Dot = short flash", systemImage: "circle.fill")
          Label("Dash = long flash", systemImage: "minus")
          Spacer()
          Button("Try SOS") { model.morseText = "SOS" }
            .buttonStyle(.link)
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.lidMuted)
      }
    }
  }

  private var customPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 14) {
        panelTitle(
          "Compose your own glow",
          subtitle: "Add steps as brightness percent : seconds, separated by commas.")
        TextEditor(text: $model.customPattern)
          .font(.system(size: 13, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(9)
          .frame(height: 65)
          .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
          .accessibilityLabel("Custom light pattern")
        HStack(spacing: 10) {
          Text("TRY A PATTERN")
            .font(.system(size: 8, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Color.lidMuted)
          Button("Double blink") { model.customPattern = "100:0.15, 0:0.15, 100:0.15, 0:1.5" }
          Button("Slow steps") { model.customPattern = "20:1, 40:1, 60:1, 80:1, 100:1, 0:1" }
          Spacer(minLength: 0)
        }
        .buttonStyle(QuietButtonStyle())
        if let error = model.patternError {
          patternError(error)
        } else {
          Text("100:0.5 means full brightness for half a second. Your pattern loops automatically.")
            .font(.system(size: 10))
            .foregroundStyle(Color.lidMuted)
        }
      }
    }
  }

  private func patternError(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
      .font(.system(size: 11))
      .foregroundStyle(Color.lidAmber)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var presetsPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 16) {
        panelTitle(
          "Make yourself comfortable",
          subtitle: "A few starting points. Every setting is yours to adjust.")
        HStack(spacing: 10) {
          presetButton(
            "Quiet desk", symbol: "moon.stars", brightness: 0.25, speed: 0.65, minimum: 0.08)
          presetButton("Everyday", symbol: "sun.haze", brightness: 0.6, speed: 1.5, minimum: 0.15)
          presetButton(
            "Make a statement", symbol: "sparkles", brightness: 1, speed: 1.7, minimum: 0.04)
        }
      }
    }
  }

  private func presetButton(
    _ title: String, symbol: String, brightness: Double, speed: Double, minimum: Double
  ) -> some View {
    Button {
      model.brightness = brightness
      model.speed = speed
      model.minimum = minimum
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 16))
          .foregroundStyle(Color.lidAmber.opacity(0.85))
        Text(title).font(.system(size: 10, weight: .medium))
        Text("\(Int(brightness * 100))% brightness")
          .font(.system(size: 9))
          .foregroundStyle(Color.lidMuted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
      .contentShape(RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain)
  }

  private var preferences: some View {
    VStack(alignment: .leading, spacing: 10) {
    HStack(spacing: 15) {
      Toggle("Start at login", isOn: Binding(
        get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
        .toggleStyle(.checkbox)
        .font(.system(size: 10))
      Toggle(isOn: $model.dimOnLowPower) {
        HStack(spacing: 7) {
          Image(systemName: "leaf").foregroundStyle(Color.lidMuted)
          Text("Dim in Low Power Mode")
        }
      }
      .toggleStyle(.checkbox)
      .font(.system(size: 10))
      Spacer()
      Button {
        model.copyAutomationCommand()
      } label: {
        Label("Copy automation command", systemImage: "terminal")
      }
      .buttonStyle(.link)
      .font(.system(size: 10))
    }
    if let message = model.loginItemMessage {
      HStack {
        Text(message).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        Button("Open Login Items", action: model.openLoginItemSettings).buttonStyle(.link)
      }
    }
    }
    .foregroundStyle(Color.lidMuted)
    .padding(.horizontal, 2)
    .padding(.bottom, 4)
  }

  private func smallHeading(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold))
      .tracking(1.3)
      .foregroundStyle(Color.lidMuted)
  }

  private func panelTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 14, weight: .semibold))
      Text(subtitle)
        .font(.system(size: 11))
        .foregroundStyle(Color.lidMuted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func statePill(_ state: AgentState) -> some View {
    Label(state.title, systemImage: state.symbol)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(Color.lidAmber)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(Color.lidAmber.opacity(0.09), in: Capsule())
  }
}

private struct OutputPreviewPanel: View {
  @ObservedObject var preview: PreviewState
  let connected: Bool
  let enabled: Bool
  let caption: String
  var body: some View {
    Panel {
      VStack(spacing: 16) {
        HStack {
          Text(connected ? "LIVE OUTPUT" : "LIGHT PREVIEW")
            .font(.system(size: 9, weight: .semibold)).tracking(1.3)
          Spacer()
          Text("\(Int((preview.level * 100).rounded()))%")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
        }.foregroundStyle(Color.lidMuted)
        LidPreview(level: preview.level).frame(height: 178).accessibilityHidden(true)
        HStack(spacing: 5) {
          Circle().fill(enabled ? Color.lidAmber : Color.lidMuted).frame(width: 4, height: 4)
          Text(caption).font(.system(size: 10)).foregroundStyle(Color.lidMuted)
        }
      }
    }
  }
}

private struct SignalRuleEditor: View {
  let title: String
  let subtitle: String
  @Binding var rule: SignalRule
  @ViewState(initialValue: Optional<String>.none) private var validationMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 12, weight: .medium))
          Text(subtitle).font(.system(size: 10)).foregroundStyle(Color.lidMuted)
        }
        Spacer(minLength: 10)
        Picker("\(title) signal", selection: $rule.style) {
          ForEach(SignalStyle.allCases) { style in
            Label(style.title, systemImage: style.symbol).tag(style)
          }
        }
        .labelsHidden()
        .frame(width: 190)
        .accessibilityLabel("\(title) signal style")
      }
      if rule.style == .custom {
        TextField("100:0.2, 0:0.5", text: $rule.pattern)
          .font(.system(size: 11, design: .monospaced))
          .textFieldStyle(.plain)
          .padding(11)
          .background(Color.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 7))
          .accessibilityLabel("\(title) custom pattern")
        if let validationMessage {
          Label(validationMessage, systemImage: "exclamationmark.circle")
            .font(.system(size: 10))
            .foregroundStyle(Color.lidAmber)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            "Brightness percent : seconds. For example, 100:0.2 is a full flash for 0.2 seconds."
          )
          .font(.system(size: 9))
          .foregroundStyle(Color.lidMuted)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear(perform: validatePattern)
    .onChange(of: rule.pattern) { _, _ in validatePattern() }
    .onChange(of: rule.style) { _, _ in validatePattern() }
  }

  /// Validate on editing events. The preview frame loop never parses text.
  private func validatePattern() {
    guard rule.style == .custom else {
      validationMessage = nil
      return
    }
    do {
      _ = try Patterns.parse(rule.pattern)
      validationMessage = nil
    } catch {
      validationMessage = error.localizedDescription
    }
  }
}

/// Cached layers keep the settings hierarchy and expensive blur layout out of
/// the frame loop. Only composited opacity changes for each visible frame.
private struct LidPreview: NSViewRepresentable {
  let level: Double
  func makeNSView(context: Context) -> Artwork { Artwork() }
  func updateNSView(_ nsView: Artwork, context: Context) { nsView.setLevel(level) }
  final class Artwork: NSView {
    private let lid = CAGradientLayer()
    private let base = CAGradientLayer()
    private let logo = CATextLayer()
    private let glow = CATextLayer()
    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      lid.colors = [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.13, alpha: 1).cgColor]
      lid.startPoint = CGPoint(x: 0, y: 1)
      lid.endPoint = CGPoint(x: 1, y: 0)
      lid.cornerRadius = 12
      lid.borderWidth = 1
      lid.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
      base.colors = [
        NSColor(white: 0.22, alpha: 1).cgColor, NSColor(white: 0.12, alpha: 1).cgColor,
      ]
      base.cornerRadius = 2
      for text in [glow, logo] {
        text.string = NSAttributedString(
          string: "",
          attributes: [.font: NSFont.systemFont(ofSize: 66), .foregroundColor: NSColor.white])
        text.alignmentMode = .center
        text.contentsScale = 2
        text.shouldRasterize = true
        text.rasterizationScale = 2
      }
      glow.shadowColor = NSColor.white.cgColor
      glow.shadowOpacity = 0.8
      glow.shadowRadius = 22
      glow.shadowOffset = .zero
      layer?.addSublayer(lid)
      layer?.addSublayer(base)
      layer?.addSublayer(glow)
      layer?.addSublayer(logo)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
      super.layout()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      let width = max(0, min(268, bounds.width - 12))
      let x = (bounds.width - width) / 2
      lid.frame = CGRect(x: x, y: 12, width: width, height: 161)
      base.frame = CGRect(x: x - 4, y: 4, width: width + 8, height: 4)
      logo.frame = CGRect(x: x, y: 52, width: width, height: 84)
      glow.frame = logo.frame
      CATransaction.commit()
    }
    func setLevel(_ level: Double) {
      let value = min(1, max(0, level))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      logo.opacity = Float(0.035 + value * 0.965)
      glow.opacity = Float(value * 0.4)
      CATransaction.commit()
    }
  }
}

private struct MenuLogo: View {
  @ObservedObject var preview: PreviewState
  var body: some View {
    Text("").font(.system(size: 40))
      .foregroundStyle(Color.white.opacity(0.06 + preview.level * 0.94))
      .frame(width: 54, height: 52)
      .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct Panel<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.lidPanel, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.055)))
  }
}

private struct QuietButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.6 : 0.84))
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        Color.white.opacity(configuration.isPressed ? 0.1 : 0.055),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.055)))
      .opacity(isEnabled ? 1 : 0.35)
  }
}

private struct AmberButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Color.lidCanvas)
      .padding(.horizontal, 15)
      .padding(.vertical, 9)
      .background(
        Color.lidAmber.opacity(configuration.isPressed ? 0.75 : 1),
        in: RoundedRectangle(cornerRadius: 7))
  }
}

struct MenuBarView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @ViewState(initialValue: Optional<IntegrationGuideSelection>.none) private var setupGuide:
    IntegrationGuideSelection?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Image(systemName: "sun.max.fill")
          .foregroundStyle(Color.lidAmber)
        Text("LidGlow").font(.system(size: 15, weight: .semibold, design: .rounded))
        Spacer()
          Toggle(
            model.isLidGlowEnabled ? "On" : "Off",
            isOn: Binding(get: { model.isLidGlowEnabled }, set: { model.setLidGlowEnabled($0) })
          )
          .toggleStyle(.switch)
          .controlSize(.mini)
          .font(.system(size: 10))
          .accessibilityLabel("LidGlow")
          .accessibilityValue(model.isLidGlowEnabled ? "On" : "Off")
          .disabled(model.isRestoringHardware || model.needsLightingReset)
      }
      HStack(alignment: .center, spacing: 14) {
        MenuLogo(preview: model.preview)
        VStack(alignment: .leading, spacing: 5) {
          Text(model.mode.title).font(.system(size: 12, weight: .medium))
          Text(statusText)
            .font(.system(size: 10))
            .foregroundStyle(Color.lidMuted)
        }
        Spacer()
      }
      Picker("Mode", selection: $model.mode) {
        ForEach(LightMode.allCases) { mode in
          Label(mode.title, systemImage: mode.symbol).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .font(.system(size: 11))
      VStack(spacing: 7) {
        HStack {
          Text("Brightness")
          Spacer()
          Text("\(Int((model.brightness * 100).rounded()))%").monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.lidMuted)
        Slider(value: $model.brightness, in: 0...1)
          .controlSize(.small)
          .accessibilityLabel("Logo brightness")
      }
      HStack {
        if model.isRestoringHardware || model.needsLightingReset {
          Button(
            model.isRestoringHardware ? "Restoring…" : "Reset lighting",
            action: model.useSystemLighting
          )
          .buttonStyle(QuietButtonStyle())
          .disabled(model.isRestoringHardware)
        }
        Spacer()
        Menu {
          Button("Use Mac’s automatic lighting", action: model.useSystemLighting)
          Divider()
          Button("Set up Claude Code…") { setupGuide = IntegrationGuideSelection(source: "claude") }
          Button("Set up Codex…") { setupGuide = IntegrationGuideSelection(source: "codex") }
          Button("More help", action: model.openHooksHelp)
        } label: {
          Image(systemName: "questionmark.circle").foregroundStyle(Color.lidMuted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isRestoringHardware)
        .accessibilityLabel("Lighting options and setup guides")
      }
      Divider()
      HStack {
        Button("Open LidGlow") {
          openWindow(id: "main")
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .buttonStyle(.plain)
        Spacer()
        Button("About") { openWindow(id: "about") }.buttonStyle(.plain)
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain)
          .foregroundStyle(Color.lidMuted)
      }
      .font(.system(size: 11))
    }
    .padding(20)
    .frame(width: 310)
    .background(Color.lidCanvas)
    .preferredColorScheme(.dark)
    .tint(.lidAmber)
    .background(WindowVisibility { model.setSurfaceVisible("menu", $0) })
    .onDisappear { model.setSurfaceVisible("menu", false) }
    .sheet(item: $setupGuide) { selection in
      IntegrationSetupGuide(model: model, initialSource: selection.source)
    }
  }

  private var usingMacLighting: Bool { model.isUsingSystemLighting && model.hardwareAvailable }

  private var statusText: String {
    if model.isRestoringHardware { return "Restoring Mac lighting…" }
    if model.needsLightingReset { return "Lighting needs a reset" }
    if usingMacLighting { return "Mac is managing your logo" }
    if !model.isControlling { return "Preview mode" }
    if !model.enabled { return "Light is off" }
    if model.mode == .agents { return model.aggregateAgentState.title }
    return "Light is on"
  }
}
