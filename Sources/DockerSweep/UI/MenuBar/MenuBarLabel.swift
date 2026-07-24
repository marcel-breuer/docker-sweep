import SwiftUI
import DockerSweepCore

struct MenuBarLabel: View {
  @ObservedObject var state: AppState
  @Environment(\.openWindow) private var openWindow
  @State private var didOpenDashboard = false

  private var symbol: String {
    if state.isCleaning || state.isScanning { return "arrow.triangle.2.circlepath" }
    switch state.availability {
    case .available:
      if let usage = state.diskUsage, CleanupPolicy.thresholdExceeded(usageBytes: usage.totalSizeBytes, thresholdBytes: state.settings.cleanupThresholdBytes) { return "externaldrive.badge.exclamationmark" }
      return "shippingbox"
    case .notInstalled: return "xmark.circle"
    case .engineUnavailable, .commandFailed: return "exclamationmark.triangle"
    }
  }

  var body: some View {
    Image(systemName: symbol)
      .symbolRenderingMode(.hierarchical)
      .accessibilityLabel("DockerSweep: \(state.statusMessage)")
      .task {
        guard !didOpenDashboard else { return }
        didOpenDashboard = true
        openWindow(id: "dashboard")
      }
  }
}
