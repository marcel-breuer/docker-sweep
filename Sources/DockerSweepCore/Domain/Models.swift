import Foundation

public enum CleanupResourceType: String, Codable, CaseIterable, Identifiable, Sendable {
  case buildCache
  case images
  case containers
  case networks
  case anonymousVolumes
  case namedVolumes

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .buildCache: "Build cache"
    case .images: "Dangling images"
    case .containers: "Stopped containers"
    case .networks: "Unused networks"
    case .anonymousVolumes: "Anonymous volumes"
    case .namedVolumes: "Named volumes"
    }
  }

  public var isVolume: Bool { self == .anonymousVolumes || self == .namedVolumes }
}

public enum CleanupTrigger: String, Codable, Sendable { case manual, threshold, scheduled }
public enum CleanupStatus: String, Codable, Sendable { case running, succeeded, partiallySucceeded, failed, cancelled }

public enum DockerAvailability: Codable, Sendable, Equatable {
  case notInstalled
  case engineUnavailable(message: String)
  case available(path: String, version: String?)
  case commandFailed(message: String)

  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  public var title: String {
    switch self {
    case .notInstalled: "Docker CLI not found"
    case .engineUnavailable: "Docker is not running"
    case .available: "Docker is ready"
    case .commandFailed: "Docker check failed"
    }
  }
}

public struct ResourceDiskUsage: Codable, Sendable, Equatable {
  public let totalCount: Int
  public let activeCount: Int?
  public let sizeBytes: Int64
  public let reclaimableBytes: Int64

  public init(totalCount: Int = 0, activeCount: Int? = nil, sizeBytes: Int64 = 0, reclaimableBytes: Int64 = 0) {
    self.totalCount = totalCount
    self.activeCount = activeCount
    self.sizeBytes = sizeBytes
    self.reclaimableBytes = reclaimableBytes
  }
}

public struct DockerDiskUsage: Codable, Sendable, Equatable {
  public let scannedAt: Date
  public let images: ResourceDiskUsage
  public let containers: ResourceDiskUsage
  public let volumes: ResourceDiskUsage
  public let buildCache: ResourceDiskUsage
  public let totalSizeBytes: Int64
  public let totalReclaimableBytes: Int64

  public init(
    scannedAt: Date = .now,
    images: ResourceDiskUsage = .init(),
    containers: ResourceDiskUsage = .init(),
    volumes: ResourceDiskUsage = .init(),
    buildCache: ResourceDiskUsage = .init()
  ) {
    self.scannedAt = scannedAt
    self.images = images
    self.containers = containers
    self.volumes = volumes
    self.buildCache = buildCache
    self.totalSizeBytes = images.sizeBytes + containers.sizeBytes + volumes.sizeBytes + buildCache.sizeBytes
    self.totalReclaimableBytes = images.reclaimableBytes + containers.reclaimableBytes + volumes.reclaimableBytes + buildCache.reclaimableBytes
  }
}

public struct AppSettings: Codable, Sendable, Equatable {
  public var launchAtLogin = false
  public var automaticScanningEnabled = true
  public var automaticCleanupEnabled = false
  public var scanInterval: TimeInterval = 6 * 60 * 60
  public var cleanupThresholdBytes: Int64 = 30 * 1_000_000_000
  public var cleanupCooldown: TimeInterval = 24 * 60 * 60
  public var minimumResourceAge: TimeInterval = 7 * 24 * 60 * 60
  public var cleanupBuildCache = true
  public var cleanupImages = true
  public var cleanupAllUnusedImages = false
  public var cleanupStoppedContainers = true
  public var cleanupNetworks = true
  public var cleanupAnonymousVolumes = false
  public var cleanupNamedVolumes = false
  public var excludedLabels = ["docker-sweep.keep=true", "keep"]
  public var notificationsEnabled = true
  public var customDockerPath: String?
  public var onboardingCompleted = false
  public var volumeWarningConfirmed = false
  public var requireManualConfirmation = true

  public init() {}

  public var selectedResourceTypes: Set<CleanupResourceType> {
    var result = Set<CleanupResourceType>()
    if cleanupBuildCache { result.insert(.buildCache) }
    if cleanupImages { result.insert(.images) }
    if cleanupStoppedContainers { result.insert(.containers) }
    if cleanupNetworks { result.insert(.networks) }
    if cleanupAnonymousVolumes { result.insert(.anonymousVolumes) }
    if cleanupNamedVolumes { result.insert(.namedVolumes) }
    return result
  }
}

