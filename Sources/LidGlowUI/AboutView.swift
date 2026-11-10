import SwiftUI

struct AboutView: View {
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "sun.max.fill")
        .font(.system(size: 46, weight: .light))
        .foregroundStyle(Color.lidAmber)
        .shadow(color: .lidAmber.opacity(0.25), radius: 16)
      VStack(spacing: 7) {
        Text("LidGlow").font(.system(size: 28, weight: .semibold, design: .rounded))
        Text("A little light. Your way.").font(.system(size: 12)).foregroundStyle(Color.lidMuted)
      }
      Rectangle().fill(Color.white.opacity(0.08)).frame(width: 180, height: 1)
      VStack(spacing: 8) {
        Text("CREATED BY").font(.system(size: 9)).tracking(2).foregroundStyle(Color.lidMuted)
        Text("Het Patel")
          .font(.system(size: 22, weight: .medium, design: .serif))
          .tracking(1)
          .foregroundStyle(Color.lidAmber.opacity(0.9))
      }
      Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1") · MIT License")
        .font(.system(size: 10)).foregroundStyle(Color.lidMuted)
      Link("View on GitHub", destination: URL(string: "https://github.com/hetptl1433/LidGlow")!)
        .font(.system(size: 12))
      Text("© 2026 Het Patel")
        .font(.system(size: 9)).foregroundStyle(Color.lidMuted.opacity(0.7))
    }
    .padding(36)
    .frame(width: 350)
    .background(Color.lidCanvas)
    .tint(.lidAmber)
  }
}
