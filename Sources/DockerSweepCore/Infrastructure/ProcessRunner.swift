import Foundation

public protocol ProcessRunning: Sendable {
  func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult
}

public final class LocalProcessRunner: ProcessRunning, @unchecked Sendable {
  private static let maximumCapturedOutputBytes = 256 * 1024
  private static let readChunkSize = 16 * 1024

  public init() {}

  public func run(executableURL: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 60) async throws -> ProcessResult {
    guard timeout.isFinite, timeout >= 0 else { throw DockerSweepError.invalidConfiguration }

    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let output = BoundedOutputCapture(limit: Self.maximumCapturedOutputBytes)
    let errorOutput = BoundedOutputCapture(limit: Self.maximumCapturedOutputBytes)
    let execution = ProcessExecution()
    let readers = DispatchGroup()
    readers.enter()
    readers.enter()

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.terminationHandler = { terminatedProcess in
      terminatedProcess.terminationHandler = nil
      readers.notify(queue: DispatchQueue.global(qos: .utility)) {
        execution.succeed(ProcessResult(
          exitCode: terminatedProcess.terminationStatus,
          standardOutput: Self.safeString(output.data),
          standardError: Self.safeString(errorOutput.data)))
      }
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
        execution.install(continuation)
        do {
          try execution.start(process)
        } catch {
          readers.leave()
          readers.leave()
          execution.fail(error)
          return
        }

        DispatchQueue.global(qos: .utility).async {
          Self.drain(outputPipe.fileHandleForReading, into: output)
          readers.leave()
        }
        DispatchQueue.global(qos: .utility).async {
          Self.drain(errorPipe.fileHandleForReading, into: errorOutput)
          readers.leave()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          execution.timeout()
        }
      }
    } onCancel: {
      execution.cancel()
    }
  }

  private static func safeString(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func drain(_ handle: FileHandle, into output: BoundedOutputCapture) {
    defer { try? handle.close() }
    while true {
      let chunk = handle.readData(ofLength: readChunkSize)
      guard !chunk.isEmpty else { return }
      output.append(chunk)
    }
  }
}

final class BoundedOutputCapture: @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var captured = Data()

  init(limit: Int) { self.limit = max(0, limit) }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    let available = limit - captured.count
    guard available > 0 else { return }
    captured.append(data.prefix(available))
  }
}

private final class ProcessExecution: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var continuation: CheckedContinuation<ProcessResult, Error>?
  private var hasFinished = false
  private var wasCancelled = false

  func install(_ continuation: CheckedContinuation<ProcessResult, Error>) {
    lock.lock()
    self.continuation = continuation
    let cancelled = wasCancelled
    lock.unlock()
    if cancelled { finish(.failure(CancellationError())) }
  }

  func start(_ process: Process) throws {
    lock.lock()
    guard !wasCancelled, !hasFinished else {
      lock.unlock()
      throw CancellationError()
    }
    self.process = process
    do {
      try process.run()
      lock.unlock()
    } catch {
      lock.unlock()
      throw error
    }
  }

  func cancel() {
    lock.lock()
    wasCancelled = true
    let process = self.process
    lock.unlock()
    if process?.isRunning == true { process?.terminate() }
    finish(.failure(CancellationError()))
  }

  func timeout() {
    lock.lock()
    guard !hasFinished, let process, process.isRunning else {
      lock.unlock()
      return
    }
    lock.unlock()
    process.terminate()
    finish(.failure(DockerSweepError.commandTimedOut))
  }

  func succeed(_ result: ProcessResult) { finish(.success(result)) }
  func fail(_ error: Error) { finish(.failure(error)) }

  private func finish(_ result: Result<ProcessResult, Error>) {
    lock.lock()
    guard !hasFinished, let continuation else { lock.unlock(); return }
    hasFinished = true
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}
