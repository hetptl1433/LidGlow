import Darwin
import Foundation
import LidGlowCore

final class ProcessRunnerChecks {
  static func runAll() {
    let suite = ProcessRunnerChecks()
    Check.run("Process runner captures JSON and preserves nonzero exit", suite.successAndNonzero)
    Check.run("Process runner caps output without unbounded allocation", suite.outputCap)
    Check.run("Process runner bounds a silent hang and reaps its child", suite.silentHang)
    Check.run("Process runner escalates ignored TERM to KILL", suite.ignoredTerm)
    Check.run("Process runner never waits for descendant stdout EOF", suite.descendantPipe)
    Check.run("Process runner supports preflight and in-flight cancellation", suite.cancellation)
    Check.run("Process runner reports a missing executable", suite.missingExecutable)
  }

  private var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONNOUSERSITE"] = "1"
    env.removeValue(forKey: "PYTHONPATH")
    return env
  }
  private func run(
    _ script: String, timeout: TimeInterval = 10, cap: Int = 65536,
    cancelled: @escaping @Sendable () -> Bool = { false }
  ) -> ProcessRunResult {
    ProcessRunner.run(
      executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script],
      environment: environment, timeout: timeout, maxOutputBytes: cap, cancelled: cancelled)
  }
  func successAndNonzero() {
    // A cold system Python launch can take several seconds on hosted Macs.
    // Functional cases use the production timeout; deadline cases below pass
    // their own short limit and continue to verify bounded termination.
    let success = run("print('{\"ok\":true}')")
    Check.equal(success.status, 0)
    Check.equal(String(data: success.output, encoding: .utf8), "{\"ok\":true}\n")
    Check.isTrue(!success.timedOut && !success.cancelled && success.error == nil)
    let failure = run("import sys; sys.stderr.write('expected failure'); sys.exit(7)")
    Check.equal(failure.status, 7)
    Check.equal(String(data: failure.output, encoding: .utf8), "expected failure")
    Check.isTrue(failure.error == nil)
  }
  func outputCap() {
    let result = run("import sys; sys.stdout.write('a'*200000)")
    Check.equal(result.status, 0)
    Check.equal(result.output.count, 65536)
    Check.isTrue(result.output.allSatisfy { $0 == 97 })
    Check.isTrue(result.error?.contains("truncated") == true)
    let none = run("print('discard')", cap: 0)
    Check.equal(none.output.count, 0)
    Check.equal(none.status, 0)
  }
  func silentHang() {
    let began = ProcessInfo.processInfo.systemUptime
    let result = run("import os,time; print(os.getpid(),flush=True); time.sleep(30)", timeout: 0.15)
    Check.isTrue(result.timedOut && !result.cancelled)
    Check.isTrue(ProcessInfo.processInfo.systemUptime - began < 1)
    Check.equal(result.status, 128 + SIGTERM)
    if let text = String(data: result.output, encoding: .utf8),
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      Check.equal(
        Darwin.kill(pid, 0), -1, "The runner's child should already have exited and been reaped")
      Check.equal(errno, ESRCH)
    } else {
      Check.isTrue(false, "The fixture did not report its PID")
    }
  }
  func ignoredTerm() {
    let began = ProcessInfo.processInfo.systemUptime
    let result = run(
      "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(30)",
      timeout: 0.4)
    Check.isTrue(result.timedOut && !result.cancelled)
    Check.equal(result.status, 128 + SIGKILL)
    Check.equal(String(data: result.output, encoding: .utf8), "ready\n")
    Check.isTrue(ProcessInfo.processInfo.systemUptime - began < 1.1)
  }
  func descendantPipe() {
    let began = ProcessInfo.processInfo.systemUptime
    let result = run(
      "import os,time\npid=os.fork()\nif pid==0:\n time.sleep(0.6)\n os._exit(0)\nos.write(1,b'parent done')\nos._exit(0)"
    )
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    // The fixture's only descendant self-terminates; leave no live process
    // behind even if an assertion records a failure.
    defer { Thread.sleep(forTimeInterval: max(0, 0.7 - elapsed)) }
    Check.equal(result.status, 0)
    Check.equal(String(data: result.output, encoding: .utf8), "parent done")
    Check.isTrue(
      !result.timedOut && elapsed < 0.5, "Must not wait for descendant's inherited pipe to close")
  }
  func cancellation() {
    let preflight = run("raise Exception('must not launch')", cancelled: { true })
    Check.isTrue(preflight.cancelled && !preflight.timedOut)
    Check.equal(preflight.status, -1)
    let began = ProcessInfo.processInfo.systemUptime
    let cancelAt = began + 0.1
    let active = run(
      "import time; time.sleep(30)", timeout: 3,
      cancelled: { ProcessInfo.processInfo.systemUptime >= cancelAt })
    Check.isTrue(active.cancelled && !active.timedOut)
    Check.isTrue(ProcessInfo.processInfo.systemUptime - began < 1)
  }
  func missingExecutable() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "missing-" + UUID().uuidString)
    let result = ProcessRunner.run(executable: path, arguments: [], timeout: 0.2)
    Check.equal(result.status, -1)
    Check.isTrue(result.error != nil && !result.timedOut && !result.cancelled)
    Check.equal(result.output.count, 0)
  }
}
