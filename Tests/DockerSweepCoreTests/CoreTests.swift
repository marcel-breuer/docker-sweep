import XCTest
@testable import DockerSweepCore

final class CoreTests: XCTestCase {
  func testByteCountParserSupportsDockerUnits() {
    XCTAssertEqual(DockerSystemDFParser.parseByteCount("1.5GB"), 1_500_000_000)
    XCTAssertEqual(DockerSystemDFParser.parseByteCount("512MiB"), 536_870_912)
  }

  func testParsesDockerSystemDFJSONLines() throws {
    let output = #"""
{"Type":"Images","TotalCount": "4","Active": "1","Size":"2GB","Reclaimable":"1GB (50%)"}
{"Type":"Containers","TotalCount": "3","Active": "1","Size":"512MB","Reclaimable":"256MB (50%)"}
{"Type":"Local Volumes","TotalCount": "2","Active": "1","Size":"4GB","Reclaimable":"2GB (50%)"}
{"Type":"Build Cache","TotalCount": "8","Active": "0","Size":"1GB","Reclaimable":"1GB (100%)"}
"""#
    let usage = try DockerSystemDFParser.parse(output)
    XCTAssertEqual(usage.images.totalCount, 4)
    XCTAssertEqual(usage.images.sizeBytes, 2_000_000_000)
    XCTAssertEqual(usage.totalReclaimableBytes, 4_256_000_000)
  }

  func testParsesDockerSystemDFTableFallback() throws {
    let output = """
    TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
    Images          4         1         2GB       1GB (50%)
    Containers      3         1         512MB     256MB (50%)
    Local Volumes   2         1         4GB       2GB (50%)
    Build Cache     8         0         1GB       1GB (100%)
    """
    let usage = try DockerSystemDFParser.parseTable(output)
    XCTAssertEqual(usage.volumes.sizeBytes, 4_000_000_000)
    XCTAssertEqual(usage.buildCache.reclaimableBytes, 1_000_000_000)
  }

  func testCleanupCommandsAreSeparateAndVolumeSafe() {
    let request = CleanupRequest(resourceTypes: [.containers, .images, .namedVolumes], minimumAge: 7 * 24 * 60 * 60, cleanupAllUnusedImages: false, excludedLabels: ["docker-sweep.keep=true"], trigger: .manual)
    XCTAssertEqual(CleanupCommandBuilder.arguments(for: .containers, request: request), ["container", "prune", "--force", "--filter", "until=168h"])
    XCTAssertEqual(CleanupCommandBuilder.arguments(for: .images, request: request), ["image", "prune", "--force", "--filter", "until=168h"])
    XCTAssertEqual(CleanupCommandBuilder.arguments(for: .namedVolumes, request: request), ["volume", "prune", "--all", "--force", "--filter", "until=168h", "--filter", "label!=docker-sweep.keep=true"])
  }

  func testDefaultSettingsProtectVolumesAndDisableAutomaticCleanup() {
    let settings = AppSettings()
    XCTAssertFalse(settings.launchAtLogin)
    XCTAssertFalse(settings.cleanupAnonymousVolumes)
    XCTAssertFalse(settings.cleanupNamedVolumes)
    XCTAssertFalse(settings.automaticCleanupEnabled)
    XCTAssertTrue(settings.selectedResourceTypes.contains(.buildCache))
  }

  func testSettingsIgnoreRemovedNotificationSetting() throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
    object["notificationsEnabled"] = false
    let data = try JSONSerialization.data(withJSONObject: object)
    let settings = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertTrue(settings.cleanupBuildCache)
  }

  func testThresholdAndCooldownPolicy() {
    let usage = DockerDiskUsage(images: ResourceDiskUsage(sizeBytes: 31_000_000_000))
    var settings = AppSettings()
    settings.automaticCleanupEnabled = true
    XCTAssertTrue(CleanupPolicy.shouldAutomaticallyClean(settings: settings, usage: usage, lastCleanup: nil))
    XCTAssertFalse(CleanupPolicy.shouldAutomaticallyClean(settings: settings, usage: usage, lastCleanup: .now.addingTimeInterval(-60)))
    XCTAssertFalse(CleanupPolicy.thresholdExceeded(usageBytes: settings.cleanupThresholdBytes, thresholdBytes: settings.cleanupThresholdBytes))
  }

  func testAgeFilter() {
    XCTAssertNil(CleanupPolicy.dockerUntilFilter(for: 0))
    XCTAssertEqual(CleanupPolicy.dockerUntilFilter(for: 3 * 60 * 60 + 10), "until=3h")
  }
}
