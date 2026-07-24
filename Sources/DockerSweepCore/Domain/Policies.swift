import Foundation

public enum CleanupPolicy {
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

  public static func dockerUntilFilter(for age: TimeInterval) -> String? {
    guard age > 0 else { return nil }
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

public enum CleanupCommandBuilder {
  public static func arguments(for type: CleanupResourceType, request: CleanupRequest) -> [String] {
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
      for label in request.excludedLabels where Self.isSafeLabelFilter(label) {
        args.append(contentsOf: ["--filter", "label!=\(label)"])
      }
    }
    return args
  }

  private static func isSafeLabelFilter(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "=" || $0 == "/" }
  }
}
