import Foundation
import SwiftUI
import DockerSweepCore
import UserNotifications

@MainActor
final class AppState: ObservableObject {
  let dockerClient: DockerCLIClient
  let settingsStore = SettingsStore()
  let historyStore = CleanupHistoryStore()
  let logger = FileLogger()

  @Published var settings = AppSettings()
  @Published var availability: DockerAvailability = .notInstalled
  @Published var diskUsage: DockerDiskUsage?
  @Published var hostDiskUsage: HostDiskUsage?
  @Published var dockerContextName: String?
  @Published var dockerContextIsLocal = false
  @Published var hostDiskNotificationStatus = ""
  @Published var cleanupCandidates: [CleanupCandidate] = []
  @Published var history: [CleanupRun] = []
  @Published var isScanning = false
  @Published var isCleaning = false
  @Published var lastScanAt: Date?
  @Published var nextScanAt: Date?
  @Published var lastError: String?
  @Published var statusMessage = "Ready to scan"
  @Published var showOnboarding = false

  private var hasStarted = false
  private var schedulerTask: Task<Void, Never>?
  private var wasBelowHostDiskFloor = false

  init() {
    dockerClient = DockerCLIClient()
  }

  deinit { schedulerTask?.cancel() }

  var lastCleanup: CleanupRun? { history.first }
  var lastFreedBytes: Int64 { lastCleanup?.reclaimedBytes ?? 0 }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    Task { [weak self] in
      guard let self else { return }
      settings = await settingsStore.load()
      settings.launchAtLogin = LoginItemController.isEnabled
      await dockerClient.setCustomPath(settings.customDockerPath)
      history = await historyStore.load()
      showOnboarding = !settings.onboardingCompleted
      if settings.hostDiskPressureAlertsEnabled { await requestNotificationPermissionIfNeeded() }
      restartScheduler()
      await scan(allowAutomaticCleanup: false)
    }
  }

  func saveSettings() {
    nextScanAt = CleanupPolicy.nextScanDate(lastScan: lastScanAt, interval: settings.scanInterval)
    restartScheduler()
    Task {
      await dockerClient.setCustomPath(settings.customDockerPath)
      try? await settingsStore.save(settings)
      if settings.hostDiskPressureAlertsEnabled { await requestNotificationPermissionIfNeeded() }
    }
  }

  func scan(allowAutomaticCleanup: Bool = false) async {
    guard !isScanning && !isCleaning else { return }
    isScanning = true
    lastError = nil
    statusMessage = "Checking Docker…"
    await logger.log("Scan started")
    hostDiskUsage = DockerHostStorageProbe.measure(includeDockerImage: false)
    await checkHostDiskPressure(allowCleanup: allowAutomaticCleanup)
    defer {
      isScanning = false
      nextScanAt = CleanupPolicy.nextScanDate(lastScan: lastScanAt, interval: settings.scanInterval)
    }

    availability = await dockerClient.checkAvailability()
    dockerContextName = await dockerClient.activeContextName()
    dockerContextIsLocal = await dockerClient.activeContextIsLocal()
    hostDiskUsage = DockerHostStorageProbe.measure(includeDockerImage: dockerContextIsLocal)
    guard availability.isAvailable else {
      statusMessage = availability.title
      await logger.log("Scan stopped: \(availability.title)")
      return
    }

    do {
      let inventoryStartedAt = Date.now
      diskUsage = try await dockerClient.fetchDiskUsage()
      let inventoryMilliseconds = max(0, Date.now.timeIntervalSince(inventoryStartedAt) * 1_000)
      lastScanAt = .now
      statusMessage = "Scan completed"
      await logger.log("Docker inventory completed in \(Int(inventoryMilliseconds)) ms: \(diskUsage?.totalSizeBytes ?? 0) bytes")
      isScanning = false
      await checkHostDiskPressure(allowCleanup: allowAutomaticCleanup)
      if allowAutomaticCleanup, let usage = diskUsage, CleanupPolicy.shouldAutomaticallyClean(settings: settings, usage: usage, lastCleanup: lastCleanup?.finishedAt) {
        isScanning = false
        do {
          let plan = try makeCleanupPlan(trigger: .threshold)
          await cleanup(authorizedPlan: plan.authorizeExecution())
        } catch {
          lastError = error.localizedDescription
          statusMessage = "Cleanup plan could not be prepared"
          await logger.log("Cleanup plan preparation failed: \(error.localizedDescription)")
        }
      }
    } catch {
      lastError = error.localizedDescription
      statusMessage = "Scan failed"
      await logger.log("Scan failed: \(error.localizedDescription)")
    }
  }

  func makeCleanupPlan(trigger: CleanupTrigger = .manual) throws -> CleanupPlan {
    let request = CleanupRequest(
      resourceTypes: settings.selectedResourceTypes,
      minimumAge: settings.minimumResourceAge,
      cleanupAllUnusedImages: settings.cleanupAllUnusedImages,
      excludedLabels: settings.excludedLabels,
      trigger: trigger)
    return try CleanupPlanner.makePlan(request: request, inventory: diskUsage)
  }

  func loadCleanupCandidates() async {
    do {
      cleanupCandidates = try await dockerClient.fetchCleanupCandidates(excludedLabels: settings.excludedLabels)
    } catch {
      lastError = error.localizedDescription
    }
  }

  func cleanup(authorizedPlan: ConfirmedCleanupPlan, candidates: [CleanupCandidate] = []) async {
    guard !isCleaning && !isScanning else { return }
    let plan = authorizedPlan.plan
    let resources = candidates.isEmpty ? plan.resourceTypes : Set(candidates.map(\.resourceType))
    guard !resources.isEmpty else {
      lastError = "Select at least one resource type before cleaning."
      return
    }
    isCleaning = true
    lastError = nil
    let startedAt = Date()
    let before = plan.inventorySnapshot?.totalSizeBytes
    statusMessage = "Cleaning Docker resources…"
    await logger.log("Cleanup plan authorized with \(plan.actions.count) actions, prepared in \(Int(plan.preparedInMilliseconds)) ms (trigger: \(plan.request.trigger.rawValue))")
    defer { isCleaning = false }

    do {
      let resourceResults: [CleanupResourceResult]
      if candidates.isEmpty {
        resourceResults = try await dockerClient.prune(authorizedPlan).resourceResults
      } else {
        resourceResults = await dockerClient.removeCleanupCandidates(candidates, minimumAge: settings.minimumResourceAge, excludedLabels: settings.excludedLabels)
      }
      let after = try? await dockerClient.fetchDiskUsage()
      if let after { diskUsage = after; lastScanAt = .now }
      let reclaimed = max(0, (before ?? 0) - (after?.totalSizeBytes ?? before ?? 0))
      let status: CleanupStatus = resourceResults.allSatisfy(\.succeeded) ? .succeeded : (resourceResults.contains(where: \.succeeded) ? .partiallySucceeded : .failed)
      let measuredReclaimed = resourceResults.compactMap(\.reclaimedBytes).reduce(0, +)
      let run = CleanupRun(id: UUID(), startedAt: startedAt, finishedAt: .now, trigger: plan.request.trigger, status: status, selectedResources: resources, diskUsageBeforeBytes: before, diskUsageAfterBytes: after?.totalSizeBytes, reclaimedBytes: reclaimed > 0 ? reclaimed : measuredReclaimed, resourceResults: resourceResults, errorMessage: resourceResults.first(where: { !$0.succeeded })?.errorMessage)
      try? await historyStore.save(run)
      history = await historyStore.load()
      statusMessage = status == .succeeded ? "Cleanup completed" : "Cleanup completed with errors"
      await logger.log("Cleanup finished: \(status.rawValue), reclaimed \(run.reclaimedBytes ?? 0) bytes")
    } catch is CancellationError {
      statusMessage = "Cleanup cancelled"
      await logger.log("Cleanup cancelled")
    } catch {
      lastError = error.localizedDescription
      statusMessage = "Cleanup failed"
      await logger.log("Cleanup failed: \(error.localizedDescription)")
    }
  }

  func finishOnboarding() {
    settings.onboardingCompleted = true
    showOnboarding = false
    saveSettings()
  }

  func deleteHistory() {
    Task {
      try? await historyStore.deleteAll()
      history = []
    }
  }

  private func restartScheduler() {
    schedulerTask?.cancel()
    schedulerTask = nil
    guard settings.automaticScanningEnabled else { return }
    let interval = min(max(settings.scanInterval, 30 * 60), 30 * 24 * 60 * 60)
    nextScanAt = CleanupPolicy.nextScanDate(lastScan: lastScanAt, interval: interval)
    schedulerTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(interval)) } catch { return }
        guard let self else { return }
        await self.scan(allowAutomaticCleanup: true)
      }
    }
  }

  private func checkHostDiskPressure(allowCleanup: Bool) async {
    guard let usage = hostDiskUsage else { return }
    let isBelowFloor = usage.availableBytes < settings.hostDiskFreeSpaceFloorBytes
    if !settings.hostDiskPressureAlertsEnabled { wasBelowHostDiskFloor = false }
    if settings.hostDiskPressureAlertsEnabled && isBelowFloor && !wasBelowHostDiskFloor {
      await postHostDiskPressureNotification(availableBytes: usage.availableBytes)
    }
    if settings.hostDiskPressureAlertsEnabled { wasBelowHostDiskFloor = isBelowFloor }
    if isBelowFloor, settings.hostDiskPressureCleanupEnabled, availability.isAvailable, !dockerContextIsLocal {
      hostDiskNotificationStatus = "Automatic cleanup is disabled because the selected Docker context is not a local Unix socket."
    }
    guard allowCleanup, isBelowFloor,
          CleanupPolicy.shouldAutomaticallyCleanForHostPressure(settings: settings, hostUsage: usage, lastCleanup: lastCleanup?.finishedAt),
          availability.isAvailable, dockerContextIsLocal, !settings.selectedResourceTypes.isEmpty else { return }
    do {
      let plan = try makeCleanupPlan(trigger: .hostDiskPressure)
      await cleanup(authorizedPlan: plan.authorizeExecution())
    } catch {
      lastError = error.localizedDescription
      statusMessage = "Disk-pressure cleanup could not be prepared"
    }
  }

  private func requestNotificationPermissionIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    let current = await center.notificationSettings()
    if current.authorizationStatus == .notDetermined {
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
      hostDiskNotificationStatus = granted ? "Notifications are enabled." : "Notifications are blocked. Allow them in System Settings to receive low-storage alerts."
    } else if current.authorizationStatus == .denied {
      hostDiskNotificationStatus = "Notifications are blocked. Allow them in System Settings to receive low-storage alerts."
    } else {
      hostDiskNotificationStatus = "Low-storage notifications are enabled."
    }
  }

  private func postHostDiskPressureNotification(availableBytes: Int64) async {
    let center = UNUserNotificationCenter.current()
    let permission = await center.notificationSettings()
    if permission.authorizationStatus == .notDetermined {
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
      guard granted else {
        hostDiskNotificationStatus = "Notifications are blocked. Allow them in System Settings to receive low-storage alerts."
        return
      }
    } else if permission.authorizationStatus == .denied {
      hostDiskNotificationStatus = "Notifications are blocked. Allow them in System Settings to receive low-storage alerts."
      return
    }
    hostDiskNotificationStatus = "Low-storage notifications are enabled."
    let content = UNMutableNotificationContent()
    content.title = "Mac storage is running low"
    content.body = "\(Formatters.bytes(availableBytes)) remains free. Open DockerSweep to review Docker cleanup options."
    content.sound = .default
    let request = UNNotificationRequest(identifier: "host-disk-pressure", content: content, trigger: nil)
    try? await center.add(request)
  }
}
