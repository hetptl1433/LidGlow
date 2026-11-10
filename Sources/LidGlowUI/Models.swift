import Combine
import Foundation
import LidGlowCore
import SwiftUI

// New SDKs also export a State macro. The alias selects the established wrapper
// explicitly and keeps command-line builds independent of that macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

typealias LightMode = LidGlowCore.LightMode
typealias AgentState = LidGlowCore.AgentState

struct AgentSession: Identifiable, Equatable {
  var id: String
  var source: String
  var state: AgentState
  var timestamp: Date
  var isDemo: Bool
}

@MainActor
final class PreviewState: ObservableObject {
  @Published var level: Double = 0
}

struct ActivityEntry: Identifiable {
  var id = UUID()
  var title: String
  var time: Date
  var state: AgentState
}

enum AppPaths {
  // Resolve only after confirming a selected developer installation. Invoking
  // the /usr/bin/python3 shim on a fresh Mac can open an unwanted installer.
  static let python: URL? = {
    let result = ProcessRunner.run(
      executable: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--print-path"],
      timeout: 2, maxOutputBytes: 4096)
    guard result.status == 0, let text = String(data: result.output, encoding: .utf8) else {
      return nil
    }
    let developer = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !developer.isEmpty, FileManager.default.fileExists(atPath: developer) else { return nil }
    let direct = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/python3")
    if FileManager.default.isExecutableFile(atPath: direct.path) { return direct }
    let shim = URL(fileURLWithPath: "/usr/bin/python3")
    return FileManager.default.isExecutableFile(atPath: shim.path) ? shim : nil
  }()
  static var dataDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["LIDGLOW_DATA_DIR"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/LidGlow", isDirectory: true)
  }
  static var events: URL { dataDirectory.appendingPathComponent("events", isDirectory: true) }
  static var helper: URL? {
    Bundle.main.url(forResource: "lidglow-hook", withExtension: "py")
  }
  static var signal: URL? {
    guard let executable = Bundle.main.executableURL else { return nil }
    let url = executable.deletingLastPathComponent().appendingPathComponent("LidGlowSignal")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }
}
