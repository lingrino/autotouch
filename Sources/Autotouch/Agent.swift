import AppKit
import AutotouchCore

/// The gesture agent: a launchd LaunchAgent (KeepAlive) running the app's own executable.
/// No NSApplication, no windows, no Dock or menu bar presence: a main run loop serving
/// MultitouchSupport's frames (via `onFrame`), IOKit and workspace notifications, and a
/// few signals. Idle unless fingers are on a trackpad.
///
/// Reliability, in layers: launchd restarts the process if it ever exits or crashes; the
/// trackpads are re-acquired on every hint they may have gone stale (`Trackpads`); a
/// replaced app bundle (upgrade) restarts into the new version.
@MainActor
enum Agent {
    nonisolated static let label = "com.lingrino.autotouch.agent"
    private static var sources: [any DispatchSourceProtocol] = []
    private static var observers: [any NSObjectProtocol] = []

    static func run() -> Never {
        guard SingleInstance.acquire() else {
            Log.error("another Autotouch agent is running; exiting")
            exit(0)
        }
        Log.info("agent \(version) starting (pid \(getpid()))")
        if MTAPI.shared == nil {
            // Without the framework there is nothing to do, and exiting would only make
            // launchd start this again every 10 s. Stay, idle, and say so in the status.
            Log.error("MultitouchSupport is unavailable: no gestures until a fix")
        } else {
            Trackpads.shared.watchDevices()
            Trackpads.shared.rebuild("start")
        }
        watchSystem()
        handleSignals()
        RestartWhenReplaced.start()
        CFRunLoopRun()
        exit(0)
    }

    nonisolated static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["AutotouchRevision"] as? String ?? "dev"))"
    }

    /// Wake, display and session changes: the trackpads' device objects may not survive them.
    private static func watchSystem() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            })
        }
        on(NSWorkspace.didWakeNotification) { Trackpads.shared.rebuildSoon("woke from sleep", after: 2) }
        on(NSWorkspace.screensDidWakeNotification) { Trackpads.shared.rebuildSoon("screens woke") }
        on(NSWorkspace.sessionDidBecomeActiveNotification) {
            Trackpads.shared.sessionActive = true
            Trackpads.shared.rebuildSoon("session active again")
        }
        on(NSWorkspace.sessionDidResignActiveNotification) {
            Trackpads.shared.sessionActive = false
            Trackpads.shared.stop()
            Log.info("session inactive: stopped listening")
        }
        // Trackpad callbacks have been seen to go quiet after display changes (MiddleClick's
        // experience); called per display, before and after each change: coalesced.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Trackpads.shared.rebuildSoon("displays reconfigured") } }
        }, nil)
    }

    /// SIGINFO logs a status line (`make status`); SIGUSR1 / SIGUSR2 perform the left / right
    /// swipe's action, to check the actions from the agent itself without a trackpad.
    private static func handleSignals() {
        func on(_ sig: Int32, _ body: @escaping @MainActor () -> Void) {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { body() } }
            s.resume()
            sources.append(s)
        }
        on(SIGINFO) { Log.info(status) }
        on(SIGUSR1) { Actions.perform(.left, from: "SIGUSR1") }
        on(SIGUSR2) { Actions.perform(.right, from: "SIGUSR2") }
    }

    static var status: String {
        let (frames, last) = frameState.withLock { ($0.frames, $0.lastFrame) }
        let age = last == 0 ? "never" : String(format: "%.0fs ago", Double(nowNanos() - last) / 1e9)
        let t = Trackpads.shared
        let swipes = Actions.performed
        return "status: version \(version), trackpads \(t.count) (\(t.running) running), rebuilds \(t.rebuilds), "
            + "frames \(frames) (last \(age)), swipes left \(swipes[.left, default: 0]) right \(swipes[.right, default: 0]), "
            + String(format: "memory %.1f MB, cpu %.2f s", Diagnostics.footprintMB(), Diagnostics.cpuSeconds())
    }
}

/// One agent per user: two would both act on every swipe. The lock lives as long as the
/// process; a restart overlapping the old process's exit waits for it.
enum SingleInstance {
    static func acquire() -> Bool {
        let path = NSTemporaryDirectory() + "com.lingrino.autotouch.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }   // can't lock: run anyway rather than not at all
        for _ in 0..<60 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            usleep(50_000)
        }
        close(fd)
        return false
    }
}

/// `brew upgrade` replaces /Applications/Autotouch.app under the running agent, and `make
/// install` rewrites it in place. Watch the folder holding the bundle; once things settle,
/// if the executable is a different file, exit: launchd starts the new one (KeepAlive). The
/// new executable must be there first, so launchd never finds the path empty mid-swap.
@MainActor
enum RestartWhenReplaced {
    private static var launched: [Int]?
    private static var generation = 0
    private static var stream: FSEventStreamRef?

    static func start() {
        guard let exe = Bundle.main.executablePath, let id = fileID(exe) else { return }
        launched = id
        let folder = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            MainActor.assumeIsolated { RestartWhenReplaced.mayHaveChanged() }
        }
        guard let s = FSEventStreamCreate(nil, callback, nil, [folder] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private static func mayHaveChanged() {
        generation &+= 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                guard g == generation, let exe = Bundle.main.executablePath,
                      let now = fileID(exe), now != launched else { return }
                Log.info("Autotouch.app was replaced: restarting into the new version")
                exit(0)
            }
        }
    }

    /// A file's identity (device, inode, modification time): a replaced file is a different one.
    private static func fileID(_ path: String) -> [Int]? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return [Int(st.st_dev), Int(st.st_ino), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
    }
}
