import Foundation
import CoreGraphics

/// Continuous portrait transforms driven by the controller's pausable clock.
/// Offsets use the canonical 192x208 cell's source-pixel units.
struct PortraitMotion {
    struct Shape: Equatable {
        let scaleX: CGFloat
        let scaleY: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        init(scaleX: CGFloat, scaleY: CGFloat, offsetX: CGFloat = 0, offsetY: CGFloat = 0) {
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.offsetX = offsetX
            self.offsetY = offsetY
        }

        static let identity = Shape(scaleX: 1, scaleY: 1)
    }

    private struct Keyframe {
        let time: TimeInterval
        let shape: Shape
    }

    private static let transitionDuration: TimeInterval = 0.8
    private static let springFrames: [Keyframe] = [
        Keyframe(time: 0, shape: Shape(scaleX: 0.90, scaleY: 1.13)),
        Keyframe(time: 0.20, shape: Shape(scaleX: 1.05, scaleY: 0.96)),
        Keyframe(time: 0.38, shape: Shape(scaleX: 0.984, scaleY: 1.025)),
        Keyframe(time: 0.56, shape: Shape(scaleX: 1.006, scaleY: 0.992)),
        Keyframe(time: transitionDuration, shape: .identity)
    ]
    private static let hoverFrames: [Keyframe] = [
        Keyframe(time: 0, shape: .identity),
        Keyframe(time: 0.06, shape: Shape(scaleX: 1.05, scaleY: 0.95)),
        Keyframe(time: 0.14, shape: Shape(scaleX: 0.97, scaleY: 1.04, offsetY: 8)),
        Keyframe(time: 0.29, shape: Shape(scaleX: 0.99, scaleY: 1.01, offsetY: 16)),
        Keyframe(time: 0.43, shape: Shape(scaleX: 0.995, scaleY: 1.0, offsetY: 9)),
        Keyframe(time: 0.55, shape: Shape(scaleX: 1.055, scaleY: 0.95)),
        Keyframe(time: 0.65, shape: Shape(scaleX: 0.992, scaleY: 1.015)),
        Keyframe(time: transitionDuration, shape: .identity)
    ]

    private var changedAt: TimeInterval?
    private var hoverStartedAt: TimeInterval?

    mutating func expressionChanged(at animationTime: TimeInterval) {
        if isHoverJumping(at: animationTime) {
            changedAt = nil
            return
        }
        changedAt = animationTime.isFinite ? max(0, animationTime) : nil
    }

    /// One flight at a time. The controller's edge tracker owns re-arming after
    /// leaving the stable interaction region; repeated entry cannot add lift.
    @discardableResult mutating func hoverEntered(at animationTime: TimeInterval) -> Bool {
        guard animationTime.isFinite, animationTime >= 0,
              !isHoverJumping(at: animationTime) else { return false }
        changedAt = nil
        hoverStartedAt = animationTime
        return true
    }

    mutating func cancelHover() { hoverStartedAt = nil }

    func isHoverJumping(at animationTime: TimeInterval) -> Bool {
        guard animationTime.isFinite, let hoverStartedAt else { return false }
        let elapsed = animationTime - hoverStartedAt
        return elapsed >= 0 && elapsed < Self.transitionDuration
    }

    func sample(at animationTime: TimeInterval, expression: String, reducedMotion: Bool) -> Shape {
        guard !reducedMotion, animationTime.isFinite else { return .identity }
        let time = max(0, animationTime)
        let name = expression.hasPrefix("static:") ? String(expression.dropFirst(7)) : expression
        let loop = Self.expressionLoop(at: time, name: name)
        var transition = Shape.identity
        var loopWeight = 1.0

        // Hover owns the response while in flight. It replaces the pose-change
        // spring rather than multiplying two stretches into a distorted body.
        if let hoverStartedAt, isHoverJumping(at: time) {
            let elapsed = time - hoverStartedAt
            transition = Self.interpolate(Self.hoverFrames, at: elapsed)
            loopWeight = Self.smoothstep(elapsed / Self.transitionDuration)
        } else if let changedAt {
            let elapsed = time - changedAt
            if elapsed >= 0 && elapsed < Self.transitionDuration {
                transition = Self.interpolate(Self.springFrames, at: elapsed)
                loopWeight = Self.smoothstep(elapsed / Self.transitionDuration)
            }
        }

        let weight = CGFloat(loopWeight)
        return Shape(
            scaleX: min(1.06, max(0.89, transition.scaleX + (loop.scaleX - 1) * weight)),
            scaleY: min(1.13, max(0.95, transition.scaleY + (loop.scaleY - 1) * weight)),
            offsetX: min(4, max(-4, transition.offsetX + loop.offsetX * weight)),
            offsetY: min(24, max(0, transition.offsetY + loop.offsetY * weight))
        )
    }

