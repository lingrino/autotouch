import Foundation
import IOKit
import AutotouchCore
import os

/// MultitouchSupport.framework: the private framework every trackpad-gesture tool uses. It
/// hands a registered callback each contact frame of a touch device (~125 Hz while
/// fingers touch it, nothing otherwise), on a thread of its own. Needs no privacy grant.
/// Looked up at runtime (dlsym), so there is nothing private to link against.
struct MTAPI: @unchecked Sendable {
    typealias Device = UnsafeMutableRawPointer
    /// (device, contacts, contact count, timestamp, frame number). The counts are read as
    /// 32-bit: correct whether the framework passes int or size_t.
    typealias FrameCallback = @convention(c) (Device?, UnsafeRawPointer?, Int32, Double, Int32) -> Void

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (Device, FrameCallback) -> Void
    let unregister: @convention(c) (Device, FrameCallback) -> Void
    let start: @convention(c) (Device, Int32) -> Int32
    let stop: @convention(c) (Device) -> Void
    let isRunning: @convention(c) (Device) -> Bool
    let familyID: @convention(c) (Device, UnsafeMutablePointer<Int32>) -> Int32
    let surface: @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    static let shared: MTAPI? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW) else {
            Log.error("can't load MultitouchSupport: \(String(cString: dlerror()))")
            return nil
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { Log.error("MultitouchSupport has no \(name)"); return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let createList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
              let register = sym("MTRegisterContactFrameCallback", (@convention(c) (Device, FrameCallback) -> Void).self),
              let unregister = sym("MTUnregisterContactFrameCallback", (@convention(c) (Device, FrameCallback) -> Void).self),
              let start = sym("MTDeviceStart", (@convention(c) (Device, Int32) -> Int32).self),
              let stop = sym("MTDeviceStop", (@convention(c) (Device) -> Void).self),
              let isRunning = sym("MTDeviceIsRunning", (@convention(c) (Device) -> Bool).self),
              let familyID = sym("MTDeviceGetFamilyID", (@convention(c) (Device, UnsafeMutablePointer<Int32>) -> Int32).self),
              let surface = sym("MTDeviceGetSensorSurfaceDimensions",
                                (@convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self)
        else { return nil }
        return MTAPI(createList: createList, register: register, unregister: unregister, start: start, stop: stop,
                     isRunning: isRunning, familyID: familyID, surface: surface)
    }()
}

/// The MTTouch struct (96 bytes per contact), as far as Autotouch reads it. Confirmed against
/// live frames on macOS 27.2 (normalized positions in 0…1, stages 1…7); `onFrame` drops
/// frames that don't look like this, and logs it once.
private enum Contact {
    static let stride = 96
    static let id = 16       // Int32 path index: stable while the finger stays down
    static let stage = 20    // Int32: 1 start-in-range, 2 hover, 3 make-touch, 4 touching, 5 break-touch, 6 linger, 7 out-of-range
    static let x = 32        // Float, normalized 0…1 left → right
    static let y = 36        // Float, normalized 0…1 bottom → top
}

/// What the frame callback (MultitouchSupport's thread) shares with the main thread.
struct FrameState: Sendable {
    struct Pad: Sendable {
        var device: UInt              // MTDeviceRef address
        var width: Float, height: Float   // surface, mm
        var recognizer = SwipeRecognizer()
    }
    var pads: [Pad] = []
    var frames: UInt64 = 0
    var lastFrame: UInt64 = 0         // nowNanos() of the newest frame
    var badLayoutLogged = false
}

let frameState = OSAllocatedUnfairLock(initialState: FrameState())

/// Runs on MultitouchSupport's thread for every frame of every device: keep it trivial.
private func onFrame(_ device: MTAPI.Device?, _ contacts: UnsafeRawPointer?, _ count: Int32, _: Double, _: Int32) {
    guard let device else { return }
    var n = 0
    var ids = SIMD3<Int32>(), xs = SIMD3<Float>(), ys = SIMD3<Float>()
    var sane = (0...64).contains(count)
    if sane, count > 0, let contacts {
        for i in 0..<Int(count) {
            let c = contacts + i * Contact.stride
            let stage = c.loadUnaligned(fromByteOffset: Contact.stage, as: Int32.self)
            let x = c.loadUnaligned(fromByteOffset: Contact.x, as: Float.self)
            let y = c.loadUnaligned(fromByteOffset: Contact.y, as: Float.self)
            guard (0...7).contains(stage), x > -0.5, x < 1.5, y > -0.5, y < 1.5 else { sane = false; break }
            guard stage == 3 || stage == 4 else { continue }
            if n < 3 {
                ids[n] = c.loadUnaligned(fromByteOffset: Contact.id, as: Int32.self)
                xs[n] = x
                ys[n] = y
            }
            n += 1
        }
    }
    let address = UInt(bitPattern: device)
    let now = nowNanos()
    let (fingers, valid, fids, fx, fy) = (n, sane, ids, xs, ys)
    let swipe: Swipe? = frameState.withLock { s in
        s.frames &+= 1
        s.lastFrame = now
        guard valid else {
            if !s.badLayoutLogged {
                s.badLayoutLogged = true
                Log.error("contact frame doesn't look like the MTTouch layout Autotouch knows (count \(count)): ignoring such frames")
            }
            return nil
        }
        guard let k = s.pads.firstIndex(where: { $0.device == address }) else { return nil }
        return s.pads[k].recognizer.frame(count: fingers, ids: fids, x: fx * s.pads[k].width, y: fy * s.pads[k].height)
    }
    if let swipe {
        DispatchQueue.main.async { MainActor.assumeIsolated { Actions.perform(swipe, from: "gesture") } }
    }
}

/// The trackpads Autotouch listens to. Rebuilt from scratch (stop everything, list devices,
/// start the trackpads) at start and whenever something may have invalidated the device
/// objects: a trackpad appearing or going away (IOKit), wake from sleep, displays being
/// reconfigured, coming back to the login session. A rebuild costs a few ms; a stale device
/// costs every swipe until the next one, so rebuild on any hint.
@MainActor
final class Trackpads {
    static let shared = Trackpads()

    /// Magic Mouse (1st and 2nd generation) family IDs: touch-sensitive too, but not a trackpad.
    private static let mouseFamilies: Set<Int32> = [112, 113]
    private let callback: MTAPI.FrameCallback = onFrame
    private var list: CFArray?
    private var devices: [MTAPI.Device] = []
    private var pending = 0
    private var ioPort: IONotificationPortRef?
    private var ioIterators: [io_iterator_t] = []
    private(set) var rebuilds = 0
    /// False while another user's session is on screen: nothing to listen for then.
    var sessionActive = true

    var count: Int { devices.count }
    var running: Int { devices.filter { MTAPI.shared?.isRunning($0) == true }.count }

    func rebuild(_ why: String) {
        stop()
        guard sessionActive, let mt = MTAPI.shared else { return }
        guard let list = mt.createList()?.takeRetainedValue() else {
            Log.error("MTDeviceCreateList returned nothing (\(why))")
            return
        }
        var pads: [FrameState.Pad] = []
        var trackpads: [MTAPI.Device] = []
        var skipped: [Int32] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let d = UnsafeMutableRawPointer(mutating: raw)
            var family: Int32 = 0
            _ = mt.familyID(d, &family)
            if Self.mouseFamilies.contains(family) { skipped.append(family); continue }
            var w: Int32 = 0, h: Int32 = 0   // hundredths of a mm
            _ = mt.surface(d, &w, &h)
            pads.append(FrameState.Pad(device: UInt(bitPattern: d),
                                       width: w > 0 ? Float(w) / 100 : 125, height: h > 0 ? Float(h) / 100 : 77))
            trackpads.append(d)
        }
        frameState.withLock { [pads] in $0.pads = pads }
        var failed: [Int32] = []
        for d in trackpads {
            mt.register(d, callback)
            let status = mt.start(d, 0)
            if status != 0 { failed.append(status) }
        }
        self.list = list
        devices = trackpads
        rebuilds += 1
        let sizes = pads.map { "\(Int($0.width))×\(Int($0.height)) mm" }.joined(separator: ", ")
        Log.info("listening on \(trackpads.count) trackpad(s) [\(sizes)] (\(why))"
                 + (skipped.isEmpty ? "" : "; skipped mouse families \(skipped)")
                 + (failed.isEmpty ? "" : "; MTDeviceStart failed: \(failed)"))
    }

    func stop() {
        guard let mt = MTAPI.shared else { return }
        for d in devices {
            mt.unregister(d, callback)
            mt.stop(d)
        }
        frameState.withLock { $0.pads = [] }
        devices = []
        list = nil
    }

    /// Coalesces bursts of hints (a wake brings several) into one rebuild.
    func rebuildSoon(_ why: String, after delay: Double = 1) {
        pending &+= 1
        let generation = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let me = Trackpads.shared
                guard generation == me.pending else { return }
                me.rebuild(why)
            }
        }
    }

    /// IOKit notifications for touch devices coming and going (a Magic Trackpad
    /// connecting or disconnecting, the built-in one being re-created).
    func watchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.error("IONotificationPortCreate failed: no device change notifications")
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        ioPort = port
        let changed: IOServiceMatchingCallback = { _, iterator in
            let n = drain(iterator)
            MainActor.assumeIsolated { Trackpads.shared.rebuildSoon("\(n) touch device(s) added or removed") }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"), changed, nil, &it)
            guard kr == KERN_SUCCESS else { Log.error("IOServiceAddMatchingNotification(\(type)): \(kr)"); continue }
            _ = drain(it)   // arms the notification; the devices already there are the initial rebuild's
            ioIterators.append(it)
        }
    }
}

/// Empties an IOKit iterator (required to re-arm its notification); how many it held.
private func drain(_ iterator: io_iterator_t) -> Int {
    var n = 0
    var o = IOIteratorNext(iterator)
    while o != 0 {
        IOObjectRelease(o)
        n += 1
        o = IOIteratorNext(iterator)
    }
    return n
}
