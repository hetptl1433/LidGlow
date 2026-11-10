import Foundation

/// The production store is UserDefaults; app-model tests use an in-memory store
/// so restart/loading regressions need no GUI, hardware, or user preference files.
public protocol SettingsStore: AnyObject {
  func object(forKey key: String) -> Any?
  func string(forKey key: String) -> String?
  func bool(forKey key: String) -> Bool
  func double(forKey key: String) -> Double
  func data(forKey key: String) -> Data?
  func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}
