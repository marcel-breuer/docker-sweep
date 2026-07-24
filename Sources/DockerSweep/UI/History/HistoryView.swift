import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Cleanup history", systemImage: "clock.arrow.circlepath").font(.headline)
        Spacer()
        Button("Clear", role: .destructive) { state.deleteHistory() }.disabled(state.history.isEmpty)
      }
      if state.history.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
          Text("No cleanups yet").font(.headline)
          Text("Completed DockerSweep runs will appear here.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(state.history) { run in
          HStack {
            Image(systemName: run.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(run.status == .succeeded ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
              Text(run.trigger.rawValue.capitalized + " cleanup").font(.subheadline.weight(.semibold))
              Text(run.finishedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
              Text(run.selectedResources.map(\.displayName).sorted().joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Formatters.bytes(run.reclaimedBytes ?? 0)).font(.subheadline.monospacedDigit())
          }
          .padding(.vertical, 3)
        }
        .listStyle(.inset)
      }
    }
    .padding(14)
    .frame(width: 440, height: 420)
  }
}
