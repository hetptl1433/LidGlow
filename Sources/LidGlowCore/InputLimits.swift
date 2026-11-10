import Foundation

/// Character counts alone do not bound storage: a single grapheme can contain
/// arbitrarily many combining scalars. Copy a small UTF-8 prefix first.
public enum InputLimits {
  public static func text(_ text: String, characters: Int, utf8Bytes: Int) -> String {
    guard characters > 0, utf8Bytes > 0 else { return "" }
    var bytes = Array(text.utf8.prefix(utf8Bytes))
    // A valid Swift string can only be cut inside its final UTF-8 scalar.
    while !bytes.isEmpty {
      if let bounded = String(bytes: bytes, encoding: .utf8) {
        return String(bounded.prefix(characters))
      }
      bytes.removeLast()
    }
    return ""
  }
}
