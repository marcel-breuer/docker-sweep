import AppKit
import SwiftUI
import DockerSweepCore

struct DashboardView: View {
  @EnvironmentObject private var state: AppState
  @State private var showingHistory = false
  @State private var showingSettings = false

  private var usageRatio: Double {
    guard let usage = state.diskUsage, state.settings.cleanupThresholdBytes > 0 else { return 0 }
    return min(Double(usage.totalSizeBytes) / Double(state.settings.cleanupThresholdBytes), 1)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          statusBanner
          storageCard
          timelineCard
          actionRow
          footerLinks
        }
        .padding(14)
      }
    }
    .background(.regularMaterial)
    .sheet(isPresented: $showingHistory) { HistoryView().environmentObject(state) }
    .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(state).padding() }
    .sheet(isPresented: $state.showOnboarding) { OnboardingView().environmentObject(state) }
    .sheet(isPresented: $state.showCleanupPreview) { CleanupPreviewView().environmentObject(state) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "shippingbox.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.tint)
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text("DockerSweep").font(.headline.weight(.semibold))
        Text("Local Docker storage monitor").font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        Task { await state.scan() }
      } label: {
        Image(systemName: state.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Scan now")
      .disabled(state.isScanning || state.isCleaning)
      Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
        .buttonStyle(.borderless)
        .help("Quit DockerSweep")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var statusBanner: some View {
    HStack(spacing: 10) {
      Circle().fill(state.availability.isAvailable ? .green : .orange).frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 2) {
        Text(state.availability.title).font(.subheadline.weight(.semibold))
        Text(state.lastError ?? state.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      if case let .available(path, version) = state.availability {
        Text(version ?? URL(fileURLWithPath: path).lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }

  private var storageCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Docker storage", systemImage: "externaldrive")
          .font(.headline)
        Spacer()
        Text(Formatters.bytes(state.settings.cleanupThresholdBytes) + " threshold")
          .font(.caption2).foregroundStyle(.secondary)
      }
      HStack(alignment: .firstTextBaseline) {
        Text(Formatters.bytes(state.diskUsage?.totalSizeBytes ?? 0))
          .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
        Text("used").font(.subheadline).foregroundStyle(.secondary)
        Spacer()
        Text(Formatters.bytes(state.diskUsage?.totalReclaimableBytes ?? 0) + " reclaimable")
          .font(.caption).foregroundStyle(.secondary)
      }
      ProgressView(value: usageRatio)
        .tint(usageRatio >= 1 ? .orange : .accentColor)
        .accessibilityLabel("Docker storage threshold")
      HStack(spacing: 12) {
        StorageStat(title: "Images", value: state.diskUsage?.images)
        StorageStat(title: "Containers", value: state.diskUsage?.containers)
        StorageStat(title: "Volumes", value: state.diskUsage?.volumes)
        StorageStat(title: "Build cache", value: state.diskUsage?.buildCache)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }

  private var timelineCard: some View {
    HStack(spacing: 10) {
      MetricCard(title: "Last scan", value: Formatters.relative(state.lastScanAt), detail: "Next: \(Formatters.relative(state.nextScanAt))", symbol: "magnifyingglass", tint: .blue)
      MetricCard(title: "Last cleanup", value: Formatters.bytes(state.lastFreedBytes), detail: Formatters.relative(state.lastCleanup?.finishedAt), symbol: "sparkles", tint: .purple)
    }
  }

  private var actionRow: some View {
    HStack(spacing: 10) {
      Button { Task { await state.scan() } } label: { Label("Scan now", systemImage: "magnifyingglass") }
        .buttonStyle(.bordered)
        .disabled(state.isScanning || state.isCleaning)
      Button { state.showCleanupPreview = true } label: { Label("Clean up", systemImage: "sparkles") }
        .buttonStyle(.borderedProminent)
        .disabled(state.isScanning || state.isCleaning || state.settings.selectedResourceTypes.isEmpty)
      Spacer()
    }
  }

  private var footerLinks: some View {
    HStack {
      Button("History", systemImage: "clock.arrow.circlepath") { showingHistory = true }.buttonStyle(.borderless)
      Spacer()
      Button("Settings", systemImage: "gearshape") { showingSettings = true }.buttonStyle(.borderless)
      Button("Open Docker Desktop", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"), configuration: NSWorkspace.OpenConfiguration()) }.buttonStyle(.borderless)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

private struct StorageStat: View {
  let title: String
  let value: ResourceDiskUsage?
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(Formatters.bytes(value?.sizeBytes ?? 0)).font(.caption.monospacedDigit())
      Text(Formatters.bytes(value?.reclaimableBytes ?? 0) + " freeable").font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
