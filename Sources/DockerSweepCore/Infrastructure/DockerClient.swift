import Foundation

public protocol DockerClient: Sendable {
  func checkAvailability() async -> DockerAvailability
  func fetchDiskUsage() async throws -> DockerDiskUsage
  func prune(_ request: CleanupRequest) async throws -> CleanupResult
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
        return .engineUnavailable(message: message)
      }
      return .available(path: executable.path, version: result.standardOutput.isEmpty ? nil : result.standardOutput)
    } catch {
      return .commandFailed(message: error.localizedDescription)
    }
  }

  public func fetchDiskUsage() async throws -> DockerDiskUsage {
    guard let executable = findExecutable() else { throw DockerSweepError.dockerExecutableNotFound }
    let result = try await runner.run(executableURL: executable, arguments: ["system", "df", "--format", "json"], environment: environment(), timeout: 60)
    guard result.exitCode == 0 else {
      throw DockerSweepError.commandFailed(exitCode: result.exitCode, message: result.standardError)
    }
    do { return try DockerSystemDFParser.parse(result.standardOutput) }
    catch {
      let fallback = try await runner.run(executableURL: executable, arguments: ["system", "df"], environment: environment(), timeout: 60)
      guard fallback.exitCode == 0 else { throw DockerSweepError.invalidOutput }
      return try DockerSystemDFParser.parseTable(fallback.standardOutput)
    }
  }

  public func prune(_ request: CleanupRequest) async throws -> CleanupResult {
    guard let executable = findExecutable() else { throw DockerSweepError.dockerExecutableNotFound }
    guard !request.resourceTypes.isEmpty else { throw DockerSweepError.invalidConfiguration }
    let order: [CleanupResourceType] = [.containers, .networks, .images, .buildCache, .anonymousVolumes, .namedVolumes]
    var results: [CleanupResourceResult] = []

    for type in order where request.resourceTypes.contains(type) {
      let startedAt = Date()
      do {
        let process = try await runner.run(executableURL: executable, arguments: CleanupCommandBuilder.arguments(for: type, request: request), environment: environment(), timeout: 10 * 60)
        let output = process.standardOutput.isEmpty ? process.standardError : process.standardOutput
        results.append(CleanupResourceResult(resourceType: type, startedAt: startedAt, finishedAt: Date(), succeeded: process.exitCode == 0, exitCode: process.exitCode, reclaimedBytes: Self.reclaimedBytes(from: output), sanitizedOutput: Self.sanitize(output), errorMessage: process.exitCode == 0 ? nil : Self.sanitize(process.standardError)))
        if process.exitCode != 0 { break }
      } catch {
        results.append(CleanupResourceResult(resourceType: type, startedAt: startedAt, finishedAt: Date(), succeeded: false, exitCode: -1, reclaimedBytes: nil, sanitizedOutput: nil, errorMessage: error.localizedDescription))
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

  private static func sanitize(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(500).description
  }

  private static func reclaimedBytes(from output: String) -> Int64? {
    guard let range = output.range(of: "reclaimed space:", options: .caseInsensitive) else { return nil }
    let value = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return DockerSystemDFParser.parseByteCount(String(value))
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
    let dataRows: [Data] = if let data = output.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { [data] } else { output.split(whereSeparator: \.isNewline).compactMap { $0.data(using: .utf8) } }
    let rows = dataRows.flatMap { data -> [Row] in
      if let array = try? JSONDecoder().decode([Row].self, from: data) { return array }
      if let row = try? JSONDecoder().decode(Row.self, from: data) { return [row] }
      return []
    }
    guard !rows.isEmpty else { throw DockerSweepError.invalidOutput }
    return usage(from: rows)
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
        guard split.count == 2 else { continue }
        type = String(split[0])
        remainder = split[1]
      }
      let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard parts.count >= 4 else { continue }
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
    return Int64(number * multiplier)
  }

  private static func usage(from rows: [Row]) -> DockerDiskUsage {
    func make(_ row: Row?) -> ResourceDiskUsage {
      guard let row else { return .init() }
      let total = Int(row.totalCount ?? "0") ?? 0
      let active = row.active.flatMap(Int.init)
      let size = parseByteCount(row.size ?? "0") ?? 0
      let reclaimable = parseByteCount(row.reclaimable ?? "0") ?? 0
      return ResourceDiskUsage(totalCount: total, activeCount: active, sizeBytes: size, reclaimableBytes: reclaimable)
    }
    func find(_ names: [String]) -> Row? { rows.first { row in names.contains { row.type?.localizedCaseInsensitiveContains($0) == true } } }
    return DockerDiskUsage(images: make(find(["Images"])), containers: make(find(["Containers"])), volumes: make(find(["Local Volumes", "Volumes"])), buildCache: make(find(["Build Cache"])))
  }
}
