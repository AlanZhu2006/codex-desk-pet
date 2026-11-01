import Foundation
import CoreGraphics

/// Continuous portrait transforms driven by the controller's pausable clock.
/// The view applies these scales around the portrait's foot baseline.
struct PortraitMotion {
    struct Shape: Equatable {
        let scaleX: CGFloat
        let scaleY: CGFloat

        static let identity = Shape(scaleX: 1, scaleY: 1)
    }

    private struct Keyframe {
        let time: TimeInterval
        let shape: Shape
    }

    private static let springDuration: TimeInterval = 0.8
    private static let springFrames: [Keyframe] = [
        Keyframe(time: 0, shape: Shape(scaleX: 0.90, scaleY: 1.13)),
        Keyframe(time: 0.20, shape: Shape(scaleX: 1.05, scaleY: 0.96)),
        Keyframe(time: 0.38, shape: Shape(scaleX: 0.984, scaleY: 1.025)),
        Keyframe(time: 0.56, shape: Shape(scaleX: 1.006, scaleY: 0.992)),
        Keyframe(time: springDuration, shape: .identity)
    ]

    private var changedAt: TimeInterval?

    mutating func expressionChanged(at animationTime: TimeInterval) {
        changedAt = animationTime.isFinite ? max(0, animationTime) : nil
    }

    func sample(at animationTime: TimeInterval, expression: String, reducedMotion: Bool) -> Shape {
        guard !reducedMotion, animationTime.isFinite else { return .identity }
        let name = expression.hasPrefix("static:") ? String(expression.dropFirst(7)) : expression
        guard name != "stone" else { return .identity }
        let time = max(0, animationTime)
        let breathing: Double
        switch name {
        case "typing", "running", "working", "tool":
            breathing = 0.006 * sin(time * 9)
        case "crying", "failed", "error":
            breathing = 0.009 * sin(time * 2 * .pi / 0.72)
        case "panic":
            breathing = 0.004 * sin(time * 25)
        default:
            breathing = 0.0125 * sin(time * 2 * .pi / 2.88)
        }

        var spring = Shape.identity
        var breathingWeight = 1.0
        if let changedAt {
            let elapsed = max(0, time - changedAt)
            if elapsed < Self.springDuration {
                spring = Self.spring(at: elapsed)
                // The first changed frame has the measured spring shape;
                // breathing joins smoothly as that response settles.
                breathingWeight = Self.smoothstep(elapsed / Self.springDuration)
            }
        }
        let delta = CGFloat(breathing * breathingWeight)
        return Shape(scaleX: min(1.06, max(0.89, spring.scaleX - delta * 0.38)),
                     scaleY: min(1.13, max(0.95, spring.scaleY + delta)))
    }

    private static func smoothstep(_ progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        return progress * progress * (3 - 2 * progress)
    }

    private static func spring(at elapsed: TimeInterval) -> Shape {
        for index in 1..<springFrames.count {
            let right = springFrames[index]
            guard elapsed <= right.time else { continue }
            let left = springFrames[index - 1]
            let fraction = CGFloat(smoothstep((elapsed - left.time) / (right.time - left.time)))
            return Shape(scaleX: left.shape.scaleX + (right.shape.scaleX - left.shape.scaleX) * fraction,
                         scaleY: left.shape.scaleY + (right.shape.scaleY - left.shape.scaleY) * fraction)
        }
        return .identity
    }

    static func selfTest() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "ClaudeDeskPet.PortraitMotion", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func close(_ left: CGFloat, _ right: CGFloat, tolerance: CGFloat = 0.000001) -> Bool {
            abs(left - right) <= tolerance
        }

        var motion = PortraitMotion()
        let rest = motion.sample(at: 0, expression: "smile", reducedMotion: false)
        let inhale = motion.sample(at: 0.72, expression: "smile", reducedMotion: false)
        let exhale = motion.sample(at: 2.16, expression: "smile", reducedMotion: false)
        let nextCycle = motion.sample(at: 2.88, expression: "smile", reducedMotion: false)
        try require(rest == .identity && close(nextCycle.scaleY, 1), "Breathing does not close its 2.88-second loop")
        try require(close(inhale.scaleY, 1.0125) && close(exhale.scaleY, 0.9875), "Breathing amplitude changed")
        try require(inhale.scaleX < 1 && exhale.scaleX > 1, "Breathing should compensate width slightly")

        motion.expressionChanged(at: 0)
        let stretch = motion.sample(at: 0, expression: "smile", reducedMotion: false)
        let squash = motion.sample(at: 0.2, expression: "smile", reducedMotion: false)
        let rebound = motion.sample(at: 0.38, expression: "smile", reducedMotion: false)
        try require(close(stretch.scaleX, 0.90) && close(stretch.scaleY, 1.13), "Expression response must begin stretched and narrow")
        try require(squash.scaleY < 0.97 && squash.scaleX > 1.04, "Expression response must squash before settling")
        try require(rebound.scaleY > 1.02 && rebound.scaleX < 1, "Expression response lost its small rebound")
        for key in [0.2, 0.38, 0.56, 0.8] {
            let before = motion.sample(at: key - 0.00001, expression: "smile", reducedMotion: false)
            let after = motion.sample(at: key + 0.00001, expression: "smile", reducedMotion: false)
            try require(abs(before.scaleX - after.scaleX) < 0.0001 && abs(before.scaleY - after.scaleY) < 0.0001,
                        "Expression response is discontinuous at a keyframe")
        }
        for name in ["smile", "typing", "running", "crying", "failed", "panic", "static:notes"] {
            for tick in 0...900 {
                let sample = motion.sample(at: Double(tick) / 30, expression: name, reducedMotion: false)
                try require(sample.scaleX.isFinite && sample.scaleY.isFinite, "Motion produced non-finite geometry")
                try require((0.89...1.06).contains(sample.scaleX) && (0.95...1.13).contains(sample.scaleY),
                            "Motion left its safe scale bounds")
                try require(170 * sample.scaleY < 202, "Motion could clip a portrait above its foot baseline")
            }
        }
        for time in [0.0, 0.2, 0.8, 4.5] {
            try require(motion.sample(at: time, expression: "stone", reducedMotion: false) == .identity,
                        "Stone should remain still")
            try require(motion.sample(at: time, expression: "smile", reducedMotion: true) == .identity,
                        "Reduced motion must suppress both breathing and spring")
        }
        let stable = motion.sample(at: 4.2, expression: "smile", reducedMotion: false)
        try require(stable == motion.sample(at: 4.2, expression: "smile", reducedMotion: false),
                    "Sampling a paused clock should remain deterministic")
        motion.expressionChanged(at: 8)
        try require(motion.sample(at: 8, expression: "smile", reducedMotion: false) == stretch,
                    "A later expression change should restart the response")
        try require(motion.sample(at: .nan, expression: "smile", reducedMotion: false) == .identity,
                    "Invalid time must not reach drawing geometry")
        motion.expressionChanged(at: .infinity)
        try require(motion.sample(at: 8, expression: "smile", reducedMotion: false).scaleY.isFinite,
                    "Invalid transition time should be ignored safely")
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
