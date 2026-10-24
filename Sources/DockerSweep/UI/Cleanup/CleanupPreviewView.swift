import SwiftUI
import DockerSweepCore

struct CleanupPreviewView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var selectedCandidateIDs: Set<String> = []
  @State private var candidateTypeFilter = "all"
  @State private var candidateSort = "size"

  private var visibleCandidates: [CleanupCandidate] {
    let filtered = candidateTypeFilter == "all" ? state.cleanupCandidates : state.cleanupCandidates.filter { $0.resourceType.rawValue == candidateTypeFilter }
    return filtered.sorted { lhs, rhs in
      if candidateSort == "age" {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
      }
      switch (lhs.estimatedBytes, rhs.estimatedBytes) {
      case let (left?, right?): return left > right
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    }
  }

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
          HStack {
            Text("Individual unused resources").font(.headline)
            Spacer()
            Button("Refresh") { Task { await state.loadCleanupCandidates() } }
              .buttonStyle(.borderless)
              .disabled(state.isScanning || state.isCleaning)
          }
          HStack {
            Picker("Type", selection: $candidateTypeFilter) {
              Text("All types").tag("all")
              ForEach(CleanupResourceType.allCases, id: \.rawValue) { type in
                Text(type.displayName).tag(type.rawValue)
              }
            }
            Picker("Sort", selection: $candidateSort) {
              Text("Largest first").tag("size")
              Text("Oldest first").tag("age")
            }
          }
          if state.cleanupCandidates.isEmpty {
            Text("No individual cleanup candidates were found. Build cache remains available through the category cleanup above.")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            ForEach(visibleCandidates) { candidate in
              Toggle(isOn: Binding(
                get: { selectedCandidateIDs.contains(candidate.id) },
                set: { selected in
                  guard candidateIsEligible(candidate) else { return }
                  if selected { selectedCandidateIDs.insert(candidate.id) }
                  else { selectedCandidateIDs.remove(candidate.id) }
                }
              )) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(candidate.name).lineLimit(1)
                  Text("Unused · \(candidate.resourceType.displayName) · \(candidate.estimatedBytes.map(Formatters.bytes) ?? "Size unavailable") · \(candidate.createdAt.map(Formatters.relative) ?? "Age unavailable")\(candidate.isProtected ? " · Protected" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              .disabled(!candidateIsEligible(candidate))
            }
          }
          Divider()
          LabeledContent("Current storage", value: Formatters.bytes(plan?.inventorySnapshot?.totalSizeBytes ?? 0))
          if selectedCandidateIDs.isEmpty {
            LabeledContent("Potentially reclaimable", value: Formatters.bytes(plan?.inventorySnapshot?.totalReclaimableBytes ?? 0))
          } else {
            let selected = state.cleanupCandidates.filter { selectedCandidateIDs.contains($0.id) && candidateIsEligible($0) }
            let knownBytes = selected.compactMap(\.estimatedBytes).reduce(0, +)
            LabeledContent(selected.contains(where: { $0.estimatedBytes == nil }) ? "Estimated minimum" : "Selected estimate", value: Formatters.bytes(knownBytes))
          }
          LabeledContent("Minimum age", value: ageLabel(state.settings.minimumResourceAge))
          if plan?.request.resourceTypes.contains(where: \.isVolume) == true || state.cleanupCandidates.contains(where: { selectedCandidateIDs.contains($0.id) && $0.resourceType.isVolume }) {
            Label("Volumes can contain persistent project data and cannot be restored.", systemImage: "exclamationmark.triangle.fill")
              .font(.caption.weight(.semibold)).foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(selectedCandidateIDs.isEmpty ? "Start cleanup" : "Remove selected resources", role: .destructive) {
          guard let plan else { return }
          let selected = state.cleanupCandidates.filter { selectedCandidateIDs.contains($0.id) && candidateIsEligible($0) }
          dismiss()
          Task { await state.cleanup(authorizedPlan: plan.authorizeExecution(), candidates: selected) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(plan?.requiresExplicitConfirmation != true || (!selectedCandidateIDs.isEmpty && state.cleanupCandidates.filter { selectedCandidateIDs.contains($0.id) && candidateIsEligible($0) }.isEmpty))
      }
    }
    .padding(18)
    .frame(width: 420, height: 480)
    .onAppear {
      Task { await state.loadCleanupCandidates() }
      guard let plan else { return }
      let elapsed = String(format: "%.2f", plan.preparedInMilliseconds)
      Task { await state.logger.log("Cleanup preview plan prepared in \(elapsed) ms from cached inventory") }
    }
  }

  private func ageLabel(_ seconds: TimeInterval) -> String {
    if seconds == 0 { return "Immediately" }
    return Formatters.relative(Date().addingTimeInterval(-seconds)).replacingOccurrences(of: " ago", with: "")
  }

  private func candidateIsEligible(_ candidate: CleanupCandidate) -> Bool {
    guard candidate.canBeSelected else { return false }
    guard state.settings.minimumResourceAge > 0 else { return true }
    guard let createdAt = candidate.createdAt else { return false }
    return Date().timeIntervalSince(createdAt) >= state.settings.minimumResourceAge
  }
}
