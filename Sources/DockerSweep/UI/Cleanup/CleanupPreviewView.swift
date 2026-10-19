import SwiftUI
import DockerSweepCore

struct CleanupPreviewView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let plan = try? state.makeCleanupPlan()

    VStack(alignment: .leading, spacing: 14) {
      Label("Review cleanup", systemImage: "sparkles.rectangle.stack")
        .font(.title3.weight(.semibold))
      Text("DockerSweep will run separate Docker prune commands. It will not stop running containers or remove resources Docker still reports as used.")
        .font(.subheadline).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text("Exact cleanup scope").font(.headline)
          ForEach(plan?.actions ?? [], id: \.resourceType) { action in
            VStack(alignment: .leading, spacing: 3) {
              Label(action.resourceType.displayName, systemImage: action.resourceType.isVolume ? "externaldrive" : "shippingbox")
              Text(action.scopeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
            }
          }
          Divider()
          LabeledContent("Current storage", value: Formatters.bytes(plan?.inventorySnapshot?.totalSizeBytes ?? 0))
          LabeledContent("Potentially reclaimable", value: Formatters.bytes(plan?.inventorySnapshot?.totalReclaimableBytes ?? 0))
          LabeledContent("Minimum age", value: ageLabel(state.settings.minimumResourceAge))
          if plan?.request.resourceTypes.contains(where: \.isVolume) == true {
            Label("Volumes can contain persistent project data and cannot be restored.", systemImage: "exclamationmark.triangle.fill")
              .font(.caption.weight(.semibold)).foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Start cleanup", role: .destructive) {
          guard let plan else { return }
          dismiss()
          Task { await state.cleanup(authorizedPlan: plan.authorizeExecution()) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(plan?.requiresExplicitConfirmation != true)
      }
    }
    .padding(18)
    .frame(width: 420, height: 480)
    .onAppear {
      guard let plan else { return }
      let elapsed = String(format: "%.2f", plan.preparedInMilliseconds)
      Task { await state.logger.log("Cleanup preview plan prepared in \(elapsed) ms from cached inventory") }
    }
  }

  private func ageLabel(_ seconds: TimeInterval) -> String {
    if seconds == 0 { return "Immediately" }
    return Formatters.relative(Date().addingTimeInterval(-seconds)).replacingOccurrences(of: " ago", with: "")
  }
}
