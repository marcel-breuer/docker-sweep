import Foundation

public protocol ProcessRunning: Sendable {
  func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult
}

public final class LocalProcessRunner: ProcessRunning, @unchecked Sendable {
  public init() {}

  public func run(executableURL: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 60) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      let completion = ProcessCompletion(continuation: continuation)

      process.executableURL = executableURL
      process.arguments = arguments
      process.environment = environment
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      process.terminationHandler = { process in
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let result = ProcessResult(
          exitCode: process.terminationStatus,
          standardOutput: Self.safeString(output),
          standardError: Self.safeString(error))
        completion.success(result)
      }

      do {
        try process.run()
      } catch {
        completion.failure(error)
        return
      }

      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 1)) {
        guard process.isRunning else { return }
        process.terminate()
        completion.failure(DockerSweepError.commandTimedOut)
      }
    }
  }

  private static func safeString(_ data: Data) -> String {
    let maxBytes = 256 * 1024
    let clipped = data.count > maxBytes ? data.prefix(maxBytes) : data
    return String(decoding: clipped, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class ProcessCompletion: @unchecked Sendable {
  private let continuation: CheckedContinuation<ProcessResult, Error>
  private let lock = NSLock()
  private var finished = false

  init(continuation: CheckedContinuation<ProcessResult, Error>) { self.continuation = continuation }

  func success(_ value: ProcessResult) { finish(.success(value)) }
  func failure(_ error: Error) { finish(.failure(error)) }

  private func finish(_ result: Result<ProcessResult, Error>) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    lock.unlock()
    continuation.resume(with: result)
  }
}
