import AppKit
import IOKit.ps
import LidGlowCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  @Published var mode: LightMode = .breathe {
    didSet {
      phaseStart = Date()
      if mode == .battery && servicesEnabled { readBattery() }
      save()
    }
  }
  @Published var brightness: Double = 0.7 { didSet { save() } }
  @Published var speed: Double = 1.5 { didSet { save() } }
  @Published var minimum: Double = 0.06 { didSet { save() } }
  @Published var enabled = true { didSet { save() } }
  // Frame changes belong to a small preview subtree, not the whole settings view.
  let preview = PreviewState()
  var output: Double { preview.level }
  @Published var hardwareAvailable = false
  @Published var isControlling = false
  @Published var hardwareStatus = "Checking logo hardware…"
  @Published var lightingNotice: String?
  @Published var sessions: [AgentSession] = []
  @Published var activity: [ActivityEntry] = []
  @Published var morseText = "HELLO" {
    didSet {
      let bounded = InputLimits.text(morseText, characters: 160, utf8Bytes: 1024)
      if bounded != morseText {
        morseText = bounded
        return
      }
      morseSteps = Patterns.morse(morseText)
      phaseStart = Date()
      save()
    }
  }
  @Published var customPattern = "100:0.3, 0:0.2, 100:0.3, 0:1.2" {
    didSet {
      let bounded = InputLimits.text(customPattern, characters: 2048, utf8Bytes: 2048)
      if bounded != customPattern {
        customPattern = bounded
        return
      }
      parsePattern()
      phaseStart = Date()
      save()
    }
  }
  @Published var agentPreferences: AgentPreferences = .default {
    didSet {
      let normalized = agentPreferences.normalized()
      if normalized != agentPreferences {
        agentPreferences = normalized
        return
      }
      agentRenderer = AgentSignalRenderer(preferences: agentPreferences)
      phaseStart = Date()
      if !loading {
        updateSessions()
        save()
      }
    }
  }
  @Published var agentCaption = "No active agent sessions"
  @Published var resolvedAgentState: AgentState = .idle
  @Published var showWelcome = false
  @Published var patternError: String?
  @Published var focusMinutes: Double = 25 {
    didSet {
      if !focusRunning { resetFocus() }
      save()
    }
  }
  @Published var focusRemaining: TimeInterval = 1500
  @Published var focusRunning = false
  @Published var batteryLevel: Double?
  @Published var isCharging = false
  @Published var dimOnLowPower = true { didSet { save() } }
  @Published var claudeInstalled = false
  @Published var codexInstalled = false
  @Published var integrationMessage: String?
  @Published var installationBusy = false
  @Published private(set) var startAtLogin = true
  @Published private(set) var loginItemMessage: String?

  private let hardware: LogoHardware
  private let previewOnly: Bool
  private let settings: SettingsStore
  private let shouldPersistPreferences: Bool
  private let servicesEnabled: Bool
  private let loginItem: LoginItemManaging?
  private var animationTimer: Timer?
  private var frameInterval: Double?
  private var focusTimer: Timer?
  private var focusTimerInterval: Double?
  private var batteryTimer: Timer?
  private var expiryTimer: Timer?
  private var saveTimer: Timer?
  private var eventObserver: DirectoryObserver?
  private let helperCancellation = HelperCancellation()
  private var integrationTask: Task<Void, Never>?
  private var statusTask: Task<Void, Never>?
  private var statusGeneration = 0
  private var visibleSurfaces: Set<String> = []
  private var phaseStart = Date()
  private var snapshots: [AgentSnapshot] = []
  private var renderSessions: [AgentSignalSession] = []
  private var agentRenderer = AgentSignalRenderer(preferences: .default)
  private var agentAnimated = false
  private var seenEvents: [String: Double] = [:]
  private var demos: [AgentSession] = []
  private var morseSteps = Patterns.morse("HELLO")
  private var customSteps: [PatternStep] = []
  private var focus = FocusClock()
  private var observers: [NSObjectProtocol] = []
  private var suspensionReasons: Set<String> = []
  private var loading = true
  private var stopped = false
  private var lastAgentIdentity = ""
  private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  @Published private var controlsWanted = true
  private var didApplyStartupSettings = false
  private var previewVisible: Bool { !visibleSurfaces.isEmpty }

  var aggregateAgentState: AgentState {
    resolvedAgentState
  }
  var focusProgress: Double { focus.progress(at: Date()) }
  var focusPaused: Bool {
    !focus.isRunning && focus.pausedRemaining > 0 && focus.pausedRemaining < focus.duration
  }
  var focusCompleted: Bool { focus.completedAt != nil }
  var batteryDescription: String {
    guard let level = batteryLevel else { return "Battery status unavailable" }
    return "\(Int((level * 100).rounded()))% · \(isCharging ? "Connected to power" : "On battery")"
  }

  init(previewOnly: Bool? = nil, settings: SettingsStore? = nil, startServices: Bool = true,
       loginItem: LoginItemManaging? = nil) {
    let preview = previewOnly ?? CommandLine.arguments.contains("--preview")
    self.previewOnly = preview
    self.settings = settings ?? UserDefaults.standard
    shouldPersistPreferences = settings != nil || !preview
    servicesEnabled = startServices
    self.loginItem = loginItem ?? (startServices && !preview ? SystemLoginItem() : nil)
    hardware = LogoHardware(
      previewOnly: preview,
      recoveryURL: AppPaths.dataDirectory.appendingPathComponent("hardware-recovery.json"))
    load()
    loading = false
    showWelcome = false
    parsePattern()
    hardwareAvailable = hardware.isAvailable
    hardwareStatus = hardware.status
    hardware.onStateChange = { [weak self] in self?.refreshHardware() }
    if startServices {
      readBattery()
      pollEvents()
      eventObserver = DirectoryObserver(directory: AppPaths.events) { [weak self] in
        self?.pollEvents()
      }
      observeLifecycle()
      updateClocks()
      statusTask = Task { await refreshHookStatus() }
    }
  }

  func setSurfaceVisible(_ surface: String, _ visible: Bool) {
    let wasVisible = previewVisible
    if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
    guard previewVisible != wasVisible else { return }
    if previewVisible {
      publishFocus()
      render()
    }
    updateClocks()
  }

  func activateSavedLightingIfNeeded() {
    guard !didApplyStartupSettings else { return }
    didApplyStartupSettings = true
    if !previewOnly { configureLoginItemIfNeeded() }
    guard !previewOnly, controlsWanted,
      !hardware.hasPendingRecovery
    else { return }
    connectHardware()
  }
  var isLidGlowEnabled: Bool { controlsWanted && !needsLightingReset }
  func setLidGlowEnabled(_ on: Bool) {
    if on {
      if hardwareAvailable { setLogoPower(true) }
      else {
        controlsWanted = true
        enabled = true
        save()
      }
    } else { useSystemLighting() }
  }

  func configureLoginItemIfNeeded() {
    guard loginItem != nil else { return }
    if !settings.bool(forKey: "loginItemConfigured") {
      setStartAtLogin(true)
      settings.set(true, forKey: "loginItemConfigured")
    } else { refreshLoginItem() }
  }
  func setStartAtLogin(_ on: Bool) {
    guard let loginItem else { return }
    do {
      try loginItem.setEnabled(on)
      refreshLoginItem()
    } catch {
      startAtLogin = loginItem.state != .off
      loginItemMessage = "Could not update Start at login: \(error.localizedDescription)"
    }
    settings.set(true, forKey: "loginItemConfigured")
  }
  func openLoginItemSettings() { loginItem?.openSettings() }
  private func refreshLoginItem() {
    guard let loginItem else { return }
    startAtLogin = loginItem.state != .off
    loginItemMessage = loginItem.state == .needsApproval
      ? "Allow LidGlow in System Settings → Login Items to start automatically." : nil
  }
  func completeWelcome(startLighting: Bool) {
    showWelcome = false
    if shouldPersistPreferences { settings.set(true, forKey: "hasSeenWelcome") }
    if startLighting && hardwareAvailable { setLogoPower(enabled) } else { useSystemLighting() }
  }
  func setLogoPower(_ on: Bool) {
    guard !hardware.isRestoring, !hardware.hasPendingRecovery || hardware.isControlling else {
      return
    }
    guard hardwareAvailable else {
      enabled = on
      controlsWanted = false
      save()
      return
    }
    controlsWanted = true
    enabled = on
    if !isControlling { connectHardware() }
    runtimeChanged()
    save()
  }
  func turnOnLight() { setLogoPower(true) }
  func useSystemLighting() {
    controlsWanted = false
    releaseHardware()
    save()
  }
  var isUsingSystemLighting: Bool {
    !isControlling && !hardware.isSuspended && !hardware.isRestoring && !hardware.hasPendingRecovery
  }
  var needsLightingReset: Bool { hardware.hasPendingRecovery }

  func connectHardware() {
    lightingNotice = nil
    do {
      try hardware.connect()
      isControlling = hardware.isControlling
      if isControlling && !suspensionReasons.isEmpty { hardware.suspend() }
    } catch {
      hardwareStatus = error.localizedDescription
      lightingNotice = error.localizedDescription
      isControlling = false
    }
    refreshHardware()
    runtimeChanged()
  }
  func releaseHardware() {
    lightingNotice = nil
    isControlling = false
    hardware.restore()
    refreshHardware()
    updateClocks()
  }
  var isRestoringHardware: Bool { hardware.isRestoring }
  var hasPendingShutdownWork: Bool {
    hardware.isRestoring || helperCancellation.activeWorkCount > 0
  }
  var canReleaseHardware: Bool {
    isControlling || hardware.isRestoring || hardware.hasPendingRecovery
  }
  var hardwareDiagnostics: String { hardware.diagnosticSummary }
  private func refreshHardware() {
    if hardwareStatus != hardware.status { hardwareStatus = hardware.status }
    if isControlling && !hardware.isControlling && !hardware.isSuspended
      && suspensionReasons.isEmpty
    {
      isControlling = false
    }
    updateClocks()
  }

  func demoAgent(_ source: String, state: AgentState) {
    mode = .agents
    demos.removeAll { $0.source == source }
    demos.append(
      AgentSession(
        id: "demo-" + source, source: source, state: state, timestamp: Date(), isDemo: true))
    record("\(source.capitalized) · \(state.title) · Demo", state: state)
    updateSessions()
  }
  func clearDemo() {
    demos.removeAll()
    updateSessions()
  }

  func startFocus() {
    mode = .focus
    focus.start(at: Date())
    publishFocus()
    runtimeChanged()
    scheduleExpiry()
  }
  func pauseFocus() {
    focus.pause(at: Date())
    publishFocus()
    runtimeChanged()
  }
  func resetFocus() {
    focus.configure(minutes: focusMinutes)
    publishFocus()
    if !loading {
      runtimeChanged()
      scheduleExpiry()
    }
  }
  private func publishFocus() {
    let remaining = focus.remaining(at: Date())
    if focusRemaining != remaining { focusRemaining = remaining }
    if focusRunning != focus.isRunning { focusRunning = focus.isRunning }
  }
  private func advanceFocus() {
    if focus.advance(to: Date()) {
      phaseStart = Date()
      record("Focus session finished", state: .complete)
      publishFocus()
      scheduleExpiry()
      updateClocks()
    } else if previewVisible && mode == .focus {
      publishFocus()
    }
    render()
    updateClocks()
  }

  func installHooks(_ source: String) { mutateHooks("install", source: source) }
  func removeHooks(_ source: String) { mutateHooks("uninstall", source: source) }
  private func mutateHooks(_ action: String, source: String) {
    guard servicesEnabled, !installationBusy, ["claude", "codex"].contains(source) else { return }
    statusTask?.cancel()
    statusGeneration += 1
    installationBusy = true
    integrationMessage = nil
    integrationTask = Task {
      var args = [action, "--agent", source]
      if action == "install", let native = AppPaths.signal {
        args += ["--native-helper", native.path]
      }
      let result = await runHelper(args)
      guard !stopped, !Task.isCancelled else { return }
      integrationMessage = result.message
      await refreshHookStatus()
      installationBusy = false
    }
  }
  func openHooksHelp() {
    if let url = Bundle.main.url(forResource: "HOOKS", withExtension: "md") {
      NSWorkspace.shared.open(url)
    }
  }
  func copyAutomationCommand() {
    guard let native = AppPaths.signal else {
      integrationMessage = "Native activity helper is missing. Rebuild the app bundle."
      return
    }
    let quoted = "'" + native.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      "\(quoted) emit --source custom --state complete --session build", forType: .string)
    integrationMessage =
      "Copied a local completion signal command. Select Agent signal to display it; use working, attention, complete, error, or idle."
  }

  func handleURL(_ url: URL) {
    guard url.scheme?.lowercased() == "lidglow", url.absoluteString.count <= 4096 else { return }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard items.count <= 32 else { return }
    let query = Dictionary(
      items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    switch url.host?.lowercased() {
    case "mode":
      if let name = query["name"], let value = LightMode(rawValue: name) { mode = value }
      if let raw = query["brightness"], let value = Double(raw), value.isFinite {
        brightness = min(1, max(0, value))
      }
    case "off": setLidGlowEnabled(false)
    case "on": setLidGlowEnabled(true)
    case "focus":
      if let raw = query["minutes"], let value = Double(raw), value.isFinite {
        focusMinutes = min(180, max(1, value))
      }
      resetFocus()
      startFocus()
    default: break
    }
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    helperCancellation.cancel()
    integrationTask?.cancel()
    statusTask?.cancel()
    [animationTimer, focusTimer, batteryTimer, expiryTimer, saveTimer].forEach { $0?.invalidate() }
    eventObserver?.stop()
    hardware.restore()
    persistSettings()
    for observer in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      DistributedNotificationCenter.default().removeObserver(observer)
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
  }

  private func runtimeChanged() {
    guard !loading, !stopped else { return }
    render()
    updateClocks()
  }
  private func render() {
    guard !loading, !stopped else { return }
    let now = Date()
    var input = EffectInput()
    input.mode = mode
    input.elapsed = now.timeIntervalSince(phaseStart)
    input.brightness = brightness * (dimOnLowPower && lowPower ? 0.4 : 1)
    input.minimum = minimum
    input.speed = speed
    input.focusProgress = focus.progress(at: now)
    input.focusFinished = focus.completedAt.map { now.timeIntervalSince($0) < 8 } ?? false
    input.batteryLevel = batteryLevel
    input.isCharging = isCharging
    input.morse = morseSteps
    input.custom = customSteps
    let level: Double
    if mode == .agents {
      let signal = agentRenderer.render(
        sessions: renderSessions, now: now, elapsed: input.elapsed,
        brightness: input.brightness, minimum: minimum, speed: speed)
      level = enabled ? signal.level : 0
      if previewVisible && agentCaption != signal.caption { agentCaption = signal.caption }
    } else {
      level = enabled ? EffectEngine.value(input) : 0
    }
    if previewVisible && abs(preview.level - level) >= 0.001 { preview.level = level }
    if isControlling && suspensionReasons.isEmpty {
      if hardware.isSuspended { hardware.resume() }
      hardware.setBrightness(level)
    }
  }

  private func updateClocks() {
    guard servicesEnabled, !loading, !stopped else { return }
    let interval = RuntimePolicy.frameInterval(
      mode: mode, enabled: enabled, connected: isControlling,
      visible: previewVisible, suspended: !suspensionReasons.isEmpty, agent: aggregateAgentState,
      charging: isCharging,
      focusFinished: focus.completedAt.map { Date().timeIntervalSince($0) < 8 } ?? false,
      lowPower: lowPower,
      agentAnimated: agentAnimated, brightness: brightness)
    if interval != frameInterval {
      animationTimer?.invalidate()
      animationTimer = nil
      frameInterval = interval
      if let interval {
        animationTimer = repeating(interval, tolerance: interval * 0.15) { [weak self] in
          self?.render()
        }
      }
    }
    let needsProgress =
      mode == .focus && (previewVisible || (isControlling && enabled && brightness > 0))
    let desiredFocusInterval: Double? =
      focus.isRunning && suspensionReasons.isEmpty
      ? (needsProgress ? 1 : max(0.01, focus.remaining(at: Date()))) : nil
    // Keep the one-shot deadline stable while other settings change.
    if (desiredFocusInterval == nil) != (focusTimerInterval == nil)
      || (desiredFocusInterval == 1) != (focusTimerInterval == 1)
      || (desiredFocusInterval != nil && focusTimer == nil)
    {
      focusTimer?.invalidate()
      focusTimer = nil
      focusTimerInterval = desiredFocusInterval
      if let interval = desiredFocusInterval {
        if needsProgress {
          focusTimer = repeating(1, tolerance: 0.15) { [weak self] in self?.advanceFocus() }
        } else {
          let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.focusTimer = nil
              self?.advanceFocus()
            }
          }
          timer.tolerance = min(0.15, interval * 0.01)
          focusTimer = timer
          RunLoop.main.add(timer, forMode: .common)
        }
      }
    }
    let needsBattery =
      mode == .battery && (previewVisible || isControlling) && suspensionReasons.isEmpty
    if needsBattery && batteryTimer == nil {
      batteryTimer = repeating(60, tolerance: 10) { [weak self] in
        self?.readBattery()
        self?.runtimeChanged()
      }
    } else if !needsBattery {
      batteryTimer?.invalidate()
      batteryTimer = nil
    }
  }
  private func repeating(
    _ interval: Double, tolerance: Double, action: @escaping @MainActor () -> Void
  ) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { action() }
    }
    timer.tolerance = tolerance
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func pollEvents() {
    guard !stopped else { return }
    let now = Date()
    snapshots = ActivityReader.snapshots(in: AppPaths.events, now: now)
    for snapshot in snapshots.reversed() where seenEvents[snapshot.id] != snapshot.timestamp {
      if now.timeIntervalSince1970 - snapshot.timestamp < 60 {
        record(
          "\(snapshot.source.capitalized) · \(snapshot.state.title)", state: snapshot.state,
          time: Date(timeIntervalSince1970: snapshot.timestamp))
      }
      seenEvents[snapshot.id] = snapshot.timestamp
    }
    if seenEvents.count > 512 {
      seenEvents = Dictionary(snapshots.map { ($0.id, $0.timestamp) }, uniquingKeysWith: max)
    }
    updateSessions()
  }
  private func updateSessions() {
    let now = Date()
    demos.removeAll { now.timeIntervalSince($0.timestamp) >= 60 }
    snapshots.removeAll { now.timeIntervalSince1970 - $0.timestamp >= 86400 }
    var current = AgentActivity.sessions(from: snapshots, preferences: agentPreferences, now: now)
      .map {
        AgentSession(
          id: $0.id, source: $0.source, state: $0.state, timestamp: $0.timestamp, isDemo: false)
      }
    current.append(
      contentsOf: demos.map {
        var value = $0
        let duration = agentPreferences.rules(for: value.source).completionSeconds
        if value.state == .complete && duration > 0
          && now.timeIntervalSince(value.timestamp) >= duration
        {
          value.state = .idle
        }
        if value.state == .error && now.timeIntervalSince(value.timestamp) >= 30 {
          value.state = .idle
        }
        return value
      })
    current.sort {
      $0.state.priority == $1.state.priority
        ? $0.timestamp > $1.timestamp : $0.state.priority > $1.state.priority
    }
    let limited = Array(current.prefix(32))
    if sessions != limited { sessions = limited }
    renderSessions = current.prefix(256).map {
      AgentSignalSession(id: $0.id, source: $0.source, state: $0.state, timestamp: $0.timestamp)
    }
    let summary = agentRenderer.render(
      sessions: renderSessions, now: now, elapsed: 0, brightness: brightness, minimum: minimum,
      speed: speed)
    agentAnimated = summary.isAnimated
    if resolvedAgentState != summary.state { resolvedAgentState = summary.state }
    if agentCaption != summary.caption { agentCaption = summary.caption }
    let selected = current.first(where: { $0.source == summary.source && $0.state == summary.state }
    )
    let identity =
      "\(summary.source):\(summary.state.rawValue):\(summary.activeCount)"
      + ([AgentState.attention, .complete, .error].contains(summary.state)
        ? ":\(selected?.timestamp.timeIntervalSince1970 ?? 0)" : "")
    if identity != lastAgentIdentity && mode == .agents { phaseStart = now }
    lastAgentIdentity = identity
    runtimeChanged()
    scheduleExpiry()
  }
  private func scheduleExpiry() {
    guard servicesEnabled else { return }
    expiryTimer?.invalidate()
    expiryTimer = nil
    let now = Date()
    var dates: [Date] = []
    for snapshot in snapshots {
      let start = Date(timeIntervalSince1970: snapshot.timestamp)
      dates.append(start.addingTimeInterval(86400))
      switch snapshot.state {
      case .working, .attention: dates.append(start.addingTimeInterval(1800))
      case .complete:
        let duration = agentPreferences.rules(for: snapshot.source).completionSeconds
        if duration > 0 { dates.append(start.addingTimeInterval(duration)) }
      case .error: dates.append(start.addingTimeInterval(30))
      default: break
      }
    }
    for demo in demos {
      dates.append(demo.timestamp.addingTimeInterval(60))
      if demo.state == .complete {
        let duration = agentPreferences.rules(for: demo.source).completionSeconds
        if duration > 0 { dates.append(demo.timestamp.addingTimeInterval(duration)) }
      }
      if demo.state == .error { dates.append(demo.timestamp.addingTimeInterval(30)) }
    }
    if let completed = focus.completedAt { dates.append(completed.addingTimeInterval(8)) }
    guard let next = dates.filter({ $0.timeIntervalSince(now) > 0 }).min() else { return }
    let timer = Timer(timeInterval: max(0.01, next.timeIntervalSince(now) + 0.01), repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.updateSessions() }
    }
    timer.tolerance = 0.05
    expiryTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func record(_ title: String, state: AgentState, time: Date = Date()) {
    if let last = activity.first, last.title == title, abs(time.timeIntervalSince(last.time)) < 2 {
      return
    }
    activity.insert(ActivityEntry(title: title, time: time, state: state), at: 0)
    activity = Array(activity.prefix(30))
  }
  private func parsePattern() {
    do {
      customSteps = try Patterns.parse(customPattern)
      patternError = nil
    } catch {
      customSteps = []
      patternError = error.localizedDescription
    }
  }
  private func readBattery() {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else {
      batteryLevel = nil
      return
    }
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any],
        let current = description[kIOPSCurrentCapacityKey] as? Double,
        let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0
      else { continue }
      let level = min(1, max(0, current / maximum))
      let charging = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
      if batteryLevel != level { batteryLevel = level }
      if isCharging != charging { isCharging = charging }
      return
    }
    if batteryLevel != nil { batteryLevel = nil }
  }
  private func observeLifecycle() {
    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLoginItem() }
    })
    for (name, reason, suspended) in [
      (NSWorkspace.screensDidSleepNotification, "display", true),
      (NSWorkspace.screensDidWakeNotification, "display", false),
      (NSWorkspace.willSleepNotification, "system", true),
      (NSWorkspace.didWakeNotification, "system", false),
    ] {
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in
          MainActor.assumeIsolated { self?.setSuspended(suspended, reason: reason) }
        })
    }
    for (name, suspended) in [
      ("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false),
    ] {
      observers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: Notification.Name(name), object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.setSuspended(suspended, reason: "lock") }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
          self?.runtimeChanged()
        }
      })
  }
  private func setSuspended(_ suspended: Bool, reason: String) {
    if suspended {
      suspensionReasons.insert(reason)
      hardware.suspend()
    } else {
      suspensionReasons.remove(reason)
      if suspensionReasons.isEmpty {
        if isControlling { hardware.resume() }
        advanceFocus()
        pollEvents()
        readBattery()
      }
    }
    refreshHardware()
    runtimeChanged()
  }

  private func refreshHookStatus() async {
    guard !stopped else { return }
    statusGeneration += 1
    let generation = statusGeneration
    let claude = await runHelper(["status", "--agent", "claude"])
    guard !stopped, !Task.isCancelled, generation == statusGeneration else { return }
    claudeInstalled = claude.installed
    let codex = await runHelper(["status", "--agent", "codex"])
    guard !stopped, !Task.isCancelled, generation == statusGeneration else { return }
    codexInstalled = codex.installed
  }
  private struct HelperResult: Sendable {
    var installed: Bool
    var message: String
  }
  private func runHelper(_ arguments: [String]) async -> HelperResult {
    guard let helper = AppPaths.helper else {
      return HelperResult(
        installed: false, message: "Hook installer is missing. Rebuild the app bundle.")
    }
    let cancellation = helperCancellation
    return await Task.detached {
      guard cancellation.begin() else {
        return HelperResult(installed: false, message: "Integration operation cancelled.")
      }
      defer { cancellation.end() }
      guard let python = AppPaths.python else {
        return HelperResult(
          installed: false,
          message:
            "Agent setup requires Python 3 from Xcode Command Line Tools. Lighting and the native automation helper work independently."
        )
      }
      let result = ProcessRunner.run(
        executable: python, arguments: [helper.path] + arguments,
        timeout: 10, maxOutputBytes: 65536, cancelled: { cancellation.isCancelled })
      if result.cancelled {
        return HelperResult(installed: false, message: "Integration operation cancelled.")
      }
      if result.timedOut {
        return HelperResult(
          installed: false,
          message: "Integration operation timed out. No further installer processes were started.")
      }
      if let error = result.error { return HelperResult(installed: false, message: error) }
      if let value = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] {
        return HelperResult(
          installed: value["installed"] as? Bool ?? false,
          message: value["message"] as? String ?? "Integration updated.")
      }
      return HelperResult(installed: false, message: "Integration did not return a valid response.")
    }.value
  }

  private func save() {
    guard !loading, !stopped else { return }
    runtimeChanged()
    guard shouldPersistPreferences else { return }
    if !servicesEnabled {
      persistSettings()
      return
    }
    saveTimer?.invalidate()
    let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.persistSettings() }
    }
    timer.tolerance = 0.1
    saveTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func persistSettings() {
    guard !loading, shouldPersistPreferences else { return }
    let defaults = settings
    for (key, value) in [
      "mode": mode.rawValue, "brightness": brightness, "speed": speed, "minimum": minimum,
      "enabled": enabled, "morseText": morseText, "customPattern": customPattern,
      "focusMinutes": focusMinutes, "dimOnLowPower": dimOnLowPower,
      "controlsWanted": controlsWanted, "lidGlowEnabled": controlsWanted,
      "breathingSpeedDefaultV2": true,
    ] as [String: Any] { defaults.set(value, forKey: key) }
    if let data = try? JSONEncoder().encode(agentPreferences) {
      defaults.set(data, forKey: "agentPreferences")
    }
  }
  private func load() {
    guard shouldPersistPreferences else { return }
    let defaults = settings
    func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
      guard defaults.object(forKey: key) != nil else { return fallback }
      let value = defaults.double(forKey: key)
      return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
    if let name = defaults.string(forKey: "mode"), let value = LightMode(rawValue: name) {
      mode = value
    }
    brightness = number("brightness", fallback: 0.7, range: 0...1)
    speed = number("speed", fallback: 1.5, range: 0.5...3)
    if speed == 1 && !defaults.bool(forKey: "breathingSpeedDefaultV2") {
      speed = 1.5
    }
    minimum = number("minimum", fallback: 0.06, range: 0...1)
    focusMinutes = number("focusMinutes", fallback: 25, range: 1...180)
    if defaults.object(forKey: "enabled") != nil { enabled = defaults.bool(forKey: "enabled") }
    if let text = defaults.string(forKey: "morseText") { morseText = String(text.prefix(160)) }
    if let text = defaults.string(forKey: "customPattern") {
      customPattern = String(text.prefix(2048))
    }
    if defaults.object(forKey: "dimOnLowPower") != nil {
      dimOnLowPower = defaults.bool(forKey: "dimOnLowPower")
    }
    // The new switch controls LidGlow versus Mac automatic lighting.
    // Adopt On once when migrating; later explicit Off choices are retained.
    controlsWanted = defaults.object(forKey: "lidGlowEnabled") == nil
      ? true : defaults.bool(forKey: "lidGlowEnabled")
    if controlsWanted { enabled = true }
    if let data = defaults.data(forKey: "agentPreferences"), data.count <= 65536,
      let preferences = try? JSONDecoder().decode(AgentPreferences.self, from: data)
    {
      agentPreferences = preferences.normalized()
    }
    resetFocus()
  }
}

private final class HelperCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  private var active = 0
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  var activeWorkCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return active
  }
  func begin() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !value else { return false }
    active += 1
    return true
  }
  func end() {
    lock.lock()
    active = max(0, active - 1)
    lock.unlock()
  }
  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
}
