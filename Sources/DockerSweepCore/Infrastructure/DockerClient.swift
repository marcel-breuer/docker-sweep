import Foundation

public protocol DockerClient: Sendable {
  func checkAvailability() async -> DockerAvailability
  func fetchDiskUsage() async throws -> DockerDiskUsage
  func prune(_ plan: ConfirmedCleanupPlan) async throws -> CleanupResult
}

public actor DockerCLIClient: DockerClient {
  private let runner: any ProcessRunning
  private var customPath: String?

  public init(runner: any ProcessRunning = LocalProcessRunner(), customPath: String? = nil) {
    self.runner = runner
    self.customPath = customPath
  }

  public func setCustomPath(_ path: String?) { customPath = path }

  public func checkAvailability() async -> DockerAvailability {
    guard let executable = findExecutable() else { return .notInstalled }
    do {
      let result = try await runner.run(executableURL: executable, arguments: ["version", "--format", "{{.Server.Version}}"], environment: environment(), timeout: 60)
      guard result.exitCode == 0 else {
        let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
        return .engineUnavailable(message: DockerOutputSanitizer.sanitize(message))
      }
      return .available(path: executable.path, version: result.standardOutput.isEmpty ? nil : result.standardOutput)
    } catch {
      return .commandFailed(message: DockerOutputSanitizer.sanitize(error.localizedDescription))
    }
  }

  public func fetchDiskUsage() async throws -> DockerDiskUsage {
    guard let executable = findExecutable() else { throw DockerSweepError.dockerExecutableNotFound }
    let result: ProcessResult
    do {
      result = try await runner.run(executableURL: executable, arguments: ["system", "df", "--format", "json"], environment: environment(), timeout: 60)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DockerSweepError {
      throw error
    } catch {
      throw DockerSweepError.commandFailed(exitCode: -1, message: DockerOutputSanitizer.sanitize(error.localizedDescription))
    }
    guard result.exitCode == 0 else {
      throw DockerSweepError.commandFailed(exitCode: result.exitCode, message: DockerOutputSanitizer.sanitize(result.standardError))
    }
    do { return try DockerSystemDFParser.parse(result.standardOutput) }
    catch {
      let fallback: ProcessResult
      do {
        fallback = try await runner.run(executableURL: executable, arguments: ["system", "df"], environment: environment(), timeout: 60)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as DockerSweepError {
        throw error
      } catch {
        throw DockerSweepError.commandFailed(exitCode: -1, message: DockerOutputSanitizer.sanitize(error.localizedDescription))
      }
      guard fallback.exitCode == 0 else {
        throw DockerSweepError.commandFailed(exitCode: fallback.exitCode, message: DockerOutputSanitizer.sanitize(fallback.standardError))
      }
      return try DockerSystemDFParser.parseTable(fallback.standardOutput)
    }
  }

  public func prune(_ confirmedPlan: ConfirmedCleanupPlan) async throws -> CleanupResult {
    guard let executable = findExecutable() else { throw DockerSweepError.dockerExecutableNotFound }
    let plan = confirmedPlan.plan
    guard !plan.actions.isEmpty else { throw DockerSweepError.invalidConfiguration }
    var results: [CleanupResourceResult] = []

    for action in plan.actions {
      try Task.checkCancellation()
      let startedAt = Date()
      do {
        let process = try await runner.run(executableURL: executable, arguments: action.arguments, environment: environment(), timeout: 10 * 60)
        let output = process.standardOutput.isEmpty ? process.standardError : process.standardOutput
        results.append(CleanupResourceResult(resourceType: action.resourceType, startedAt: startedAt, finishedAt: Date(), succeeded: process.exitCode == 0, exitCode: process.exitCode, reclaimedBytes: Self.reclaimedBytes(from: output), sanitizedOutput: DockerOutputSanitizer.sanitize(output), errorMessage: process.exitCode == 0 ? nil : DockerOutputSanitizer.sanitize(process.standardError)))
        if process.exitCode != 0 { break }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        results.append(CleanupResourceResult(resourceType: action.resourceType, startedAt: startedAt, finishedAt: Date(), succeeded: false, exitCode: -1, reclaimedBytes: nil, sanitizedOutput: nil, errorMessage: DockerOutputSanitizer.sanitize(error.localizedDescription)))
        break
      }
    }
    return CleanupResult(resourceResults: results)
  }

  private func findExecutable() -> URL? {
    let candidates = [customPath, "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
      .compactMap { $0 }
    let pathCandidates = environment()["PATH", default: ""].split(separator: ":").map { String($0) + "/docker" }
    for candidate in candidates + pathCandidates {
      if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
    }
    return nil
  }

  private func environment() -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    values["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    return values
  }

  private static func reclaimedBytes(from output: String) -> Int64? {
    guard let range = output.range(of: "reclaimed space:", options: .caseInsensitive) else { return nil }
    let value = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return DockerSystemDFParser.parseByteCount(String(value))
  }
}

enum DockerOutputSanitizer {
  static func sanitize(_ text: String, limit: Int = 500) -> String {
    var output = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    let replacements: [(pattern: String, template: String, options: String.CompareOptions)] = [
      (#"(https?://)[^/\s:@]+:[^/\s@]+@"#, "$1[REDACTED]@", [.regularExpression]),
      (#"(?i)(authorization\s*:\s*bearer\s+)[A-Za-z0-9._~+/-]+=*"#, "$1[REDACTED]", [.regularExpression]),
      (#"(?i)\b(password|passwd|token|secret|api[_-]?key)(\s*[=:]\s*)[^\s,;]+"#, "$1$2[REDACTED]", [.regularExpression])
    ]
    for replacement in replacements {
      output = output.replacingOccurrences(of: replacement.pattern, with: replacement.template, options: replacement.options)
    }
    return String(output.prefix(max(0, limit)))
  }
}

public enum DockerSystemDFParser {
  private struct Row: Decodable {
    let type: String?
    let totalCount: String?
    let active: String?
    let size: String?
    let reclaimable: String?

    enum CodingKeys: String, CodingKey { case type = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable" }
  }

  public static func parse(_ output: String) throws -> DockerDiskUsage {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw DockerSweepError.invalidOutput }

    if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
      if let rows = try? JSONDecoder().decode([Row].self, from: data) {
        guard !rows.isEmpty else { throw DockerSweepError.invalidOutput }
        return try usage(from: rows)
      }
      if let row = try? JSONDecoder().decode(Row.self, from: data) {
        return try usage(from: [row])
      }
      throw DockerSweepError.invalidOutput
    }

    var rows: [Row] = []
    for line in trimmed.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
            let row = try? JSONDecoder().decode(Row.self, from: data),
            !(row.type?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
        throw DockerSweepError.invalidOutput
      }
      rows.append(row)
    }
    return try usage(from: rows)
  }

  public static func parseTable(_ output: String) throws -> DockerDiskUsage {
    var rows: [Row] = []
    for line in output.split(whereSeparator: \.isNewline).dropFirst() {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      let type: String
      let remainder: Substring
      if text.hasPrefix("Local Volumes") {
        type = "Local Volumes"
        remainder = text.dropFirst("Local Volumes".count).drop(while: { $0 == " " || $0 == "\t" })
      } else if text.hasPrefix("Build Cache") {
        type = "Build Cache"
        remainder = text.dropFirst("Build Cache".count).drop(while: { $0 == " " || $0 == "\t" })
      } else {
        let split = text.split(separator: " ", maxSplits: 1)
        guard split.count == 2 else { throw DockerSweepError.invalidOutput }
        type = String(split[0])
        remainder = split[1]
      }
      let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard parts.count >= 4 else { throw DockerSweepError.invalidOutput }
      rows.append(Row(type: type, totalCount: parts[0], active: parts[1], size: parts[2], reclaimable: parts[3]))
    }
    guard !rows.isEmpty else { throw DockerSweepError.invalidOutput }
    return usage(from: rows)
  }

  public static func parseByteCount(_ value: String) -> Int64? {
    let cleaned = value.replacingOccurrences(of: ",", with: ".")
    guard let numberRange = cleaned.range(of: "^[0-9]+(?:\\.[0-9]+)?", options: .regularExpression), let number = Double(cleaned[numberRange]) else { return nil }
    let remainder = cleaned[numberRange.upperBound...].trimmingCharacters(in: .whitespaces)
    let unit = String(remainder.prefix { $0.isLetter }).lowercased()
    let multiplier: Double
    switch unit {
    case "kb": multiplier = 1_000
    case "kib": multiplier = 1_024
    case "mb": multiplier = 1_000_000
    case "mib": multiplier = 1_048_576
    case "gb": multiplier = 1_000_000_000
    case "gib": multiplier = 1_073_741_824
    case "tb": multiplier = 1_000_000_000_000
    case "tib": multiplier = 1_099_511_627_776
    default: multiplier = 1
    }
    let bytes = number * multiplier
    guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
    return Int64(bytes)
  }

  private static func usage(from rows: [Row]) throws -> DockerDiskUsage {
    var categorized: [String: ResourceDiskUsage] = [:]
    for row in rows {
      guard let type = row.type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else {
        throw DockerSweepError.invalidOutput
      }
      let category: String?
      if type.localizedCaseInsensitiveContains("images") { category = "images" }
      else if type.localizedCaseInsensitiveContains("containers") { category = "containers" }
      else if type.localizedCaseInsensitiveContains("local volumes") || type.localizedCaseInsensitiveContains("volumes") { category = "volumes" }
      else if type.localizedCaseInsensitiveContains("build cache") { category = "buildCache" }
      else { category = nil }
      guard let category else { continue }
      guard categorized[category] == nil,
            let totalCount = row.totalCount.flatMap(Int.init), totalCount >= 0,
            let size = row.size.flatMap(parseByteCount), size >= 0,
            let reclaimable = row.reclaimable.flatMap(parseByteCount), reclaimable >= 0 else {
        throw DockerSweepError.invalidOutput
      }
      let active = row.active.flatMap(Int.init)
      if row.active != nil && active == nil { throw DockerSweepError.invalidOutput }
      if let active, active < 0 { throw DockerSweepError.invalidOutput }
      if let active, active > totalCount { throw DockerSweepError.invalidOutput }
      if reclaimable > size { throw DockerSweepError.invalidOutput }
      categorized[category] = ResourceDiskUsage(totalCount: totalCount, activeCount: active, sizeBytes: size, reclaimableBytes: reclaimable)
    }
    guard !categorized.isEmpty else { throw DockerSweepError.invalidOutput }
    let byteCounts = ["images", "containers", "volumes", "buildCache"].compactMap { categorized[$0] }
    for values in [byteCounts.map(\.sizeBytes), byteCounts.map(\.reclaimableBytes)] {
      var total: Int64 = 0
      for value in values {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw DockerSweepError.invalidOutput }
        total = sum
      }
    }
    return DockerDiskUsage(
      images: categorized["images"] ?? .init(),
      containers: categorized["containers"] ?? .init(),
      volumes: categorized["volumes"] ?? .init(),
      buildCache: categorized["buildCache"] ?? .init())
  }
}
