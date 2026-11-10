import SwiftUI

struct IntegrationGuideSelection: Identifiable {
  let source: String
  var id: String { source }
}

struct LightingWelcomeView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 17) {
      HStack(spacing: 13) {
        Image(systemName: "sun.max.fill")
          .font(.system(size: 31, weight: .medium))
          .foregroundStyle(Color.lidAmber)
        VStack(alignment: .leading, spacing: 5) {
          Text("A little light. Your way.")
            .font(.system(size: 22, weight: .semibold, design: .rounded))
          Text("Welcome to LidGlow")
            .font(.system(size: 11))
            .foregroundStyle(Color.lidMuted)
        }
      }
      Text("Customize your logo’s glow, or let it show what your agents are doing.")
        .font(.system(size: 12))
        .foregroundStyle(Color.white.opacity(0.8))
      VStack(alignment: .leading, spacing: 10) {
        welcomeRow("slider.horizontal.3", title: "Choose your brightness and rhythm")
        welcomeRow("sparkles", title: "Set your own Claude Code and Codex signals")
        welcomeRow("power", title: "Turn your logo on or off from the menu bar")
      }
      Text(
        model.hardwareAvailable
          ? "Quitting restores Mac lighting. Change settings any time."
          : "Your logo is not available right now. You can still try every mode onscreen."
      )
      .font(.system(size: 10))
      .foregroundStyle(Color.lidMuted)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Spacer()
        if model.hardwareAvailable {
          Button("Explore preview") { model.completeWelcome(startLighting: false) }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        Button(model.hardwareAvailable ? "Get started" : "Explore preview") {
          model.completeWelcome(startLighting: model.hardwareAvailable)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isRestoringHardware)
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.regular)
    }
    .padding(24)
    .frame(width: 480)
    .background(Color.lidCanvas)
    .preferredColorScheme(.dark)
    .tint(.lidAmber)
    .interactiveDismissDisabled()
  }

  private func welcomeRow(_ symbol: String, title: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 14))
        .foregroundStyle(Color.lidAmber)
        .frame(width: 22, height: 18)
      Text(title).font(.system(size: 11, weight: .medium))
    }
  }
}

struct IntegrationSetupGuide: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @ViewState(initialValue: "claude") private var source: String

  init(model: AppModel, initialSource: String) {
    self.model = model
    _source = ViewState(initialValue: initialSource == "codex" ? "codex" : "claude")
  }

  private var installed: Bool { source == "codex" ? model.codexInstalled : model.claudeInstalled }
  private var agentName: String { source == "codex" ? "Codex" : "Claude Code" }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 15) {
        HStack(spacing: 11) {
          Image(systemName: "sparkles")
            .font(.system(size: 22))
            .foregroundStyle(Color.lidAmber)
          VStack(alignment: .leading, spacing: 4) {
            Text("Set up agent signals").font(.system(size: 20, weight: .semibold))
            Text("A few quick steps, then let the light follow along.")
              .font(.system(size: 11)).foregroundStyle(Color.lidMuted)
          }
        }
        Picker("Agent", selection: $source) {
          Text("Claude Code").tag("claude")
          Text("Codex").tag("codex")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Agent to set up")
        .disabled(model.installationBusy)
      }
      .padding(24)

      ScrollView {
        VStack(alignment: .leading, spacing: 23) {
          GuideStep(
            number: "1", title: "Add the integration",
            detail:
              "LidGlow adds local activity hooks to \(agentName). Your existing settings stay in place."
          ) {
            HStack(spacing: 12) {
              Button(
                installed
                  ? "Hooks added" : (model.installationBusy ? "Please wait…" : "Add integration")
              ) {
                model.installHooks(source)
              }
              .buttonStyle(.borderedProminent)
              .disabled(installed || model.installationBusy)
              if installed {
                Label("Hooks added", systemImage: "checkmark.circle")
                  .font(.system(size: 10))
                  .foregroundStyle(Color.lidAmber)
              }
            }
          }
          GuideStep(
            number: "2",
            title: source == "codex" ? "Review and trust the hooks" : "Reload Claude Code",
            detail: source == "codex"
              ? "In Codex, open Settings > Hooks and review the LidGlow hooks. Trust them when you’re ready. LidGlow cannot do this step for you."
              : "Restart Claude Code, or open /hooks to check that LidGlow’s hooks are loaded."
          ) {
            EmptyView()
          }
          GuideStep(
            number: "3", title: "Send a task",
            detail:
              "Choose Agent signal in LidGlow. Start a task in \(agentName), then watch your Working and Finished signals. You can customize both in the app."
          ) {
            EmptyView()
          }
          if let message = model.integrationMessage {
            Text(message)
              .font(.system(size: 11))
              .foregroundStyle(Color.lidAmber)
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.lidAmber.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
              .fixedSize(horizontal: false, vertical: true)
          }
          Label(
            "Only activity states stay on this Mac. LidGlow does not save your prompts or code.",
            systemImage: "lock"
          )
          .font(.system(size: 10))
          .foregroundStyle(Color.lidMuted)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 23)
      }
      Divider()
      HStack(spacing: 12) {
        if installed {
          Button("Remove integration") { model.removeHooks(source) }
            .buttonStyle(.link)
            .disabled(model.installationBusy)
        } else {
          Button("Full guide", action: model.openHooksHelp)
            .buttonStyle(.link)
        }
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.bordered)
          .keyboardShortcut(.defaultAction)
      }
      .font(.system(size: 11))
      .padding(.horizontal, 24)
      .padding(.vertical, 17)
    }
    .frame(width: 500, height: 510)
    .background(Color.lidCanvas)
    .preferredColorScheme(.dark)
    .tint(.lidAmber)
    .onAppear(perform: clearStaleMessage)
    .onChange(of: source) { _, _ in clearStaleMessage() }
  }

  private func clearStaleMessage() {
    guard !model.installationBusy else { return }
    model.integrationMessage = nil
  }
}

private struct GuideStep<Actions: View>: View {
  let number: String
  let title: String
  let detail: String
  let actions: Actions

  init(number: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) {
    self.number = number
    self.title = title
    self.detail = detail
    self.actions = actions()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      Text(number)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.lidAmber)
        .frame(width: 25, height: 25)
        .background(Color.lidAmber.opacity(0.1), in: Circle())
      VStack(alignment: .leading, spacing: 9) {
        Text(title).font(.system(size: 12, weight: .semibold))
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(Color.lidMuted)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
        actions
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
