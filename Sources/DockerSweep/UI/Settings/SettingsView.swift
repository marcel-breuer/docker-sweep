import AppKit
import SwiftUI
import DockerSweepCore

struct SettingsView: View {
  @EnvironmentObject private var state: AppState
  @State private var showVolumeWarning = false
  @State private var showLoginError = false
  @State private var loginError = ""

  private let intervals: [(String, TimeInterval)] = [
    ("30 minutes", 30 * 60), ("Hourly", 60 * 60), ("Every 2 hours", 2 * 60 * 60),
    ("Every 4 hours", 4 * 60 * 60), ("Every 6 hours", 6 * 60 * 60), ("Every 8 hours", 8 * 60 * 60),
    ("Every 12 hours", 12 * 60 * 60), ("Daily", 24 * 60 * 60), ("Weekly", 7 * 24 * 60 * 60),
  ]
  private let cooldowns: [(String, TimeInterval)] = [
    ("1 hour", 60 * 60), ("6 hours", 6 * 60 * 60), ("12 hours", 12 * 60 * 60),
    ("24 hours", 24 * 60 * 60), ("3 days", 3 * 24 * 60 * 60), ("7 days", 7 * 24 * 60 * 60),
  ]
  private let ages: [(String, TimeInterval)] = [
    ("Immediately", 0), ("24 hours", 24 * 60 * 60), ("3 days", 3 * 24 * 60 * 60),
    ("7 days", 7 * 24 * 60 * 60), ("14 days", 14 * 24 * 60 * 60), ("30 days", 30 * 24 * 60 * 60),
    ("90 days", 90 * 24 * 60 * 60),
  ]

  var body: some View {
    Form {
      Section("General") {
        Toggle("Launch DockerSweep at login", isOn: Binding(
          get: { state.settings.launchAtLogin },
          set: { enabled in updateLoginItem(enabled) }
        ))
        Toggle("Enable automatic scans", isOn: $state.settings.automaticScanningEnabled)
        Toggle("Enable notifications", isOn: $state.settings.notificationsEnabled)
        LabeledContent("Docker CLI") {
          Text(state.availabilityPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        TextField("Custom Docker path (optional)", text: Binding(get: { state.settings.customDockerPath ?? "" }, set: { state.settings.customDockerPath = $0.isEmpty ? nil : $0; state.saveSettings() }))
      }

      Section("Automation") {
        Picker("Scan interval", selection: $state.settings.scanInterval) {
          ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
        }
        Toggle("Enable automatic cleanup", isOn: $state.settings.automaticCleanupEnabled)
        Stepper(value: $state.settings.cleanupThresholdBytes, in: 1_000_000_000...2_000_000_000_000, step: 1_000_000_000) {
          Text("Cleanup threshold: \(Formatters.bytes(state.settings.cleanupThresholdBytes))")
        }
        Picker("Cleanup cooldown", selection: $state.settings.cleanupCooldown) {
          ForEach(cooldowns, id: \.1) { Text($0.0).tag($0.1) }
        }
        Picker("Minimum resource age", selection: $state.settings.minimumResourceAge) {
          ForEach(ages, id: \.1) { Text($0.0).tag($0.1) }
        }
        Text("Automatic cleanup only runs after the threshold is exceeded and the cooldown has elapsed.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Cleanup resources") {
        Toggle("Build cache", isOn: $state.settings.cleanupBuildCache)
        Toggle("Dangling images", isOn: $state.settings.cleanupImages)
        Toggle("Remove all unused images", isOn: $state.settings.cleanupAllUnusedImages)
        Toggle("Stopped containers", isOn: $state.settings.cleanupStoppedContainers)
        Toggle("Unused networks", isOn: $state.settings.cleanupNetworks)
        Toggle("Anonymous volumes", isOn: $state.settings.cleanupAnonymousVolumes)
          .onChange(of: state.settings.cleanupAnonymousVolumes) { enabled in validateVolumeToggle(enabled, keyPath: \.cleanupAnonymousVolumes) }
        Toggle("Named volumes", isOn: $state.settings.cleanupNamedVolumes)
          .onChange(of: state.settings.cleanupNamedVolumes) { enabled in validateVolumeToggle(enabled, keyPath: \.cleanupNamedVolumes) }
        Text("Volumes are disabled by default. DockerSweep never removes running containers or resources Docker still reports as in use.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Protection") {
        Toggle("Require confirmation before manual cleanup", isOn: $state.settings.requireManualConfirmation)
        Text("Volumes labeled `docker-sweep.keep=true` or `keep` are excluded from volume prune commands.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Volume data cannot be restored after Docker removes it.")
          .font(.caption.weight(.semibold)).foregroundStyle(.orange)
      }

      Section("History") {
        Button("Clear cleanup history", role: .destructive) { state.deleteHistory() }
        Button("Open log folder") { NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/DockerSweep")) }
      }

      Section("About") {
        LabeledContent("Version", value: "0.1.2")
        Link("Project website", destination: URL(string: "https://github.com/marcel-breuer/docker-sweep")!)
        Text("DockerSweep is open-source software under the MIT License.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 500, height: 650)
    .alert("Protect Docker volumes", isPresented: $showVolumeWarning) {
      Button("Cancel", role: .cancel) {}
      Button("I understand", role: .destructive) {
        state.settings.volumeWarningConfirmed = true
        state.saveSettings()
      }
    } message: {
      Text("Unused Docker volumes may contain databases, uploads, or other persistent project data. DockerSweep cannot restore deleted volumes.")
    }
    .alert("Login item unavailable", isPresented: $showLoginError) { Button("OK", role: .cancel) {} } message: { Text(loginError) }
    .onChange(of: state.settings) { _ in state.saveSettings() }
  }

  private func validateVolumeToggle(_ enabled: Bool, keyPath: WritableKeyPath<AppSettings, Bool>) {
    guard !enabled || state.settings.volumeWarningConfirmed else {
      state.settings[keyPath: keyPath] = false
      showVolumeWarning = true
      return
    }
    state.saveSettings()
  }

  private func updateLoginItem(_ enabled: Bool) {
    do {
      try LoginItemController.setEnabled(enabled)
      state.settings.launchAtLogin = LoginItemController.isEnabled
      state.saveSettings()
    } catch {
      state.settings.launchAtLogin = LoginItemController.isEnabled
      loginError = error.localizedDescription
      showLoginError = true
    }
  }
}

private extension AppState {
  var availabilityPath: String {
    if case let .available(path, _) = availability { return path }
    return settings.customDockerPath ?? "Not detected"
  }
}
