import AppKit
import AutotouchCore

/// What the two swipes do. Neither needs a privacy grant: opening an app and hiding one are
/// LaunchServices requests, and window owners and bounds (not titles) are readable without
/// Screen Recording.
@MainActor
enum Actions {
    static let chrome = "com.google.Chrome"
    private(set) static var performed: [Swipe: Int] = [:]
    private static var sequence = 0

    static func perform(_ swipe: Swipe, from source: String) {
        // Fingers on the trackpad while the screen is locked, or while another user's session
        // is on screen, aren't meant for this session's apps.
        guard Session.onConsole, !Session.screenLocked else {
            Log.info("\(swipe) swipe ignored: screen locked or session not on console")
            return
        }
        performed[swipe, default: 0] += 1
        sequence += 1
        switch swipe {
        case .left: launchChrome(source)
        case .right: hideAppUnderCursor(source)
        }
    }

    /// Opens Chrome: launches it, or brings it forward (unhiding it) when it is running, the
    /// same as clicking it in the Dock.
    static func launchChrome(_ source: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chrome) else {
            Log.error("left swipe (\(source)): Chrome (\(chrome)) isn't installed")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { Log.error("left swipe (\(source)): opening Chrome failed: \(error)") }
        }
        Log.info("left swipe (\(source)): open Chrome")
    }

    /// Hides the app owning the window under the pointer (⌘H for that app); over no window,
    /// the frontmost app.
    ///
    /// macOS ignores a hide request from another process for the last app with windows on
    /// screen (it has no app to make active instead; seen on 27.2). ⌘H would hand
    /// activation to Finder, the desktop: do that first in that case. When the window list
    /// misjudges it (windows on another Space), a check shortly after does the same.
    /// When Finder itself is that last app there is no app to hand activation to: it stays
    /// (⌘H in Finder works, but sending it needs Accessibility). Each hide goes both ways
    /// macOS has (`requestHide`).
    static func hideAppUnderCursor(_ source: String) {
        let windows = normalWindows()
        guard let app = appUnderCursor(windows) ?? NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else {
            Log.info("right swipe (\(source)): no app to hide")
            return
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        let pid = app.processIdentifier
        let isFinder = app.bundleIdentifier == finder
        let last = !windows.contains { $0.pid != pid }
        if last && isFinder {
            Log.info("right swipe (\(source)): Finder is the last app with windows on screen: macOS won't hide it from outside")
            return
        }
        if last { activateFinder() }
        requestHide(app)
        Log.info("right swipe (\(source)): hide \(name)" + (last ? " (last app on screen: Finder first)" : ""))
        // Another swipe since may have shown the app again on purpose.
        let seq = sequence
        if !isFinder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    guard seq == sequence, let a = NSRunningApplication(processIdentifier: pid), !a.isHidden else { return }
                    activateFinder()
                    requestHide(a)
                    Log.info("right swipe (\(source)): \(name) was still showing: hid it again, Finder first")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if seq == sequence, let a = NSRunningApplication(processIdentifier: pid), !a.isHidden {
                    Log.error("right swipe (\(source)): \(name) is still not hidden")
                }
            }
        }
    }

    /// Asks `app` to hide both ways macOS has; together they are harmless (one hide).
    /// LaunchServices' request (`hide()`) never reaches an app that was launched in the
    /// background and opened later: Spotlight launches Things that way to query its App
    /// Intents, and Calculator launched the same way ignores it too (seen on 27.2.1). The
    /// window server's request (SkyLight) reaches those.
    static func requestHide(_ app: NSRunningApplication) {
        // hide() returns false even when it works (macOS 27.2, from a process that isn't an
        // NSApplication): check what happened instead.
        _ = app.hide()
        SkyLight.shared?.hide(app.processIdentifier)
    }

    static let finder = "com.apple.finder"

    /// Makes Finder (the desktop) the active app. Works from a background process; opens no
    /// window.
    static func activateFinder() {
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: finder).first?.activate()
    }

    /// On-screen, normal-level (layer 0), visible windows, front to back, other than the
    /// desktop's: owner and bounds only (no Screen Recording needed for those).
    static func normalWindows() -> [(pid: pid_t, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        return list.compactMap { w in
            guard w[kCGWindowLayer as String] as? Int == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 1, rect.height > 1,
                  let pid = (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != me else { return nil }
            return (pid, rect)
        }
    }

    /// The app owning the frontmost normal window under the pointer (skipping windows whose
    /// owner isn't an app).
    static func appUnderCursor(_ windows: [(pid: pid_t, bounds: CGRect)]) -> NSRunningApplication? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        for w in windows where w.bounds.contains(point) {
            if let app = NSRunningApplication(processIdentifier: w.pid) { return app }
        }
        return nil
    }
}

/// The window server's hide request (`SLPSPostHideReq`), the way the app gets told to hide
/// itself besides LaunchServices'. SkyLight is private: looked up with `dlopen`/`dlsym` like
/// MultitouchSupport, nothing private is linked. Nil if a macOS update takes it away
/// (logged once); hiding then relies on `hide()` alone.
struct SkyLight: @unchecked Sendable {
    let processForPID: @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    let postHideRequest: @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    static let shared: SkyLight? = {
        func sym<T>(_ path: String, _ name: String, _: T.Type) -> T? {
            guard let lib = dlopen(path, RTLD_NOW), let p = dlsym(lib, name) else {
                Log.error("no \(name) in \(path): hiding asks LaunchServices only")
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }
        // GetProcessForPID is public but deprecated; looked up too, so no deprecation warning.
        guard let processForPID = sym("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                                      "GetProcessForPID",
                                      (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self),
              let postHideRequest = sym("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLPSPostHideReq",
                                        (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32).self)
        else { return nil }
        return SkyLight(processForPID: processForPID, postHideRequest: postHideRequest)
    }()

    func hide(_ pid: pid_t) {
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return }
        _ = postHideRequest(&psn)
    }
}

/// This login session's state, read live from the window server (nothing cached to go stale).
/// Unknown (no session dictionary) counts as on console and unlocked: better a swipe too
/// many than none.
enum Session {
    private static var current: [String: Any] { CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:] }
    /// False while another user's session is on screen (fast user switching).
    static var onConsole: Bool { current[kCGSessionOnConsoleKey as String] as? Bool ?? true }
    static var screenLocked: Bool { current["CGSSessionScreenIsLocked"] as? Bool ?? false }
}
