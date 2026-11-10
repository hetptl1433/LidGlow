import Darwin
import Foundation

/// Kernel notifications replace continual directory polling. Atomic file replacement
/// changes directory entries; bursts are coalesced into a single read.
@MainActor
public final class DirectoryObserver {
  private let directory: URL
  private let changed: () -> Void
  private var source: DispatchSourceFileSystemObject?
  private var parentSource: DispatchSourceFileSystemObject?
  private var debounce: Timer?
  private var retry: Timer?
  private var stopped = false

  public init(directory: URL, changed: @escaping () -> Void) {
    self.directory = directory
    self.changed = changed
    arm()
  }
  public func stop() {
    stopped = true
    source?.cancel()
    source = nil
    parentSource?.cancel()
    parentSource = nil
    debounce?.invalidate()
    debounce = nil
    retry?.invalidate()
    retry = nil
  }
  private func arm() {
    guard !stopped else { return }
    retry?.invalidate()
    retry = nil
    source?.cancel()
    parentSource?.cancel()
    source = nil
    parentSource = nil
    do {
      guard Self.hasNoSymlinkComponents(directory) else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      source = watch(directory, events: [.write, .rename, .delete, .revoke], isParent: false)
      parentSource = watch(
        directory.deletingLastPathComponent(), events: [.write, .rename, .delete, .revoke],
        isParent: true)
    } catch {}
    if source == nil { scheduleRetry() }
  }
  private func watch(_ path: URL, events: DispatchSource.FileSystemEvent, isParent: Bool)
    -> DispatchSourceFileSystemObject?
  {
    let fd = open(path.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    let observation = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: events, queue: .main)
    observation.setCancelHandler { close(fd) }
    observation.setEventHandler { [weak self, weak observation] in
      MainActor.assumeIsolated {
        guard let self, let observation, !self.stopped else { return }
        guard isParent ? self.parentSource === observation : self.source === observation else {
          return
        }
        let flags = observation.data
        if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
          self.source?.cancel()
          self.source = nil
          // Preserve the parent watch when only events/ is replaced.
          // A newly written completion must not wait past its 8s lease.
          if isParent {
            self.parentSource?.cancel()
            self.parentSource = nil
          }
          self.scheduleRetry(after: 0.1)
        } else if isParent && self.source == nil {
          self.arm()
        }
        self.notify()
      }
    }
    observation.resume()
    return observation
  }
  private func notify() {
    guard debounce == nil else { return }
    let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.stopped else { return }
        self.debounce = nil
        self.changed()
      }
    }
    timer.tolerance = 0.025
    debounce = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func scheduleRetry(after delay: Double = 30) {
    guard retry == nil, !stopped else { return }
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.stopped else { return }
        self.retry = nil
        self.arm()
        self.changed()
      }
    }
    timer.tolerance = min(5, delay * 0.15)
    retry = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private static func hasNoSymlinkComponents(_ url: URL) -> Bool {
    guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".")
    else { return false }
    var path = ""
    for component in url.pathComponents.dropFirst() {
      path += "/" + component
      var metadata = stat()
      if lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK { return false }
    }
    return true
  }
}
