import Testing
@testable import AutotouchCore

/// Drives a recognizer with synthetic frames: fingers as (id, x mm, y mm).
private struct Pad {
    var r = SwipeRecognizer()
    var fired: [Swipe] = []

    mutating func frame(_ fingers: [(Int32, Float, Float)]) {
        var ids = SIMD3<Int32>(), x = SIMD3<Float>(), y = SIMD3<Float>()
        for (i, f) in fingers.prefix(3).enumerated() { (ids[i], x[i], y[i]) = f }
        if let s = r.frame(count: fingers.count, ids: ids, x: x, y: y) { fired.append(s) }
    }

    /// Three fingers 15 mm apart starting at (x0, y0), moving by (dx, dy) in `steps` frames.
    mutating func three(from x0: Float = 50, _ y0: Float = 40, by dx: Float, _ dy: Float, steps: Int = 20,
                        ids: (Int32, Int32, Int32) = (1, 2, 3)) {
        for s in 0...steps {
            let t = Float(s) / Float(steps)
            frame([(ids.0, x0 + dx * t, y0 + dy * t),
                   (ids.1, x0 + 15 + dx * t, y0 + 2 + dy * t),
                   (ids.2, x0 + 30 + dx * t, y0 + dy * t)])
        }
    }

    mutating func lift() { frame([]) }
}

@Test func swipeLeftAndRight() {
    var p = Pad()
    p.three(by: -30, 0)
    p.lift()
    p.three(by: 30, 0)
    p.lift()
    #expect(p.fired == [.left, .right])
}

@Test func firesOncePerTouch() {
    var p = Pad()
    p.three(by: -40, 0)
    p.three(from: 10, 40, by: 40, 0)   // back the other way without lifting
    #expect(p.fired == [.left])
    p.lift()
    p.three(by: 40, 0)
    #expect(p.fired == [.left, .right])
}

@Test func firesAtTheThreshold() {
    var p = Pad()
    p.three(by: -(SwipeRecognizer.travel - 0.5), 0)
    #expect(p.fired.isEmpty)
    p.lift()
    p.three(by: -(SwipeRecognizer.travel + 0.5), 0)
    #expect(p.fired == [.left])
}

@Test func toleratesAnArc() {
    var p = Pad()
    p.three(by: 30, 12)   // ~22° off horizontal
    #expect(p.fired == [.right])
}

@Test func ignoresVerticalAndDiagonal() {
    var p = Pad()
    p.three(by: 0, 30)
    p.lift()
    p.three(by: 20, 20)   // 45°
    p.lift()
    // Vertical first, then sideways in the same touch: still not a swipe.
    p.three(by: 0, -20)
    p.three(from: 50, 20, by: -40, 0)
    #expect(p.fired.isEmpty)
}

@Test func ignoresPinchAndSpread() {
    var p = Pad()
    // Outer fingers apart, middle still: average sideways travel 0.
    for s in 0...20 {
        let t = Float(s) / 20
        p.frame([(1, 50 - 20 * t, 40), (2, 65, 42), (3, 80 + 20 * t, 40)])
    }
    p.lift()
    // Two fingers sweep left, one stays: the average passes the threshold, one finger doesn't.
    for s in 0...20 {
        let t = Float(s) / 20
        p.frame([(1, 50 - 25 * t, 40), (2, 65 - 25 * t, 42), (3, 80, 40)])
    }
    #expect(p.fired.isEmpty)
}

@Test func fourFingersAreNotOurs() {
    var p = Pad()
    for s in 0...20 {
        let x = 50 - Float(s) * 2
        p.frame([(1, x, 40), (2, x + 15, 42), (3, x + 30, 40), (4, x + 45, 38)])
    }
    #expect(p.fired.isEmpty)
    // Lifting to three fingers mid-gesture doesn't start a swipe either.
    p.three(by: -30, 0)
    #expect(p.fired.isEmpty)
    p.lift()
    p.three(by: -30, 0)
    #expect(p.fired == [.left])
}

@Test func twoFingerScrollThenThirdFinger() {
    var p = Pad()
    // Two fingers scroll 30 mm left, then a third lands: the swipe starts there.
    for s in 0...20 {
        let x = 80 - Float(s) * 1.5
        p.frame([(1, x, 40), (2, x + 15, 42)])
    }
    p.frame([(1, 50, 40), (2, 65, 42), (3, 80, 40)])
    p.frame([(1, 45, 40), (2, 60, 42), (3, 75, 40)])
    #expect(p.fired.isEmpty)
    p.three(from: 45, 40, by: -20, 0)
    #expect(p.fired == [.left])
}

@Test func contactOrderDoesNotMatter() {
    var p = Pad()
    for s in 0...20 {
        let x = 50 + Float(s) * 1.5
        var f: [(Int32, Float, Float)] = [(7, x, 40), (8, x + 15, 42), (9, x + 30, 40)]
        if s % 2 == 1 { f.reverse() }
        if s % 3 == 2 { f.swapAt(0, 1) }
        p.frame(f)
    }
    #expect(p.fired == [.right])
}

@Test func briefLiftKeepsTheSwipe() {
    var p = Pad()
    p.frame([(1, 50, 40), (2, 65, 42), (3, 80, 40)])
    p.frame([(1, 44, 40), (2, 59, 42), (3, 74, 40)])
    p.frame([(1, 40, 40), (3, 70, 40)])               // finger 2 loses contact for a frame
    p.frame([(1, 36, 40), (2, 51, 42), (3, 66, 40)])  // and is back: 14 mm in all
    #expect(p.fired == [.left])
}

@Test func differentFingerStartsOver() {
    var p = Pad()
    p.frame([(1, 50, 40), (2, 65, 42), (3, 80, 40)])
    p.frame([(1, 44, 40), (2, 59, 42), (3, 74, 40)])
    p.frame([(1, 40, 40), (3, 70, 40)])
    p.frame([(1, 36, 40), (4, 51, 42), (3, 66, 40)])  // a new finger: measured from here
    #expect(p.fired.isEmpty)
    p.frame([(1, 20, 40), (4, 35, 42), (3, 50, 40)])
    #expect(p.fired == [.left])
}

@Test func stillFingersNeverFire() {
    var p = Pad()
    for _ in 0..<1000 { p.frame([(1, 50, 40), (2, 65, 42), (3, 80, 40)]) }
    #expect(p.fired.isEmpty)
}