    private static func expressionLoop(at time: TimeInterval, name: String) -> Shape {
        func shape(_ sx: Double, _ sy: Double, _ x: Double = 0, _ y: Double = 0) -> Shape {
            Shape(scaleX: CGFloat(sx), scaleY: CGFloat(sy), offsetX: CGFloat(x), offsetY: CGFloat(y))
        }
        func phase(_ period: Double) -> Double { 2 * .pi * time / period }
        func hop(_ value: Double) -> Double { pow(max(0, sin(value)), 2) }
        switch name {
        case "smile-closed", "waiting":
            let wave = sin(phase(2.4))
            return shape(1 - 0.007 * wave, 1 + 0.016 * wave, 0.7 * sin(phase(4.8)), 2.5 * hop(phase(2.4)))
        case "confetti", "jumping", "celebrate":
            let wave = sin(phase(1.8))
            return shape(1 - 0.009 * wave, 1 + 0.018 * wave, 1.3 * sin(phase(3.6)), 5.5 * hop(phase(1.8)))
        case "typing", "running", "working", "tool":
            let tap = sin(time * 9)
            return shape(1 - 0.004 * tap, 1 + 0.012 * tap, 0.6 * sin(time * 12), 0.45 * (1 - cos(time * 9)))
        case "crying", "failed", "error":
            let sob = sin(phase(0.72))
            return shape(1 - 0.008 * sob, 1 + 0.018 * sob, 1.5 * sin(phase(0.42)), 0.8 * (1 - cos(phase(0.72))))
        case "panic":
            return shape(1 - 0.008 * sin(time * 21), 1 + 0.012 * sin(time * 17),
                         2.5 * sin(time * 25), 0.4 * (1 - cos(time * 25)))
        case "notes", "review", "thinking":
            let wave = sin(phase(3.0))
            return shape(1 - 0.004 * wave, 1 + 0.015 * wave, 1.5 * sin(phase(3.6)))
        case "guilty", "aborted", "interrupted":
            let wave = cos(phase(3.2))
            return shape(1 - 0.006 * wave, 1 + 0.014 * wave, 2 * sin(phase(3.2)), 0.6 * (1 - wave))
        case "confident":
            let wave = sin(phase(3.4))
            return shape(1 - 0.006 * wave, 1 + 0.018 * wave, 0.8 * sin(phase(5)))
        case "knock", "waving":
            let wave = sin(phase(2.6))
            return shape(1 - 0.007 * wave, 1 + 0.014 * wave, 2 * sin(phase(2.6)), 1.4 * hop(phase(2.6)))
        case "stone":
            let wave = sin(phase(2.4))
            return shape(1 - 0.002 * wave, 1 + 0.004 * wave, 0.65 * sin(phase(0.9)))
        default:
            let wave = sin(phase(2.88))
            return shape(1 - 0.005 * wave, 1 + 0.016 * wave, 1.2 * sin(phase(5.76)))
        }
    }

    private static func smoothstep(_ progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        return progress * progress * (3 - 2 * progress)
    }

    private static func interpolate(_ frames: [Keyframe], at elapsed: TimeInterval) -> Shape {
        for index in 1..<frames.count {
            let right = frames[index]
            guard elapsed <= right.time else { continue }
            let left = frames[index - 1]
            let fraction = CGFloat(smoothstep((elapsed - left.time) / (right.time - left.time)))
            func blend(_ left: CGFloat, _ right: CGFloat) -> CGFloat { left + (right - left) * fraction }
            return Shape(scaleX: blend(left.shape.scaleX, right.shape.scaleX),
                         scaleY: blend(left.shape.scaleY, right.shape.scaleY),
                         offsetX: blend(left.shape.offsetX, right.shape.offsetX),
                         offsetY: blend(left.shape.offsetY, right.shape.offsetY))
        }
        return .identity
    }