public struct CleanupRequest: Sendable, Equatable {
  public let resourceTypes: Set<CleanupResourceType>
  public let minimumAge: TimeInterval
  public let cleanupAllUnusedImages: Bool
  public let excludedLabels: [String]
  public let trigger: CleanupTrigger

  public init(resourceTypes: Set<CleanupResourceType>, minimumAge: TimeInterval, cleanupAllUnusedImages: Bool, excludedLabels: [String], trigger: CleanupTrigger) {
    self.resourceTypes = resourceTypes
    self.minimumAge = minimumAge
    self.cleanupAllUnusedImages = cleanupAllUnusedImages
    self.excludedLabels = excludedLabels
    self.trigger = trigger
  }
}

public struct ProcessResult: Sendable, Equatable {
  public let exitCode: Int32
  public let standardOutput: String
  public let standardError: String
  public let duration: TimeInterval

  public init(exitCode: Int32, standardOutput: String, standardError: String, duration: TimeInterval) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.duration = duration
  }
}

public struct CleanupResourceResult: Codable, Sendable, Equatable {
  public let resourceType: CleanupResourceType
  public let startedAt: Date
  public let finishedAt: Date
  public let succeeded: Bool
  public let exitCode: Int32
  public let reclaimedBytes: Int64?
  public let sanitizedOutput: String?
  public let errorMessage: String?

  public init(resourceType: CleanupResourceType, startedAt: Date, finishedAt: Date, succeeded: Bool, exitCode: Int32, reclaimedBytes: Int64?, sanitizedOutput: String?, errorMessage: String?) {
    self.resourceType = resourceType
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.succeeded = succeeded
    self.exitCode = exitCode
    self.reclaimedBytes = reclaimedBytes
    self.sanitizedOutput = sanitizedOutput
    self.errorMessage = errorMessage
  }
}

public struct CleanupResult: Sendable, Equatable {
  public let resourceResults: [CleanupResourceResult]
  public var succeeded: Bool { resourceResults.allSatisfy(\.succeeded) }
  public var reclaimedBytes: Int64 { resourceResults.compactMap(\.reclaimedBytes).reduce(0, +) }
}

public struct CleanupRun: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public let startedAt: Date
  public let finishedAt: Date
  public let trigger: CleanupTrigger
  public let status: CleanupStatus
  public let selectedResources: Set<CleanupResourceType>
  public let diskUsageBeforeBytes: Int64?
  public let diskUsageAfterBytes: Int64?
  public let reclaimedBytes: Int64?
  public let resourceResults: [CleanupResourceResult]
  public let errorMessage: String?

  public init(id: UUID, startedAt: Date, finishedAt: Date, trigger: CleanupTrigger, status: CleanupStatus, selectedResources: Set<CleanupResourceType>, diskUsageBeforeBytes: Int64?, diskUsageAfterBytes: Int64?, reclaimedBytes: Int64?, resourceResults: [CleanupResourceResult], errorMessage: String?) {
    self.id = id
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.trigger = trigger
    self.status = status
    self.selectedResources = selectedResources
    self.diskUsageBeforeBytes = diskUsageBeforeBytes
    self.diskUsageAfterBytes = diskUsageAfterBytes
    self.reclaimedBytes = reclaimedBytes
    self.resourceResults = resourceResults
    self.errorMessage = errorMessage
  }
}

public enum DockerSweepError: LocalizedError, Sendable, Equatable {
  case dockerExecutableNotFound
  case dockerEngineUnavailable
  case unsupportedDockerVersion
  case commandTimedOut
  case commandFailed(exitCode: Int32, message: String)
  case invalidOutput
  case invalidConfiguration
  case persistenceFailed

  public var errorDescription: String? {
    switch self {
    case .dockerExecutableNotFound: "The Docker CLI could not be found."
    case .dockerEngineUnavailable: "Docker Desktop is not running or the Docker Engine is unavailable."
    case .unsupportedDockerVersion: "This Docker version does not provide the required disk usage output."
    case .commandTimedOut: "The Docker command timed out."
    case let .commandFailed(_, message): message
    case .invalidOutput: "Docker returned an output format DockerSweep could not read."
    case .invalidConfiguration: "The cleanup configuration is invalid."
    case .persistenceFailed: "DockerSweep could not save local state."
    }
  }
}
