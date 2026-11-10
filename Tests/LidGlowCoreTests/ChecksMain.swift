import Darwin
import Foundation

/// A dependency-free assertion runner for hosts with Command Line Tools only.
enum Check {
  private(set) static var assertions = 0
  private(set) static var failures = 0
  private(set) static var cases = 0

  static func isTrue(
    _ condition: @autoclosure () -> Bool, _ context: String = "", file: StaticString = #fileID,
    line: UInt = #line
  ) {
    assertions += 1
    if !condition() { fail(context.isEmpty ? "Expected true" : context, file: file, line: line) }
  }

  static func equal<T: Equatable>(
    _ actual: T, _ expected: T, _ context: String = "", file: StaticString = #fileID,
    line: UInt = #line
  ) {
    assertions += 1
    if actual != expected {
      fail("Expected \(expected), got \(actual). \(context)", file: file, line: line)
    }
  }

  static func notEqual<T: Equatable>(
    _ actual: T, _ unexpected: T, _ context: String = "", file: StaticString = #fileID,
    line: UInt = #line
  ) {
    assertions += 1
    if actual == unexpected {
      fail("Expected values to differ: \(actual). \(context)", file: file, line: line)
    }
  }

  static func greaterThan<T: Comparable>(
    _ actual: T, _ lowerBound: T, _ context: String = "", file: StaticString = #fileID,
    line: UInt = #line
  ) {
    assertions += 1
    if actual <= lowerBound {
      fail("Expected \(actual) > \(lowerBound). \(context)", file: file, line: line)
    }
  }

  static func throwsError<T>(
    _ expression: @autoclosure () throws -> T, _ context: String = "", file: StaticString = #fileID,
    line: UInt = #line
  ) {
    assertions += 1
    do {
      _ = try expression()
      fail("Expected an error. \(context)", file: file, line: line)
    } catch {
      // An error is the required result for this assertion.
    }
  }

  static func run(_ name: String, _ action: () throws -> Void) {
    cases += 1
    let previousFailures = failures
    do { try action() } catch {
      fail("Unexpected error in \(name): \(error)", file: #fileID, line: #line)
    }
    print("\(previousFailures == failures ? "PASS" : "FAIL") \(name)")
  }

  private static func fail(_ message: String, file: StaticString, line: UInt) {
    failures += 1
    if failures <= 50 {
      let text = "FAIL \(file):\(line): \(message)\n"
      FileHandle.standardError.write(Data(text.utf8))
    } else if failures == 51 {
      FileHandle.standardError.write(Data("Further assertion details suppressed.\n".utf8))
    }
  }

  static func finish() -> Never {
    print("\(cases) check cases · \(assertions) assertions · \(failures) failures")
    exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}

@main
enum LidGlowChecks {
  @MainActor
  static func main() {
    let effects = EffectsChecks()
    Check.run(
      "Every effect stays inside its configured peak",
      effects.testEveryEffectStaysInsideConfiguredPeak)
    Check.run("Custom pattern boundaries and looping", effects.testCustomPatternBoundariesAndLoop)
    Check.run("Invalid patterns fail closed", effects.testInvalidPatternsFailClosed)
    Check.run(
      "International Morse timing and unsupported characters",
      effects.testMorseUsesInternationalTimingAndDropsUnsupportedCharacters)
    Check.run(
      "Distinct agent patterns and attention priority",
      effects.testAgentPatternsAreDistinctAndAttentionWins)
    Check.run(
      "Unknown battery does not appear full", effects.testBatteryUnknownDoesNotPretendToBeFull)

    let activity = ActivityChecks()
    Check.run(
      "One completed session preserves another working session",
      activity.testOneCompletedSessionDoesNotHideAnotherWorkingSession)
    Check.run(
      "Missing stop events expire and completion is temporary",
      activity.testMissingStopEventsExpireAndFinishSignalIsTemporary)
    Check.run(
      "Reader rejects symlinks, oversized and invalid snapshots",
      activity.testReaderRejectsLinksOversizeAndInvalidSnapshots)
    Check.run(
      "Duplicate session files use the newest snapshot",
      activity.testDuplicateSessionFilesUseNewestSnapshot)
    RuntimeChecks.runAll()
    HardwareControlChecks.runAll()
    ProcessRunnerChecks.runAll()
    DirectoryObserverChecks.runAll()
    AgentRulesChecks.runAll()
    AgentActivityChecks.runAll()
    Check.finish()
  }
}