    static func selfTest() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.PortraitMotion", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func close(_ left: CGFloat, _ right: CGFloat, tolerance: CGFloat = 0.000001) -> Bool {
            abs(left - right) <= tolerance
        }
        let names = ["smile", "smile-closed", "typing", "notes", "knock", "confetti",
                     "panic", "guilty", "stone", "confident", "crying"]
        var motion = PortraitMotion()
        for name in names {
            let initial = motion.sample(at: 0, expression: name, reducedMotion: false)
            var maximumVariation: CGFloat = 0
            for tick in 0...900 {
                let time = Double(tick) / 30
                let value = motion.sample(at: time, expression: name, reducedMotion: false)
                let variation = abs(value.scaleX - initial.scaleX) * 170 + abs(value.scaleY - initial.scaleY) * 170
                    + abs(value.offsetX - initial.offsetX) + abs(value.offsetY - initial.offsetY)
                maximumVariation = max(maximumVariation, variation)
                try require(value.scaleX.isFinite && value.scaleY.isFinite && value.offsetX.isFinite && value.offsetY.isFinite,
                            "Motion produced non-finite geometry")
                try require((0.89...1.06).contains(value.scaleX) && (0.95...1.13).contains(value.scaleY),
                            "Motion left its safe scale bounds")
                try require(abs(value.offsetX) <= 4 && (0...24).contains(value.offsetY), "Motion left its safe offset bounds")
                try require(6 + 170 * value.scaleY + value.offsetY <= 208 + 24,
                            "Motion could clip the reserved top clearance")
                try require(abs(value.offsetX) + 160 * value.scaleX / 2 < 192 / 2,
                            "Motion could clip a portrait horizontally")
                try require(motion.sample(at: time, expression: name, reducedMotion: true) == .identity,
                            "Reduced motion must suppress every expression")
            }
            try require(maximumVariation > 0.5, "A selectable expression is still completely static: \(name)")
        }
        let periodic = motion.sample(at: 2.88, expression: "smile", reducedMotion: false)
        try require(close(periodic.scaleY, 1), "Neutral breathing lost its 2.88-second cycle")

        motion.expressionChanged(at: 0)
        let stretch = motion.sample(at: 0, expression: "smile", reducedMotion: false)
        let squash = motion.sample(at: 0.2, expression: "smile", reducedMotion: false)
        try require(close(stretch.scaleX, 0.90) && close(stretch.scaleY, 1.13), "Expression response must begin stretched and narrow")
        try require(squash.scaleY < 0.97 && squash.scaleX > 1.04, "Expression response must squash before settling")
        for key in [0.2, 0.38, 0.56, 0.8] {
            let before = motion.sample(at: key - 0.00001, expression: "smile", reducedMotion: false)
            let after = motion.sample(at: key + 0.00001, expression: "smile", reducedMotion: false)
            try require(abs(before.scaleX - after.scaleX) < 0.0001 && abs(before.scaleY - after.scaleY) < 0.0001,
                        "Expression response is discontinuous at a keyframe")
        }
        var hover = PortraitMotion()
        hover.expressionChanged(at: 1)
        try require(hover.hoverEntered(at: 1), "First hover did not start a jump")
        let early = hover.sample(at: 1, expression: "smile", reducedMotion: false)
        try require(close(early.scaleY, 1), "Hover multiplied the expression-change spring")
        try require(hover.isHoverJumping(at: 1.2), "Hover flight ended prematurely")
        try require(!hover.hoverEntered(at: 1.2), "Repeated entry stacked a second jump")
        let apex = hover.sample(at: 1.29, expression: "smile", reducedMotion: false)
        try require(apex.offsetY >= 15.9 && apex.offsetY <= 24, "Hover needs visible lift at its apex")
        let landing = hover.sample(at: 1.55, expression: "smile", reducedMotion: false)
        try require(landing.scaleY < 0.97 && landing.offsetY < 0.01, "Hover lost its landing squash")
        hover.expressionChanged(at: 1.6)
        let ended = hover.sample(at: 1.81, expression: "smile", reducedMotion: false)
        let baseline = PortraitMotion().sample(at: 1.81, expression: "smile", reducedMotion: false)
        try require(!hover.isHoverJumping(at: 1.81) && ended == baseline, "Hover did not return to the expression loop")
        try require(hover.hoverEntered(at: 2), "A later entry cannot start another jump")
        hover.cancelHover()
        try require(!hover.isHoverJumping(at: 2.1), "Gesture/menu cancellation left a jump queued")
        try require(hover.sample(at: 2.1, expression: "smile", reducedMotion: false)
                    == PortraitMotion().sample(at: 2.1, expression: "smile", reducedMotion: false),
                    "Cancelled hover still affects the portrait")
        try require(!hover.hoverEntered(at: .nan) && !hover.hoverEntered(at: -1), "Invalid hover time should be ignored")
        try require(hover.sample(at: .nan, expression: "smile", reducedMotion: false) == .identity,
                    "Invalid time must not reach drawing geometry")
        try require(motion.sample(at: 4.2, expression: "typing", reducedMotion: false)
                    == motion.sample(at: 4.2, expression: "typing", reducedMotion: false),
                    "Sampling a paused clock should be deterministic")
        motion.expressionChanged(at: .infinity)
        try require(motion.sample(at: 8, expression: "smile", reducedMotion: false).scaleY.isFinite,
                    "Invalid transition time should be ignored safely")
    }
}

