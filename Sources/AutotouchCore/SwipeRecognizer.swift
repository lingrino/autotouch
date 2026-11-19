/// A horizontal three-finger swipe, by the direction the fingers move.
public enum Swipe: Sendable, Hashable {
    case left, right
}

/// Recognizes a horizontal three-finger swipe in one trackpad's contact frames.
///
/// It is fed every frame while fingers touch the pad (~125 Hz), with the fingers that are
/// down and their positions in millimetres, so the thresholds mean the same on every
/// trackpad. A swipe is recognized once, as soon as the fingers have travelled far enough
/// together; nothing more is recognized until every finger has lifted. Allocation-free.
///
/// The rules, in order:
/// - Exactly three fingers (`isFinger`: a resting palm isn't one). Four or more is somebody
///   else's gesture (macOS's): ignore everything until all fingers lift. One or two fingers
///   do nothing, so a finger that loses contact for a moment mid-swipe doesn't lose the swipe;
///   longer than `maxLapse` frames and the positions are forgotten (two fingers scrolling a
///   while, then the third back, mustn't fire on where they all were before).
/// - Positions are measured from where the three fingers were when the third came down (a
///   two-finger scroll that gains a finger starts from there, not from the scroll's start).
///   If a different finger joins, start over from that frame.
/// - Mostly vertical travel past the threshold ends it: that's not a horizontal swipe.
/// - Fires when the fingers' average sideways travel reaches `travel`, is at least
///   `dominance` times the vertical travel, and every finger moved at least `fingerTravel`
///   the same way (a pinch or a rotation moves fingers in different directions).
public struct SwipeRecognizer: Sendable {
    /// Average sideways travel (mm) of the three fingers that makes a swipe. 12 felt "slightly
    /// too long" to the user (2026-11-19).
    public static let travel: Float = 9
    /// Each finger must move at least this far (mm) in the swipe's direction.
    public static let fingerTravel: Float = 4
    /// Sideways travel must be at least this many times the vertical travel (within ~34°).
    public static let dominance: Float = 1.5

    /// Whether a trackpad contact counts as a finger: touching (MultitouchSupport stage 3
    /// make-touch or 4 touching) and not classified as something else. The driver labels
    /// each contact: 1–5 fingers, 0 unclassified, 6 and up not a fingertip: a palm or wrist
    /// resting on the pad's edge (6, 7, 8, 10), a fingertip grazing the top edge (7, 12)
    /// (recorded 2026-11-19). Counting a resting palm made a three-finger swipe four contacts
    /// (ignored), and kept the touch from ending between swipes.
    @inlinable
    public static func isFinger(stage: Int32, label: Int32) -> Bool {
        (stage == 3 || stage == 4) && label < 6
    }

    /// Frames in a row with only one or two fingers down that a swipe survives (~80 ms at
    /// 125 Hz; recorded lapses were at most 2 frames).
    public static let maxLapse = 10

    private enum Phase { case idle, tracking, finished }
    private var phase = Phase.idle
    private var lapse = 0
    private var ids = SIMD3<Int32>()
    private var startX = SIMD3<Float>()
    private var startY = SIMD3<Float>()

    public init() {}

    /// One contact frame. `count` is how many fingers are down; when it is 3, `ids`, `x` and
    /// `y` (mm) describe them, in any order. Returns the swipe the first time one is
    /// recognized in this touch.
    public mutating func frame(count: Int, ids: SIMD3<Int32>, x: SIMD3<Float>, y: SIMD3<Float>) -> Swipe? {
        if count == 0 { phase = .idle; return nil }
        if count > 3 { phase = .finished; return nil }
        if count < 3 {
            if phase == .tracking {
                lapse += 1
                if lapse > Self.maxLapse { phase = .idle }
            }
            return nil
        }
        lapse = 0
        if phase == .finished { return nil }

        // Line this frame's fingers up with the anchored ones.
        var dx = SIMD3<Float>(), dy = SIMD3<Float>()
        var matched = phase == .tracking
        if matched {
            for k in 0..<3 {
                let id = self.ids[k]
                let j = ids[0] == id ? 0 : ids[1] == id ? 1 : ids[2] == id ? 2 : -1
                if j < 0 { matched = false; break }
                dx[k] = x[j] - startX[k]
                dy[k] = y[j] - startY[k]
            }
        }
        if !matched {
            self.ids = ids
            startX = x
            startY = y
            phase = .tracking
            return nil
        }

        let mx = dx.sum() / 3, my = dy.sum() / 3
        if abs(my) >= Self.travel && abs(my) > abs(mx) { phase = .finished; return nil }
        guard abs(mx) >= Self.travel, abs(mx) >= Self.dominance * abs(my) else { return nil }
        let direction: Float = mx < 0 ? -1 : 1
        guard (dx * direction).min() >= Self.fingerTravel else { return nil }
        phase = .finished
        return mx < 0 ? .left : .right
    }
}
