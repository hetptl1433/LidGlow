import Darwin
import Foundation

public struct ProcessRunResult: Sendable {
  /// Exit code, or 128 + signal for a signalled child. -1 means no exit status.
  public let status: Int32
  public let output: Data
  public let timedOut: Bool
  public let cancelled: Bool
  public let error: String?
}

/// Runs one local helper without an unbounded EOF read or waitUntilExit call.
/// Invoke from a worker task. Foundation monitors and reaps its own child;
/// descendant processes are never signalled and cannot extend the output wait.
/// The cancellation predicate must be quick and safe to call from that worker.
public enum ProcessRunner {
  public static func run(
    executable: URL, arguments: [String],
    environment: [String: String]? = nil,
    timeout: TimeInterval = 10, maxOutputBytes: Int = 65536,
    cancelled: @escaping @Sendable () -> Bool = { false }
  ) -> ProcessRunResult {
    guard executable.isFileURL else {
      return ProcessRunResult(
        status: -1, output: Data(), timedOut: false, cancelled: false,
        error: "The helper executable must be a local file URL.")
    }
    guard timeout.isFinite, timeout > 0 else {
      return ProcessRunResult(
        status: -1, output: Data(), timedOut: false, cancelled: false,
        error: "The process timeout must be finite and positive.")
    }
    if cancelled() {
      return ProcessRunResult(
        status: -1, output: Data(), timedOut: false, cancelled: true, error: nil)
    }

    let process = Process()
    let pipe = Pipe()
    let readHandle = pipe.fileHandleForReading
    let writeHandle = pipe.fileHandleForWriting
    defer {
      try? readHandle.close()
      try? writeHandle.close()
    }
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    // A termination handler lets Foundation retain its monitor/reaper even
    // if a kernel-delayed exit outlasts this function's bounded grace period.
    process.terminationHandler = { _ in }

    let descriptor = readHandle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      return ProcessRunResult(
        status: -1, output: Data(), timedOut: false, cancelled: false,
        error: "Could not configure the helper output pipe.")
    }

    let began = ProcessInfo.processInfo.systemUptime
    let deadline = began + timeout
    do { try process.run() } catch {
      return ProcessRunResult(
        status: -1, output: Data(), timedOut: false, cancelled: false,
        error: error.localizedDescription)
    }
    // Only the launched process and any descendants keep a writer now.
    try? writeHandle.close()

    var output = Data()
    let limit = max(0, maxOutputBytes)
    var buffer = [UInt8](repeating: 0, count: 8192)
    var readOpen = true
    var truncated = false
    var ioFailed = false
    var didTimeout = false
    var didCancel = false
    var terminatedAt: TimeInterval?
    var killed = false

    func drain(maxReads: Int) {
      guard readOpen else { return }
      for _ in 0..<maxReads {
        let count = read(descriptor, &buffer, buffer.count)
        if count == 0 {
          readOpen = false
          return
        }
        if count < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { return }
          ioFailed = true
          readOpen = false
          return
        }
        let stored = min(count, max(0, limit - output.count))
        if stored > 0 { output.append(buffer, count: stored) }
        if stored < count { truncated = true }
      }
    }

    while true {
      let now = ProcessInfo.processInfo.systemUptime
      if terminatedAt == nil {
        if cancelled() { didCancel = true } else if now >= deadline { didTimeout = true }
        if didCancel || didTimeout {
          terminatedAt = now
          if process.isRunning { process.terminate() }
        }
      }

      drain(maxReads: 4)
      if !process.isRunning {
        // Drain only already available bytes. A descendant can retain
        // stdout forever or keep writing; neither extends our lifetime.
        drain(maxReads: 16)
        break
      }

      if let terminatedAt {
        if now - terminatedAt >= 0.15 && !killed {
          if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
          killed = true
        }
        if now - terminatedAt >= 0.40 { break }
      }

      let nextDeadline = terminatedAt.map { $0 + 0.40 } ?? deadline
      let wait = Int32(max(1, min(20, (nextDeadline - now) * 1000)))
      if readOpen {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, wait)
        if ready < 0 && errno != EINTR {
          ioFailed = true
          readOpen = false
        }
        if ready > 0 && event.revents & Int16(POLLNVAL) != 0 {
          ioFailed = true
          readOpen = false
        }
      } else {
        // Closed stdout with a still-running child must not busy-spin.
        _ = poll(nil, 0, wait)
      }
    }

    let stillRunning = process.isRunning
    let status: Int32
    if stillRunning {
      status = -1
    } else {
      let value = process.terminationStatus
      status = process.terminationReason == .uncaughtSignal ? 128 + value : value
    }
    let error: String?
    if stillRunning {
      error = "The helper did not exit within the termination grace period."
    } else if ioFailed {
      error = "The helper output pipe could not be read."
    } else if truncated {
      error = "Helper output was truncated to \(limit) bytes."
    } else {
      error = nil
    }
    return ProcessRunResult(
      status: status, output: output, timedOut: didTimeout, cancelled: didCancel, error: error)
  }
}
