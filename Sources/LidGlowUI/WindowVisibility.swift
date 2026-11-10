import AppKit
import SwiftUI

/// Occluded, minimized, closed and dismissed windows do not need preview frames.
struct WindowVisibility: NSViewRepresentable {
  let changed: (Bool) -> Void
  func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
  func updateNSView(_ nsView: VisibilityView, context: Context) {}

  final class VisibilityView: NSView {
    private let changed: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var last: Bool?
    init(changed: @escaping (Bool) -> Void) {
      self.changed = changed
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
      guard let window else {
        publish(false)
        return
      }
      for name in [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] notification in
            MainActor.assumeIsolated {
              if notification.name == NSWindow.willCloseNotification {
                self?.publish(false)
              } else {
                self?.refresh()
              }
            }
          })
      }
      DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private func refresh() {
      publish(
        window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
          ?? false)
    }
    private func publish(_ value: Bool) {
      guard last != value else { return }
      last = value
      changed(value)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
}
