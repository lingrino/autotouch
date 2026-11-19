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
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session[kCGSessionOnConsoleKey as String] as? Bool == false || session["CGSSessionScreenIsLocked"] as? Bool == true {
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
    static func hideAppUnderCursor(_ source: String) {
        guard let app = appUnderCursor() ?? NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else {
            Log.info("right swipe (\(source)): no app to hide")
            return
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        // hide() returns false even when it works (macOS 27.2, from a process that isn't an
        // NSApplication): check what happened instead. Not for Finder (macOS keeps it visible
        // when no other app is), nor when another swipe came since (it may have shown it again).
        _ = app.hide()
        Log.info("right swipe (\(source)): hide \(name)")
        guard app.bundleIdentifier != "com.apple.finder" else { return }
        let pid = app.processIdentifier, seq = sequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if seq == sequence, let a = NSRunningApplication(processIdentifier: pid), !a.isHidden {
                    Log.error("right swipe (\(source)): \(name) is still not hidden")
                }
            }
        }
    }

    /// The app owning the frontmost normal-level window under the pointer.
    static func appUnderCursor() -> NSRunningApplication? {
        guard let point = CGEvent(source: nil)?.location,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in windows {   // front to back
            guard w[kCGWindowLayer as String] as? Int == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  let pid = w[kCGWindowOwnerPID as String] as? Int else { continue }
            return NSRunningApplication(processIdentifier: pid_t(pid))
        }
        return nil
    }
}
