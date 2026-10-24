import Foundation

public enum CleanupPolicy {
  public static let maximumCleanupAge: TimeInterval = 100 * 365 * 24 * 60 * 60

  public static func thresholdExceeded(usageBytes: Int64, thresholdBytes: Int64) -> Bool {
    usageBytes > thresholdBytes
  }

  public static func cooldownElapsed(lastCleanup: Date?, cooldown: TimeInterval, now: Date = .now) -> Bool {
    guard let lastCleanup else { return true }
    return now.timeIntervalSince(lastCleanup) >= cooldown
  }

  public static func shouldAutomaticallyClean(settings: AppSettings, usage: DockerDiskUsage, lastCleanup: Date?, now: Date = .now) -> Bool {
    settings.automaticScanningEnabled &&
      settings.automaticCleanupEnabled &&
      !settings.selectedResourceTypes.isEmpty &&
      thresholdExceeded(usageBytes: usage.totalSizeBytes, thresholdBytes: settings.cleanupThresholdBytes) &&
      cooldownElapsed(lastCleanup: lastCleanup, cooldown: settings.cleanupCooldown, now: now)
  }

  public static func shouldAutomaticallyCleanForHostPressure(settings: AppSettings, hostUsage: HostDiskUsage, lastCleanup: Date?, now: Date = .now) -> Bool {
    settings.automaticScanningEnabled &&
      settings.hostDiskPressureCleanupEnabled &&
      !settings.selectedResourceTypes.isEmpty &&
      hostUsage.availableBytes < settings.hostDiskFreeSpaceFloorBytes &&
      cooldownElapsed(lastCleanup: lastCleanup, cooldown: settings.cleanupCooldown, now: now)
  }

  public static func dockerUntilFilter(for age: TimeInterval) -> String? {
    guard age.isFinite, age > 0, age <= maximumCleanupAge else { return nil }
    let hours = Int((age / 3600).rounded(.down))
    return "until=\(max(hours, 1))h"
  }

  public static func nextScanDate(lastScan: Date?, interval: TimeInterval, now: Date = .now) -> Date? {
    guard interval >= 30 * 60 else { return nil }
    guard let lastScan else { return now }
    let next = lastScan.addingTimeInterval(interval)
    return next <= now ? now : next
  }
}

public enum CleanupPlanner {
  private static let actionOrder: [CleanupResourceType] = [.containers, .networks, .images, .buildCache, .anonymousVolumes, .namedVolumes]
  private static let maximumExcludedLabels = 64
  private static let maximumLabelLength = 128

  public static func makePlan(request: CleanupRequest, inventory: DockerDiskUsage? = nil) throws -> CleanupPlan {
    let startedAt = Date.now
    guard !request.resourceTypes.isEmpty,
          request.minimumAge.isFinite,
          request.minimumAge >= 0,
          request.minimumAge <= CleanupPolicy.maximumCleanupAge else {
      throw DockerSweepError.invalidConfiguration
    }

    let actions = try actionOrder.compactMap { type -> CleanupAction? in
      guard request.resourceTypes.contains(type) else { return nil }
      return CleanupAction(
        resourceType: type,
        arguments: try CleanupCommandBuilder.arguments(for: type, request: request),
        scopeDescription: CleanupCommandBuilder.scopeDescription(for: type, request: request))
    }
    guard !actions.isEmpty else { throw DockerSweepError.invalidConfiguration }

    return CleanupPlan(
      request: request,
      actions: actions,
      inventorySnapshot: inventory,
      preparedInMilliseconds: max(0, Date.now.timeIntervalSince(startedAt) * 1_000))
  }

  fileprivate static func isSafeLabelFilter(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= maximumLabelLength else { return false }
    let components = value.split(separator: "=", omittingEmptySubsequences: false)
    guard components.count <= 2, !components[0].isEmpty,
          !components[0].hasPrefix("/"), !components[0].hasSuffix("/") else { return false }
    return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "=" || $0 == "/" }
  }

  fileprivate static func validateLabels(_ labels: [String]) throws {
    guard labels.count <= maximumExcludedLabels, labels.allSatisfy(isSafeLabelFilter) else {
      throw DockerSweepError.invalidConfiguration
    }
  }
}

public enum CleanupCommandBuilder {
  public static func arguments(for type: CleanupResourceType, request: CleanupRequest) throws -> [String] {
    guard request.minimumAge.isFinite,
          request.minimumAge >= 0,
          request.minimumAge <= CleanupPolicy.maximumCleanupAge else {
      throw DockerSweepError.invalidConfiguration
    }
    if type.isVolume { try CleanupPlanner.validateLabels(request.excludedLabels) }

    var args: [String]
    switch type {
    case .containers: args = ["container", "prune", "--force"]
    case .networks: args = ["network", "prune", "--force"]
    case .images: args = ["image", "prune", "--force"]
    case .buildCache: args = ["builder", "prune", "--force"]
    case .anonymousVolumes: args = ["volume", "prune", "--force"]
    case .namedVolumes: args = ["volume", "prune", "--all", "--force"]
    }

    if type == .images && request.cleanupAllUnusedImages { args.insert("--all", at: 2) }
    if let filter = CleanupPolicy.dockerUntilFilter(for: request.minimumAge) {
      args.append(contentsOf: ["--filter", filter])
    }
    if type.isVolume {
      for label in request.excludedLabels {
        args.append(contentsOf: ["--filter", "label!=\(label)"])
      }
    }
    return args
  }

  fileprivate static func scopeDescription(for type: CleanupResourceType, request: CleanupRequest) -> String {
    let resourceScope: String = switch type {
    case .buildCache: "Build cache"
    case .images: request.cleanupAllUnusedImages ? "All unused images" : "Dangling images"
    case .containers: "Stopped containers"
    case .networks: "Unused networks"
    case .anonymousVolumes: "Unused anonymous volumes"
    case .namedVolumes: "Unused named volumes"
    }

    var details = [resourceScope]
    if let ageFilter = CleanupPolicy.dockerUntilFilter(for: request.minimumAge) {
      let hours = max(Int((request.minimumAge / 3600).rounded(.down)), 1)
      details.append("Older than \(hours) hours (Docker filter: \(ageFilter))")
    } else {
      details.append("No minimum age filter")
    }
    if type.isVolume, !request.excludedLabels.isEmpty {
      details.append("Excluding labels: \(request.excludedLabels.joined(separator: ", "))")
    }
    return details.joined(separator: " · ")
  }
}
