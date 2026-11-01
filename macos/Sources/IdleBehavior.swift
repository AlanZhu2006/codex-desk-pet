import Foundation
import CoreGraphics

/// Small, local idle actions. This value type owns no windows, timers or disk
/// state; callers supply monotonic time and decide when idling is appropriate.
struct IdleBehavior {
    struct Output {
        let origin: CGPoint?
        /// `idle` / `waving` are atlas animations; `static:name` is a portrait.
        let pose: String?

        static let none = Output(origin: nil, pose: nil)
    }

    private struct Journey {
        let from: CGPoint
        let to: CGPoint
        let startedAt: TimeInterval
        let duration: TimeInterval
        let frequency: Double
        let amplitude: CGFloat
    }

    private struct RandomSource {
        var state: UInt64

        mutating func unit() -> Double {
            // SplitMix64 gives reproducible schedules without global RNG state.
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            value ^= value >> 31
            return Double(value >> 11) / 9_007_199_254_740_992.0
        }

        mutating func value(_ lower: Double, _ upper: Double) -> Double {
            lower + (upper - lower) * unit()
        }
    }

    private(set) var anchor = CGPoint.zero
    private(set) var currentOrigin = CGPoint.zero
    private(set) var currentPose = "idle"
    var isWandering: Bool { journey != nil }

    private var allowedRect = CGRect.zero
    private var random: RandomSource
    private var journey: Journey?
    private var nextPoseAt: TimeInterval = 0
    private var poseUntil: TimeInterval?
    private var nextJourneyAt: TimeInterval = 0
    private var lastUpdateAt: TimeInterval?
    private var wasEligible = false
    private var previousPosesEnabled = false
    private var previousWanderingEnabled = false

    init(seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        random = RandomSource(state: seed)
    }

    /// `allowedRect` describes legal *window origins*, after subtracting the
    /// complete panel size from the screen's usable frame. Only reset changes
    /// the home anchor: an autonomous stroll can never move its own home.
    mutating func reset(now: TimeInterval, origin: CGPoint, allowedRect: CGRect) {
        self.allowedRect = Self.validRect(allowedRect)
        anchor = clamp(origin, to: self.allowedRect)
        currentOrigin = anchor
        currentPose = "idle"
        journey = nil
        poseUntil = nil
        wasEligible = false
        previousPosesEnabled = false
        previousWanderingEnabled = false
        lastUpdateAt = now.isFinite ? now : nil
        schedule(after: now.isFinite ? now : 0)
    }

    /// A blocked update emits nothing, so it cannot replace a working/error or
    /// manually chosen expression. Resuming starts fresh deadlines from the
    /// last visible location, rather than catching up or snapping home.
    mutating func update(now: TimeInterval, eligible: Bool, posesEnabled: Bool,
                         wanderingEnabled: Bool, reduceMotion: Bool,
                         pointerNear: Bool) -> Output {
        guard now.isFinite else { return .none }
        let timeJumped = lastUpdateAt.map { now < $0 || now - $0 > 1 } ?? false
        lastUpdateAt = now
        let canIdle = eligible && !reduceMotion && !pointerNear

        guard canIdle else {
            journey = nil
            poseUntil = nil
            wasEligible = false
            previousPosesEnabled = posesEnabled
            previousWanderingEnabled = wanderingEnabled
            return .none
        }

        if !wasEligible {
            wasEligible = true
            journey = nil
            poseUntil = nil
            currentPose = "idle"
            previousPosesEnabled = posesEnabled
            previousWanderingEnabled = wanderingEnabled
            schedule(after: now)
            return Output(origin: nil, pose: "idle")
        }

        // A suspended laptop or delayed run loop must not teleport to the end
        // of a journey, or execute a burst of missed idle actions on wake.
        if timeJumped {
            journey = nil
            poseUntil = nil
            schedule(after: now)
            let pose = currentPose == "idle" ? nil : "idle"
            currentPose = "idle"
            previousPosesEnabled = posesEnabled
            previousWanderingEnabled = wanderingEnabled
            return Output(origin: nil, pose: pose)
        }

        var outputPose: String?
        if posesEnabled != previousPosesEnabled {
            nextPoseAt = now + random.value(6, 12)
            poseUntil = nil
            if currentPose != "idle" {
                currentPose = "idle"
                outputPose = "idle"
            }
            previousPosesEnabled = posesEnabled
        }
        if wanderingEnabled != previousWanderingEnabled {
            journey = nil
            nextJourneyAt = now + random.value(8, 16)
            previousWanderingEnabled = wanderingEnabled
        }

        if let deadline = poseUntil, now >= deadline {
            poseUntil = nil
            currentPose = "idle"
            outputPose = "idle"
        }

        // Keep the expression steady during a stroll. Most of each idle cycle
        // stays neutral; brief benign expressions never masquerade as errors.
        if posesEnabled && journey == nil && now >= nextPoseAt {
            nextPoseAt = now + random.value(6, 12)
            let pose = choosePose()
            if pose != currentPose {
                currentPose = pose
                outputPose = pose
            }
            if pose != "idle" { poseUntil = now + random.value(2.5, 4.5) }
        }

        if wanderingEnabled && journey == nil && currentPose == "idle" && now >= nextJourneyAt {
            beginJourney(now: now)
        }

        var outputOrigin: CGPoint?
        if let journey {
            let progress = min(1, max(0, (now - journey.startedAt) / journey.duration))
            let point = progress >= 1 ? journey.to : position(on: journey, progress: progress)
            if point != currentOrigin {
                currentOrigin = point
                outputOrigin = point
            }
            if progress >= 1 {
                self.journey = nil
                nextJourneyAt = now + random.value(8, 16)
            }
        }
        return Output(origin: outputOrigin, pose: outputPose)
    }

