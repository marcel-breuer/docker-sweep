import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var state: AppState
  @State private var step = 0

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: step == 0 ? "shippingbox.fill" : step == 1 ? "externaldrive.fill" : "sparkles")
        .font(.system(size: 38, weight: .semibold))
        .foregroundStyle(.tint)
      Text(step == 0 ? "Welcome to DockerSweep" : step == 1 ? "Set a safe threshold" : "Choose what may be cleaned")
        .font(.title2.weight(.semibold))
      Text(step == 0 ? "A local menu-bar utility for keeping Docker storage under control." : step == 1 ? "DockerSweep will never clean automatically unless you enable it explicitly." : "Build cache, dangling images, stopped containers, and networks are enabled by default. Volumes stay protected.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      if step == 1 {
        Stepper(value: Binding(get: { state.settings.cleanupThresholdBytes }, set: { state.settings.cleanupThresholdBytes = $0 }), in: 1_000_000_000...2_000_000_000_000, step: 1_000_000_000) {
          Text("Threshold: \(Formatters.bytes(state.settings.cleanupThresholdBytes))")
        }
        .padding(.horizontal)
      }
      if step == 2 {
        Toggle("Enable automatic cleanup", isOn: Binding(get: { state.settings.automaticCleanupEnabled }, set: { state.settings.automaticCleanupEnabled = $0 }))
          .padding(.horizontal, 28)
        Text("You can review every manual cleanup before it starts in the preview screen.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.bordered) }
        Spacer()
        Button(step == 2 ? "Start first scan" : "Continue") {
          if step == 2 { state.finishOnboarding(); Task { await state.scan() } } else { step += 1; state.saveSettings() }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(28)
    .frame(width: 390, height: 330)
  }
}
