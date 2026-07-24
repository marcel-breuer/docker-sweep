import Foundation

public actor SettingsStore {
  private let fileURL: URL

  public init(directory: URL? = nil) {
    let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DockerSweep", isDirectory: true)
    fileURL = base.appendingPathComponent("settings.json")
  }

  public func load() -> AppSettings {
    guard let data = try? Data(contentsOf: fileURL), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
    return settings
  }

  public func save(_ settings: AppSettings) throws {
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(settings)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw DockerSweepError.persistenceFailed
    }
  }
}

public actor CleanupHistoryStore {
  private let fileURL: URL

  public init(directory: URL? = nil) {
    let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DockerSweep", isDirectory: true)
    fileURL = base.appendingPathComponent("cleanup-history.json")
  }

  public func load() -> [CleanupRun] {
    guard let data = try? Data(contentsOf: fileURL), let history = try? JSONDecoder().decode([CleanupRun].self, from: data) else { return [] }
    return history.sorted { $0.finishedAt > $1.finishedAt }
  }

  public func save(_ run: CleanupRun) throws {
    var history = load()
    history.insert(run, at: 0)
    let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
    history = Array(history.filter { $0.finishedAt >= cutoff }.prefix(100))
    try write(history)
  }

  public func deleteAll() throws { try write([]) }

  private func write(_ history: [CleanupRun]) throws {
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(history).write(to: fileURL, options: .atomic)
    } catch {
      throw DockerSweepError.persistenceFailed
    }
  }
}

public actor FileLogger {
  private let directory: URL
  private let fileURL: URL
  private let maxBytes = 5 * 1024 * 1024
  private let maxRotations = 5

  public init(directory: URL? = nil) {
    let base = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/DockerSweep", isDirectory: true)
    self.directory = base
    self.fileURL = base.appendingPathComponent("docker-sweep.log")
  }

  public func log(_ message: String) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try rotateIfNeeded()
      let line = "[\(ISO8601DateFormatter().string(from: .now))] \(message.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))\n"
      if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
          let handle = try FileHandle(forWritingTo: fileURL)
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
          try handle.close()
        } else {
          try data.write(to: fileURL, options: .atomic)
        }
      }
    } catch {
      // Logging must never take down the menu-bar application.
    }
  }

  private func rotateIfNeeded() throws {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path), let size = attributes[.size] as? NSNumber, size.intValue >= maxBytes else { return }
    let manager = FileManager.default
    for index in stride(from: maxRotations - 1, through: 1, by: -1) {
      let old = fileURL.appendingPathExtension("\(index)")
      let next = fileURL.appendingPathExtension("\(index + 1)")
      if manager.fileExists(atPath: old.path) { try? manager.removeItem(at: next) ; try? manager.moveItem(at: old, to: next) }
    }
    let first = fileURL.appendingPathExtension("1")
    try? manager.removeItem(at: first)
    try manager.moveItem(at: fileURL, to: first)
  }
}