/// Tracks the pointer's edge independently of the animation's changing bounds.
/// Even blocked entries are remembered, so releasing a click or closing a menu
/// while still over the character cannot queue another surprise jump.
struct PetHoverTracker {
    private(set) var isInside = false

    mutating func update(isInside: Bool, eligible: Bool) -> Bool {
        let entered = !self.isInside && isInside
        self.isInside = isInside
        return entered && eligible
    }

    static func selfTest() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.PetHoverTracker", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        var tracker = PetHoverTracker()
        try require(tracker.update(isInside: true, eligible: true), "Pointer entry should trigger once")
        for _ in 0..<100 { try require(!tracker.update(isInside: true, eligible: true), "Staying inside retriggered hover") }
        try require(!tracker.update(isInside: false, eligible: true), "Leaving should only re-arm")
        try require(tracker.update(isInside: true, eligible: true), "Re-entry should trigger again")
        _ = tracker.update(isInside: false, eligible: true)
        try require(!tracker.update(isInside: true, eligible: false), "Blocked input should not trigger")
        try require(!tracker.update(isInside: true, eligible: true), "Unblocking should not replay an entry")
        _ = tracker.update(isInside: false, eligible: false)
        try require(tracker.update(isInside: true, eligible: true), "A real later entry should re-arm after blocking")
    }
}

/// Separates a light click from dragging, including small pointer jitter.
/// The controller owns window movement; this type only classifies the gesture.
struct PetPressTracker {
    private(set) var isPressed = false
    private(set) var isDragging = false
    private var pressOrigin = CGPoint.zero
    private static let dragThreshold: CGFloat = 4

    mutating func begin(at point: CGPoint) {
        cancel()
        guard Self.valid(point) else { return }
        pressOrigin = point
        isPressed = true
    }

    @discardableResult mutating func drag(to point: CGPoint) -> Bool {
        guard isPressed else { return false }
        guard Self.valid(point) else { cancel(); return false }
        if hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) >= Self.dragThreshold {
            isDragging = true
        }
        return isDragging
    }

    /// Returns true only for a valid pressed gesture that never became a drag.
    mutating func end(at point: CGPoint) -> Bool {
        guard isPressed else { return false }
        drag(to: point)
        let wasClick = isPressed && !isDragging
        cancel()
        return wasClick
    }

    mutating func cancel() {
        isPressed = false
        isDragging = false
        pressOrigin = .zero
    }

    private static func valid(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    static func selfTest() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "ClaudeDeskPet.PetPressTracker", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        var tracker = PetPressTracker()
        try require(!tracker.end(at: .zero), "A release without a press cannot click")
        tracker.begin(at: CGPoint(x: 20, y: 30))
        try require(tracker.isPressed && !tracker.isDragging, "Press should not immediately count as dragging")
        try require(!tracker.drag(to: CGPoint(x: 22, y: 32)), "Small pointer jitter should remain a click")
        try require(tracker.end(at: CGPoint(x: 22, y: 32)), "A light release should click")
        try require(!tracker.isPressed && !tracker.isDragging, "Release must clear gesture state")

        tracker.begin(at: .zero)
        try require(tracker.drag(to: CGPoint(x: 4, y: 0)), "A four-point movement should start dragging")
        tracker.drag(to: .zero)
        try require(!tracker.end(at: .zero), "Returning to the press point must not turn a drag into a click")
        tracker.begin(at: CGPoint(x: -100, y: 400))
        try require(tracker.end(at: CGPoint(x: -100, y: 400)), "A new gesture must not retain the old drag")

        tracker.begin(at: .zero)
        try require(!tracker.end(at: CGPoint(x: 0, y: 5)), "Release displacement must catch a missed drag event")
        tracker.begin(at: .zero)
        tracker.cancel()
        try require(!tracker.end(at: .zero), "Cancelled gestures must never click")
        tracker.begin(at: CGPoint(x: CGFloat.nan, y: 0))
        try require(!tracker.isPressed, "Invalid coordinates must not begin a gesture")
        tracker.begin(at: .zero)
        tracker.drag(to: CGPoint(x: CGFloat.infinity, y: 0))
        try require(!tracker.isPressed && !tracker.end(at: .zero), "Invalid drag coordinates should cancel safely")
    }
}
