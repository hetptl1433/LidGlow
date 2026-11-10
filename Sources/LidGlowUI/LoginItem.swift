import ServiceManagement

enum LoginItemState: Equatable { case off, on, needsApproval }

@MainActor
protocol LoginItemManaging {
  var state: LoginItemState { get }
  func setEnabled(_ enabled: Bool) throws
  func openSettings()
}

@MainActor
final class SystemLoginItem: LoginItemManaging {
  var state: LoginItemState {
    switch SMAppService.mainApp.status {
    case .enabled: return .on
    case .requiresApproval: return .needsApproval
    default: return .off
    }
  }
  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      if state == .off { try SMAppService.mainApp.register() }
    } else if state != .off {
      try SMAppService.mainApp.unregister()
    }
  }
  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
