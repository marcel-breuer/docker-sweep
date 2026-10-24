import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol DockerClient: Sendable {
  func checkAvailability() async -> DockerAvailability
  func fetchDiskUsage() async throws -> DockerDiskUsage
  func fetchCleanupCandidates(excludedLabels: [String]) async throws -> [CleanupCandidate]
  func removeCleanupCandidates(_ candidates: [CleanupCandidate], minimumAge: TimeInterval, excludedLabels: [String]) async -> [CleanupResourceResult]
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

  public func activeContextName() async -> String? {
    guard let executable = findExecutable(),
          let result = try? await runner.run(executableURL: executable, arguments: ["context", "show"], environment: environment(), timeout: 30),
          result.exitCode == 0 else { return nil }
    let name = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  public func activeContextIsLocal() async -> Bool {
    guard let executable = findExecutable(),
          let result = try? await runner.run(executableURL: executable, arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], environment: environment(), timeout: 30),
          result.exitCode == 0 else { return false }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://")
  }

  public func fetchCleanupCandidates(excludedLabels: [String]) async throws -> [CleanupCandidate] {
    guard let executable = findExecutable() else { throw DockerSweepError.dockerExecutableNotFound }
    let specs: [(CleanupResourceType, [String], String, String)] = [
      (.containers, ["container", "ls", "--all", "--filter", "status=exited", "--size", "--format", "{{json .}}"], "ID", "Names"),
      (.images, ["image", "ls", "--all", "--filter", "dangling=true", "--format", "{{json .}}"], "ID", "Repository"),
      (.networks, ["network", "ls", "--filter", "dangling=true", "--format", "{{json .}}"], "ID", "Name"),
    ]
    var candidates: [CleanupCandidate] = []
    for (type, arguments, idKey, nameKey) in specs {
      let result = try await runner.run(executableURL: executable, arguments: arguments, environment: environment(), timeout: 60)
      guard result.exitCode == 0 else {
        throw DockerSweepError.commandFailed(exitCode: result.exitCode, message: DockerOutputSanitizer.sanitize(result.standardError))
      }
      candidates.append(contentsOf: Self.candidates(from: result.standardOutput, type: type, idKey: idKey, nameKey: nameKey))
    }
    let volumeResult = try await runner.run(executableURL: executable, arguments: ["volume", "ls", "--all", "--filter", "dangling=true", "--format", "{{json .}}"], environment: environment(), timeout: 60)
    guard volumeResult.exitCode == 0 else {
      throw DockerSweepError.commandFailed(exitCode: volumeResult.exitCode, message: DockerOutputSanitizer.sanitize(volumeResult.standardError))
    }
    candidates.append(contentsOf: Self.volumeCandidates(from: volumeResult.standardOutput, excludedLabels: Set(excludedLabels)))
    var createdDates: [String: Date] = [:]
    for type in Set(candidates.map(\.resourceType)) {
      let matching = candidates.filter { $0.resourceType == type }
      let subcommand: String = switch type {
      case .containers: "container"
      case .images: "image"
      case .networks: "network"
      case .anonymousVolumes, .namedVolumes: "volume"
      case .buildCache: continue
      }
      let identityField = type.isVolume ? "Name" : "Id"
      let createdField = type.isVolume ? "CreatedAt" : "Created"
      let template = "{{.\(identityField)}}|{{.\(createdField)}}"
      let inspected = try? await runner.run(executableURL: executable, arguments: [subcommand, "inspect", "--format", template] + matching.map(\.id), environment: environment(), timeout: 60)
      guard let inspected, inspected.exitCode == 0 else { continue }
      for line in inspected.standardOutput.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
        guard fields.count == 2, let date = Self.parseDockerDate(fields[1]) else { continue }
        let matched = matching.first { candidate in
          type.isVolume ? candidate.id == fields[0] : candidate.id.hasPrefix(fields[0]) || fields[0].hasPrefix(candidate.id)
        }
        if let matched { createdDates[Self.candidateKey(matched)] = date }
      }
    }
    let datedCandidates = candidates.map { candidate in
      CleanupCandidate(id: candidate.id, resourceType: candidate.resourceType, name: candidate.name, createdAt: createdDates[Self.candidateKey(candidate)], estimatedBytes: candidate.estimatedBytes, isInUse: candidate.isInUse, isProtected: candidate.isProtected)
    }
    return datedCandidates.sorted { ($0.estimatedBytes ?? 0) > ($1.estimatedBytes ?? 0) }
  }

  public func removeCleanupCandidates(_ candidates: [CleanupCandidate], minimumAge: TimeInterval, excludedLabels: [String]) async -> [CleanupResourceResult] {
    guard let executable = findExecutable() else {
      return candidates.map { candidate in
        CleanupResourceResult(resourceType: candidate.resourceType, startedAt: .now, finishedAt: .now, succeeded: false, exitCode: -1, reclaimedBytes: nil, sanitizedOutput: nil, errorMessage: "Docker CLI is unavailable.")
      }
    }
    let freshCandidates = (try? await fetchCleanupCandidates(excludedLabels: excludedLabels)) ?? []
    let freshByID = Dictionary(uniqueKeysWithValues: freshCandidates.map { (Self.candidateKey($0), $0) })
    var results: [CleanupResourceResult] = []
    for candidate in candidates {
      let started = Date()
      guard candidate.canBeSelected,
            let current = freshByID[Self.candidateKey(candidate)],
            current.canBeSelected, minimumAge == 0 || current.createdAt.map({ Date().timeIntervalSince($0) >= minimumAge }) == true else {
        results.append(CleanupResourceResult(resourceType: candidate.resourceType, startedAt: started, finishedAt: Date(), succeeded: false, exitCode: 1, reclaimedBytes: nil, sanitizedOutput: nil, errorMessage: "Resource changed, is protected, or is younger than the minimum age."))
        continue
      }
      let subcommand: String = switch candidate.resourceType {
      case .containers: "container"
      case .images: "image"
      case .networks: "network"
      case .anonymousVolumes, .namedVolumes: "volume"
      case .buildCache: continue
      }
      do {
        let process = try await runner.run(executableURL: executable, arguments: [subcommand, "rm", current.id], environment: environment(), timeout: 10 * 60)
        let output = process.standardOutput.isEmpty ? process.standardError : process.standardOutput
        results.append(CleanupResourceResult(resourceType: candidate.resourceType, startedAt: started, finishedAt: Date(), succeeded: process.exitCode == 0, exitCode: process.exitCode, reclaimedBytes: nil, sanitizedOutput: DockerOutputSanitizer.sanitize(output), errorMessage: process.exitCode == 0 ? nil : DockerOutputSanitizer.sanitize(process.standardError)))
      } catch {
        results.append(CleanupResourceResult(resourceType: candidate.resourceType, startedAt: started, finishedAt: Date(), succeeded: false, exitCode: -1, reclaimedBytes: nil, sanitizedOutput: nil, errorMessage: DockerOutputSanitizer.sanitize(error.localizedDescription)))
      }
    }
    return results
  }

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

  private static func candidates(from output: String, type: CleanupResourceType, idKey: String, nameKey: String) -> [CleanupCandidate] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      guard let data = String(line).data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = row[idKey] as? String, !id.isEmpty else { return nil }
      let name = (row[nameKey] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
      let size = (row["Size"] as? String).flatMap(DockerSystemDFParser.parseByteCount)
      return CleanupCandidate(id: id, resourceType: type, name: name, estimatedBytes: size)
    }
  }

  private static func candidateKey(_ candidate: CleanupCandidate) -> String {
    "\(candidate.resourceType.rawValue):\(candidate.id)"
  }

  private static func volumeCandidates(from output: String, excludedLabels: Set<String>) -> [CleanupCandidate] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      guard let data = String(line).data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = row["Name"] as? String, !name.isEmpty else { return nil }
      let labels = row["Labels"] as? String ?? ""
      let pairs = labels.split(separator: ",").map(String.init)
      let protected = excludedLabels.contains { excluded in
        pairs.contains(where: { $0 == excluded || $0.hasPrefix(excluded + "=") })
      }
      let type: CleanupResourceType = name.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil ? .namedVolumes : .anonymousVolumes
      return CleanupCandidate(id: name, resourceType: type, name: name, isProtected: protected)
    }
  }

  private static func parseDockerDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let standard = ISO8601DateFormatter()
    if let date = standard.date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
    return formatter.date(from: value)
  }
}

