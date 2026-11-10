import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  var reopenMain: (() -> Void)?
  private var terminating = false
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows {
      reopenMain?()
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating, let model else { return .terminateNow }
    terminating = true
    model.shutdown()
    guard model.hasPendingShutdownWork else { return .terminateNow }
    Task { @MainActor in
      let deadline = Date().addingTimeInterval(1.5)
      while model.hasPendingShutdownWork && Date() < deadline {
        try? await Task.sleep(nanoseconds: 30_000_000)
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@MainActor
public struct LidGlowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()

  public init() {}

  public var body: some Scene {
    Window("LidGlow", id: "main") {
      MainWindowHost(model: model, delegate: delegate)
    }
    .defaultSize(width: 1040, height: 760)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Light") {
        Toggle("Logo light", isOn: Binding(get: { model.enabled }, set: { model.setLogoPower($0) }))
          .keyboardShortcut("l", modifiers: [.command, .shift])
        ForEach(LightMode.allCases) { mode in
          Button(mode.title) { model.mode = mode }
        }
        Divider()
        Button("Use Mac’s automatic lighting") { model.useSystemLighting() }
      }
    }
    .defaultLaunchBehavior(.presented)
    MenuBarExtra {
      MenuBarView(model: model)
        .preferredColorScheme(.dark)
    } label: {
      Image(systemName: model.isControlling && model.enabled ? "lightbulb.fill" : "lightbulb")
        .accessibilityLabel("LidGlow")
    }
    .menuBarExtraStyle(.window)
  }
}

private struct MainWindowHost: View {
  @ObservedObject var model: AppModel
  let delegate: AppDelegate
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    ContentView(model: model)
      .preferredColorScheme(.dark)
      .onAppear {
        delegate.model = model
        delegate.reopenMain = { openWindow(id: "main") }
        model.activateSavedLightingIfNeeded()
      }
      .onOpenURL { model.handleURL($0) }
  }
}
