import SwiftUI
import DockerSweepCore

struct CleanupPreviewView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Review cleanup", systemImage: "sparkles.rectangle.stack")
        .font(.title3.weight(.semibold))
      Text("DockerSweep will run separate Docker prune commands. It will not stop running containers or remove resources Docker still reports as used.")
        .font(.subheadline).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        Text("Selected resources").font(.headline)
        ForEach(Array(state.settings.selectedResourceTypes).sorted { $0.rawValue < $1.rawValue }) { resource in
          Label(resource.displayName, systemImage: resource.isVolume ? "externaldrive" : "shippingbox")
        }
      }
      Divider()
      LabeledContent("Current storage", value: Formatters.bytes(state.diskUsage?.totalSizeBytes ?? 0))
      LabeledContent("Potentially reclaimable", value: Formatters.bytes(state.diskUsage?.totalReclaimableBytes ?? 0))
      LabeledContent("Minimum age", value: ageLabel(state.settings.minimumResourceAge))
      if state.settings.selectedResourceTypes.contains(where: \.isVolume) {
        Label("Volumes can contain persistent project data and cannot be restored.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption.weight(.semibold)).foregroundStyle(.orange)
      }
      Spacer()
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Start cleanup", role: .destructive) {
          dismiss()
          Task { await state.cleanup() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.settings.selectedResourceTypes.isEmpty)
      }
    }
    .padding(18)
    .frame(width: 420, height: 420)
  }

  private func ageLabel(_ seconds: TimeInterval) -> String {
    if seconds == 0 { return "Immediately" }
    return Formatters.relative(Date().addingTimeInterval(-seconds)).replacingOccurrences(of: " ago", with: "")
  }
}