public enum DockerHostStorageProbe {
  public static func measure(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, includeDockerImage: Bool = true) -> HostDiskUsage? {
    let image = homeDirectory.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    let hasImage = includeDockerImage && FileManager.default.fileExists(atPath: image.path)
    let storageVolume = hasImage ? image : homeDirectory
    let volumeValues = try? storageVolume.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
    guard let available = volumeValues?.volumeAvailableCapacity else { return nil }
    let imageValues = hasImage ? try? image.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) : nil
    return HostDiskUsage(
      availableBytes: Int64(available),
      totalBytes: volumeValues?.volumeTotalCapacity.map(Int64.init),
      dockerImageAllocatedBytes: imageValues?.fileAllocatedSize.map(Int64.init),
      dockerImageCapacityBytes: imageValues?.fileSize.map(Int64.init))
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
    return try usage(from: rows)
  }

  public static func parseByteCount(_ value: String) -> Int64? {
    let cleaned = value.replacingOccurrences(of: ",", with: ".")
    guard let numberRange = cleaned.range(of: "^[0-9]+(?:\\.[0-9]+)?", options: .regularExpression), let number = Double(cleaned[numberRange]) else { return nil }
    let remainder = cleaned[numberRange.upperBound...].trimmingCharacters(in: .whitespaces)
    let unit = String(remainder.prefix { $0.isLetter }).lowercased()
    let annotation = remainder.dropFirst(unit.count).trimmingCharacters(in: .whitespaces)
    guard annotation.isEmpty || annotation.range(of: "^\\([0-9]+(?:\\.[0-9]+)?%\\)$", options: .regularExpression) != nil else { return nil }
    let multiplier: Double
    switch unit {
    case "", "b", "bytes": multiplier = 1
    case "kb": multiplier = 1_000
    case "kib": multiplier = 1_024
    case "mb": multiplier = 1_000_000
    case "mib": multiplier = 1_048_576
    case "gb": multiplier = 1_000_000_000
    case "gib": multiplier = 1_073_741_824
    case "tb": multiplier = 1_000_000_000_000
    case "tib": multiplier = 1_099_511_627_776
    default: return nil
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
