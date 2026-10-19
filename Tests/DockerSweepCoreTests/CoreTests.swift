import XCTest
@testable import DockerSweepCore

final class CoreTests: XCTestCase {
  func testByteCountParserSupportsDockerUnits() {
    XCTAssertEqual(DockerSystemDFParser.parseByteCount("1.5GB"), 1_500_000_000)
    XCTAssertEqual(DockerSystemDFParser.parseByteCount("512MiB"), 536_870_912)
    XCTAssertEqual(DockerSystemDFParser.parseByteCount("1GB (50%)"), 1_000_000_000)
    XCTAssertNil(DockerSystemDFParser.parseByteCount("1GBjunk"))
    XCTAssertNil(DockerSystemDFParser.parseByteCount("999999999999999999999999999999TB"))
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

  func testMalformedDockerOutputIsRejectedInsteadOfPartiallyParsed() {
    let output = #"""
    {"Type":"Images","TotalCount":"4","Active":"1","Size":"2GB","Reclaimable":"1GB"}
    not-json
    """#
    XCTAssertThrowsError(try DockerSystemDFParser.parse(output)) { error in
      XCTAssertEqual(error as? DockerSweepError, .invalidOutput)
    }
  }

  func testCleanupCommandsAreSeparateAndVolumeSafe() throws {
    let request = CleanupRequest(resourceTypes: [.containers, .images, .namedVolumes], minimumAge: 7 * 24 * 60 * 60, cleanupAllUnusedImages: false, excludedLabels: ["docker-sweep.keep=true"], trigger: .manual)
    XCTAssertEqual(try CleanupCommandBuilder.arguments(for: .containers, request: request), ["container", "prune", "--force", "--filter", "until=168h"])
    XCTAssertEqual(try CleanupCommandBuilder.arguments(for: .images, request: request), ["image", "prune", "--force", "--filter", "until=168h"])
    XCTAssertEqual(try CleanupCommandBuilder.arguments(for: .namedVolumes, request: request), ["volume", "prune", "--all", "--force", "--filter", "until=168h", "--filter", "label!=docker-sweep.keep=true"])
  }

  func testPreviewAndExecutionShareOneConfirmedPlanAndInventorySnapshot() throws {
    let inventory = DockerDiskUsage(images: ResourceDiskUsage(totalCount: 4, activeCount: 1, sizeBytes: 2_000_000_000, reclaimableBytes: 1_000_000_000))
    let request = CleanupRequest(resourceTypes: [.images, .namedVolumes], minimumAge: 7 * 24 * 60 * 60, cleanupAllUnusedImages: false, excludedLabels: ["docker-sweep.keep=true"], trigger: .manual)

    let previewPlan = try CleanupPlanner.makePlan(request: request, inventory: inventory)
    let authorizedPlan = previewPlan.authorizeExecution()

    XCTAssertEqual(previewPlan.inventorySnapshot, inventory)
    XCTAssertEqual(previewPlan.actions.map(\.resourceType), [.images, .namedVolumes])
    XCTAssertTrue(previewPlan.requiresExplicitConfirmation)
    XCTAssertEqual(previewPlan.actions[0].arguments, ["image", "prune", "--force", "--filter", "until=168h"])
    XCTAssertEqual(previewPlan.actions[0].scopeDescription, "Dangling images · Older than 168 hours (Docker filter: until=168h)")
    XCTAssertEqual(previewPlan.actions[1].scopeDescription, "Unused named volumes · Older than 168 hours (Docker filter: until=168h) · Excluding labels: docker-sweep.keep=true")
    XCTAssertGreaterThanOrEqual(previewPlan.preparedInMilliseconds, 0)
    XCTAssertEqual(authorizedPlan.plan, previewPlan)
    XCTAssertEqual(authorizedPlan.plan.actions, previewPlan.actions)
  }

  func testUnsafeVolumeExclusionLabelFailsClosed() {
    let request = CleanupRequest(resourceTypes: [.namedVolumes], minimumAge: 7 * 24 * 60 * 60, cleanupAllUnusedImages: false, excludedLabels: ["docker-sweep.keep=true", "bad label"], trigger: .manual)

    XCTAssertThrowsError(try CleanupPlanner.makePlan(request: request)) { error in
      XCTAssertEqual(error as? DockerSweepError, .invalidConfiguration)
    }
  }

  func testDockerOutputSanitizerRedactsCredentialsAndBoundsErrorText() {
    let sanitized = DockerOutputSanitizer.sanitize("https://user:password@example.com Authorization: Bearer abc.def token=secret")
    XCTAssertEqual(sanitized, "https://[REDACTED]@example.com Authorization: Bearer [REDACTED] token=[REDACTED]")
    XCTAssertEqual(DockerOutputSanitizer.sanitize(String(repeating: "x", count: 600)).count, 500)
  }

  func testProcessOutputCaptureHasAHardLimit() {
    let output = BoundedOutputCapture(limit: 16)
    output.append(Data(repeating: 65, count: 32))
    output.append(Data("later".utf8))
    XCTAssertEqual(output.data, Data(repeating: 65, count: 16))
  }

  func testLocalProcessRunnerTimesOutAndTerminatesAProcess() async {
    let runner = LocalProcessRunner()
    do {
      _ = try await runner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:], timeout: 0.05)
      XCTFail("Expected the process to time out")
    } catch let error as DockerSweepError {
      XCTAssertEqual(error, .commandTimedOut)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testLocalProcessRunnerPropagatesTaskCancellation() async throws {
    let runner = LocalProcessRunner()
    let task = Task {
      try await runner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:], timeout: 30)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected the process task to be cancelled")
    } catch is CancellationError {
      // Expected.
    }
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