    private mutating func schedule(after now: TimeInterval) {
        nextPoseAt = now + random.value(6, 12)
        nextJourneyAt = now + random.value(8, 16)
    }

    private mutating func choosePose() -> String {
        let choice = random.unit()
        switch choice {
        case ..<0.45: return "idle"
        case ..<0.60: return "static:smile"
        case ..<0.75: return "static:smile-closed"
        case ..<0.83: return "static:confident"
        case ..<0.91: return "static:notes"
        case ..<0.96: return "static:knock"
        default: return "waving"
        }
    }

    private var roamingRect: CGRect {
        let minX = max(allowedRect.minX, anchor.x - 110)
        let maxX = min(allowedRect.maxX, anchor.x + 110)
        let minY = max(allowedRect.minY, anchor.y - 30)
        let maxY = min(allowedRect.maxY, anchor.y + 30)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private mutating func beginJourney(now: TimeInterval) {
        let bounds = roamingRect
        var destination = currentOrigin
        for _ in 0..<6 {
            // Leave some room for a gentle vertical float where the display
            // allows it. Final clamping also handles tiny or edge-bound areas.
            let verticalInset = min(4, bounds.height / 2)
            destination = CGPoint(x: random.value(Double(bounds.minX), Double(bounds.maxX)),
                                  y: random.value(Double(bounds.minY + verticalInset), Double(bounds.maxY - verticalInset)))
            if distance(currentOrigin, destination) >= 18 { break }
        }
        let length = distance(currentOrigin, destination)
        guard length >= 12 else {
            nextJourneyAt = now + random.value(8, 16)
            return
        }
        let duration = min(6, max(2, Double(length) / random.value(25, 40)))
        journey = Journey(from: currentOrigin, to: destination, startedAt: now,
                          duration: duration, frequency: random.value(1.25, 1.65),
                          amplitude: CGFloat(random.value(3, 4)))
    }

    private func position(on journey: Journey, progress: Double) -> CGPoint {
        let eased = progress * progress * (3 - 2 * progress)
        // Squaring the envelope gives zero displacement and velocity at both
        // ends, avoiding a visible step when the standing cutout stops.
        let envelope = pow(sin(.pi * progress), 2)
        let bob = journey.amplitude * CGFloat(sin(2 * .pi * journey.frequency * journey.duration * progress) * envelope)
        let point = CGPoint(x: journey.from.x + (journey.to.x - journey.from.x) * eased,
                            y: journey.from.y + (journey.to.y - journey.from.y) * eased + bob)
        return clamp(point, to: roamingRect)
    }

    private func distance(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
        hypot(left.x - right.x, left.y - right.y)
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x.isFinite ? point.x : rect.minX, rect.minX), rect.maxX),
                y: min(max(point.y.isFinite ? point.y : rect.minY, rect.minY), rect.maxY))
    }

    private static func validRect(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return .zero }
        return CGRect(x: rect.origin.x, y: rect.origin.y,
                      width: max(0, rect.width), height: max(0, rect.height))
    }

    /// Deterministic behavioral checks, independent of AppKit or wall time.
    static func selfTest() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.IdleBehavior", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let legal = CGRect(x: -400, y: 20, width: 800, height: 500)
        let home = CGPoint(x: 0, y: 50)
        var behavior = IdleBehavior(seed: 42)
        behavior.reset(now: 0, origin: home, allowedRect: legal)
        let initial = behavior.update(now: 0, eligible: true, posesEnabled: true,
                                      wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(initial.pose == "idle" && initial.origin == nil, "Idle start should restore a neutral pose without moving")
        var sawMove = false
        var sawPose = false
        var neutralFrames = 0
        let permitted = Set(["idle", "static:smile", "static:smile-closed", "static:confident", "static:notes", "static:knock", "waving"])
        for step in 1...14_400 {
            let now = Double(step) / 24
            let output = behavior.update(now: now, eligible: true, posesEnabled: true,
                                         wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            if let origin = output.origin {
                sawMove = true
                try require(origin.x >= legal.minX && origin.x <= legal.maxX && origin.y >= legal.minY && origin.y <= legal.maxY,
                            "A stroll left legal window origins")
                try require(abs(origin.x - home.x) <= 110.0001 && abs(origin.y - home.y) <= 30.0001,
                            "A stroll drifted out of its home range")
            }
            if let pose = output.pose {
                try require(permitted.contains(pose), "Idle emitted an error or unsupported pose")
                if pose != "idle" { sawPose = true }
            }
            if behavior.currentPose == "idle" { neutralFrames += 1 }
            try require(behavior.anchor == home, "A stroll moved its own home anchor")
        }
        try require(sawMove && sawPose, "A seeded idle session did not exercise both behavior types")
        try require(neutralFrames > 7_200, "Idle should spend most of its time in a neutral pose")

        // The exact same seed and timeline must replay the same visible output.
        var replayA = IdleBehavior(seed: 17)
        var replayB = IdleBehavior(seed: 17)
        replayA.reset(now: 0, origin: home, allowedRect: legal)
        replayB.reset(now: 0, origin: home, allowedRect: legal)
        for step in 0...1_200 {
            let now = Double(step) / 24
            let a = replayA.update(now: now, eligible: true, posesEnabled: true, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            let b = replayB.update(now: now, eligible: true, posesEnabled: true, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            try require(a.origin == b.origin && a.pose == b.pose, "Seeded behavior is not reproducible")
        }

        // Exercise actual journeys' endpoints and the internal bob envelope.
        let journey = Journey(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 60),
                              startedAt: 0, duration: 4, frequency: 1.45, amplitude: 3.5)
        try require(behavior.distance(behavior.position(on: journey, progress: 0), journey.from) < 0.0001,
                    "Movement starts with a bob offset")
        try require(behavior.distance(behavior.position(on: journey, progress: 1), journey.to) < 0.0001,
                    "Movement ends with a bob offset")
        var sawBob = false
        for step in 1..<100 {
            let progress = Double(step) / 100
            let eased = progress * progress * (3 - 2 * progress)
            let baseline = journey.from.y + (journey.to.y - journey.from.y) * eased
            let displacement = abs(behavior.position(on: journey, progress: progress).y - baseline)
            try require(displacement <= 4.0001, "The vertical float exceeded its gentle amplitude")
            if displacement > 1 { sawBob = true }
        }
        try require(sawBob, "Movement has no visible vertical float")

        // Ineligible / hover / reduced-motion updates cannot override the app's
        // task expression, and resuming cannot snap the window to its anchor.
        let before = behavior.currentOrigin
        let blocked = behavior.update(now: 600.05, eligible: false, posesEnabled: true, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(blocked.origin == nil && blocked.pose == nil && behavior.currentOrigin == before, "Busy state emitted an idle action")
        let resumed = behavior.update(now: 600.10, eligible: true, posesEnabled: true, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(resumed.origin == nil && resumed.pose == "idle" && behavior.currentOrigin == before, "Resuming idle snapped the character")
        for (motion, hover) in [(true, false), (false, true)] {
            let output = behavior.update(now: 600.15, eligible: true, posesEnabled: true, wanderingEnabled: true, reduceMotion: motion, pointerNear: hover)
            try require(output.origin == nil && output.pose == nil && behavior.currentOrigin == before, "Reduced motion or pointer proximity did not suspend idle")
        }

        // Jump forward while actually walking: do not catch up to a destination.
        var sleeping = IdleBehavior(seed: 8)
        sleeping.reset(now: 0, origin: home, allowedRect: legal)
        var time: TimeInterval = 0
        while !sleeping.isWandering && time < 60 {
            _ = sleeping.update(now: time, eligible: true, posesEnabled: false, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            time += 1.0 / 24
        }
        try require(sleeping.isWandering, "Sleep test did not start a journey")
        _ = sleeping.update(now: time + 0.25, eligible: true, posesEnabled: false, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        let sleepOrigin = sleeping.currentOrigin
        let woke = sleeping.update(now: time + 120, eligible: true, posesEnabled: false, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(woke.origin == nil && !sleeping.isWandering && sleeping.currentOrigin == sleepOrigin && sleeping.anchor == home,
                    "Waking from sleep teleported or shifted home")

        // Even a display too small to allow movement must stay finite and idle.
        var tiny = IdleBehavior(seed: 3)
        tiny.reset(now: 0, origin: CGPoint(x: 99, y: 99), allowedRect: CGRect(x: 7, y: -5, width: 0, height: 0))
        for step in 0...1_000 {
            _ = tiny.update(now: Double(step) / 24, eligible: true, posesEnabled: false,
                            wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        }
        try require(tiny.currentOrigin == CGPoint(x: 7, y: -5) && !tiny.isWandering, "Degenerate screen bounds produced movement")
    }
}
