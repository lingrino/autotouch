import Foundation

/// Installs the agent as a classic per-user LaunchAgent (~/Library/LaunchAgents), like
/// peep's, not an SMAppService one: SMAppService pins the executable's cdhash in a launch
/// constraint, which local rebuilds violated (peep, 2026-11). KeepAlive: launchd starts it
/// at login and again whenever it exits.
enum LaunchAgent {
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(Agent.label).plist" }

    static func plist(executable: String) -> [String: Any] {
        [
            "Label": Agent.label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",   // never throttled: a swipe must act right away
            "AssociatedBundleIdentifiers": ["com.lingrino.autotouch"],
        ]
    }

    static var loaded: Bool { launchctl(["print", "gui/\(getuid())/\(Agent.label)"]) == 0 }

    /// Writes the plist if it differs and (re)loads the agent: always when `force` (a new
    /// build), else only when the plist changed or the agent isn't loaded. Only the copy in
    /// /Applications registers itself: the agent must run from a path that stays put.
    static func register(force: Bool) -> Bool {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasPrefix("/Applications/"), bundle.hasSuffix(".app"), let exe = Bundle.main.executablePath else {
            Log.error("not registering the agent from \(bundle): only /Applications/Autotouch.app does")
            fputs("autotouch: only /Applications/Autotouch.app registers the agent (this is \(bundle))\n", stderr)
            return false
        }
        let path = plistPath
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist(executable: exe), format: .xml, options: 0) else {
            return false
        }
        let changed = FileManager.default.contents(atPath: path) != data
        if changed {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: path, contents: data) else {
                Log.error("can't write \(path)")
                return false
            }
        }
        if force || changed || !loaded {
            launchctl(["bootout", "gui/\(getuid())/\(Agent.label)"])
            let status = launchctl(["bootstrap", "gui/\(getuid())", path])
            Log.info("agent \(Agent.version) registered (bootstrap \(status))")
            if status != 0 { fputs("autotouch: launchctl bootstrap failed (\(status))\n", stderr) }
            return status == 0
        }
        return true
    }

    /// Runs launchctl to completion, output discarded; its exit status (-1 if it didn't start).
    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
