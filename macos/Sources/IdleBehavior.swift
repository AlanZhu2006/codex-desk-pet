import Foundation
import CoreGraphics

/// Small, local idle actions. This value type owns no windows, timers or disk
/// state; callers supply monotonic time and decide when idling is appropriate.
struct IdleBehavior {
    struct Output {
        let origin: CGPoint?
        /// `idle` restores neutral; `static:name` selects a portrait clip.
        let pose: String?

        static let none = Output(origin: nil, pose: nil)
    }

    private struct Journey {
        let from: CGPoint
        let to: CGPoint
        let startedAt: TimeInterval
        let duration: TimeInterval
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
    private static let idlePoses = ["static:smile-closed", "static:confident", "static:notes", "static:knock",
                                    "static:guilty", "static:stone", "static:confetti"]
    private var lastChosenPose: String?
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
        lastChosenPose = nil
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
        let clockReversed = lastUpdateAt.map { now < $0 } ?? false
        let timeJumped = lastUpdateAt.map { now < $0 || now - $0 > 1 } ?? false
        lastUpdateAt = now
        let canIdle = eligible && !reduceMotion

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
        // of a journey. Preserve the expression deadline on forward jumps:
        // throttled timers may keep arriving more than a second apart. Moving
        // that deadline on every such tick would starve expressions forever.
        // An overdue pose is selected once below, with its next deadline based
        // on now, so waking never replays a backlog of missed expressions.
        if timeJumped {
            journey = nil
            nextJourneyAt = max(nextJourneyAt, now + 2)
            if clockReversed {
                poseUntil = nil
                schedule(after: now)
                let pose = currentPose == "idle" ? nil : "idle"
                currentPose = "idle"
                previousPosesEnabled = posesEnabled
                previousWanderingEnabled = wanderingEnabled
                return Output(origin: nil, pose: pose)
            }
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

        // Being nearby should make the companion easy to grab, without
        // restarting its expression clock every time the pointer passes it.
        // Keep poses alive; stop only window movement and leave a short grace
        // period after the pointer departs before another stroll may begin.
        if pointerNear {
            journey = nil
            nextJourneyAt = max(nextJourneyAt, now + 2)
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
            // Stone's 3.42-second clip needs enough time to finish one loop.
            let minimumDuration = pose == "static:stone" ? 3.5 : 2.5
            poseUntil = now + random.value(minimumDuration, 4.5)
        }

        if wanderingEnabled && !pointerNear && journey == nil && currentPose == "idle" && now >= nextJourneyAt {
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
        // Returning to neutral must not forget the previous expressive pose.
        // All remaining portraits have equal odds, with a reproducible RNG.
        let choices = Self.idlePoses.filter { $0 != lastChosenPose }
        let pose = choices[Int(random.unit() * Double(choices.count))]
        lastChosenPose = pose
        return pose
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
            destination = CGPoint(x: random.value(Double(bounds.minX), Double(bounds.maxX)),
                                  y: random.value(Double(bounds.minY), Double(bounds.maxY)))
            if distance(currentOrigin, destination) >= 18 { break }
        }
        let length = distance(currentOrigin, destination)
        guard length >= 12 else {
            nextJourneyAt = now + random.value(8, 16)
            return
        }
        let duration = min(6, max(2, Double(length) / random.value(25, 40)))
        journey = Journey(from: currentOrigin, to: destination, startedAt: now,
                          duration: duration)
    }

    private func position(on journey: Journey, progress: Double) -> CGPoint {
        let eased = progress * progress * (3 - 2 * progress)
        // The portrait renderer supplies fixed-foot breathing and spring.
        // The window itself follows only this gentle eased path, without a
        // second vertical oscillation that would make the whole pet float.
        let point = CGPoint(x: journey.from.x + (journey.to.x - journey.from.x) * eased,
                            y: journey.from.y + (journey.to.y - journey.from.y) * eased)
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
        let expressivePoses = Set(["static:smile-closed", "static:confident", "static:notes", "static:knock",
                                   "static:guilty", "static:stone", "static:confetti"])
        let permitted = expressivePoses.union(["idle"])
        var seenPoses = Set<String>()
        var previousExpressivePose: String?
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
                if pose != "idle" {
                    sawPose = true
                    seenPoses.insert(pose)
                    try require(pose != previousExpressivePose, "Returning to neutral allowed a repeated random expression")
                    previousExpressivePose = pose
                    let minimumDuration = pose == "static:stone" ? 3.5 : 2.5
                    try require(behavior.poseUntil.map { $0 >= now + minimumDuration && $0 <= now + 4.5 } == true,
                                "An idle expression's display duration is incorrect")
                }
            }
            if behavior.currentPose == "idle" { neutralFrames += 1 }
            try require(behavior.anchor == home, "A stroll moved its own home anchor")
        }
        try require(sawMove && sawPose, "A seeded idle session did not exercise both behavior types")
        try require(seenPoses == expressivePoses, "A seeded idle session did not show all seven distinct expressions")
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

        // A stroll must ease between its endpoints without adding an unrelated
        // window bounce; body elasticity belongs to the portrait renderer.
        let journey = Journey(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 60),
                              startedAt: 0, duration: 4)
        try require(behavior.distance(behavior.position(on: journey, progress: 0), journey.from) < 0.0001,
                    "Movement starts away from its visible location")
        try require(behavior.distance(behavior.position(on: journey, progress: 1), journey.to) < 0.0001,
                    "Movement does not settle at its destination")
        var previous = journey.from
        for step in 1..<100 {
            let progress = Double(step) / 100
            let point = behavior.position(on: journey, progress: progress)
            try require(point.x >= previous.x && point.y >= previous.y,
                        "A simple stroll reverses vertically or horizontally")
            try require(point.x <= journey.to.x && point.y <= journey.to.y,
                        "A stroll overshoots its destination")
            previous = point
        }

        // Ineligible / reduced-motion updates cannot override the app's task
        // expression, and resuming cannot snap the window to its anchor.
        let before = behavior.currentOrigin
        let blocked = behavior.update(now: 600.05, eligible: false, posesEnabled: true, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(blocked.origin == nil && blocked.pose == nil && behavior.currentOrigin == before, "Busy state emitted an idle action")
        let resumed = behavior.update(now: 600.10, eligible: true, posesEnabled: true, wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(resumed.origin == nil && resumed.pose == "idle" && behavior.currentOrigin == before, "Resuming idle snapped the character")
        let reduced = behavior.update(now: 600.15, eligible: true, posesEnabled: true,
                                      wanderingEnabled: true, reduceMotion: true, pointerNear: false)
        try require(reduced.origin == nil && reduced.pose == nil && behavior.currentOrigin == before,
                    "Reduced motion did not suspend idle")

        // Pointer proximity may stop the window, but must never starve the
        // expression clock. Without strolling, the exact pose schedule should
        // match whether the pointer stays near, passes every four seconds, or
        // stays away entirely.
        var away = IdleBehavior(seed: 42)
        var near = IdleBehavior(seed: 42)
        var passing = IdleBehavior(seed: 42)
        away.reset(now: 0, origin: home, allowedRect: legal)
        near.reset(now: 0, origin: home, allowedRect: legal)
        passing.reset(now: 0, origin: home, allowedRect: legal)
        var hoverPoses = 0
        for tick in 0...2_880 {
            let now = Double(tick) / 24
            let a = away.update(now: now, eligible: true, posesEnabled: true,
                                wanderingEnabled: false, reduceMotion: false, pointerNear: false)
            let n = near.update(now: now, eligible: true, posesEnabled: true,
                                wanderingEnabled: false, reduceMotion: false, pointerNear: true)
            let p = passing.update(now: now, eligible: true, posesEnabled: true,
                                   wanderingEnabled: false, reduceMotion: false, pointerNear: tick % 96 == 0)
            try require(n.pose == a.pose && p.pose == a.pose, "Hover restarted or starved the expression schedule")
            try require(n.origin == nil && p.origin == nil, "A nearby pointer moved the window")
            if let pose = n.pose, pose != "idle" { hoverPoses += 1 }
        }
        try require(hoverPoses >= 8, "Hovering did not show regular visible expressions")

        // With roaming enabled, a long hover still shows expressions, never
        // moves, and leaves at least two seconds to grab the pet after leaving.
        var hovering = IdleBehavior(seed: 19)
        hovering.reset(now: 0, origin: home, allowedRect: legal)
        var roamingHoverPoses = 0
        for tick in 0...2_880 {
            let output = hovering.update(now: Double(tick) / 24, eligible: true, posesEnabled: true,
                                         wanderingEnabled: true, reduceMotion: false, pointerNear: true)
            try require(output.origin == nil && hovering.currentOrigin == home,
                        "A stroll continued under the pointer")
            if let pose = output.pose, pose != "idle" { roamingHoverPoses += 1 }
        }
        try require(roamingHoverPoses >= 8, "Roaming mode starved expressions while hovered")
        for tick in 1...48 {
            let output = hovering.update(now: 120 + Double(tick) / 24, eligible: true, posesEnabled: true,
                                         wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            try require(output.origin == nil, "The window moved before its two-second pointer grace period")
        }
        var resumedWalking = false
        for tick in 49...1_440 {
            let output = hovering.update(now: 120 + Double(tick) / 24, eligible: true, posesEnabled: true,
                                         wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            if output.origin != nil { resumedWalking = true }
        }
        try require(resumedWalking && hovering.anchor == home,
                    "Leaving the pointer did not resume local roaming from the same anchor")

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

        // A throttled run loop is not a new sleep/wake cycle on every tick.
        // Expressions still run at their ordinary deadlines, while stale
        // window journeys remain cancelled instead of jumping between frames.
        var throttled = IdleBehavior(seed: 42)
        throttled.reset(now: 0, origin: home, allowedRect: legal)
        var slowPoses = 0
        var slowPoseStartedAt: TimeInterval?
        for tick in 0...109 {
            let now = Double(tick) * 1.1
            let output = throttled.update(now: now, eligible: true, posesEnabled: true,
                                          wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            try require(output.origin == nil && throttled.currentOrigin == home,
                        "A throttled tick advanced a stale window journey")
            if let pose = output.pose, pose != "idle" {
                slowPoses += 1
                slowPoseStartedAt = now
                try require(throttled.nextPoseAt >= now + 6 && throttled.nextPoseAt <= now + 12,
                            "A throttled pose changed the normal expression interval")
                let minimumDuration = pose == "static:stone" ? 3.5 : 2.5
                try require(throttled.poseUntil.map { $0 >= now + minimumDuration && $0 <= now + 4.5 } == true,
                            "A throttled pose changed the normal display duration")
            } else if output.pose == "idle", let started = slowPoseStartedAt {
                try require(now - started >= 2.5 && now - started <= 5.6,
                            "A delayed callback cut short or lost an expression's return to idle")
                slowPoseStartedAt = nil
            }
        }
        try require(slowPoses >= 8, "Repeated 1.1-second timer delays starved idle expressions")

        // One long gap can choose one overdue expression, but cannot catch up
        // a journey or immediately replay several missed expression cycles.
        var gap = IdleBehavior(seed: 8)
        gap.reset(now: 0, origin: home, allowedRect: legal)
        var gapTime: TimeInterval = 0
        while !gap.isWandering && gapTime < 60 {
            _ = gap.update(now: gapTime, eligible: true, posesEnabled: true,
                           wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            gapTime += 1.0 / 24
        }
        try require(gap.isWandering, "Expression wake test did not start a journey")
        let gapOrigin = gap.currentOrigin
        let wakeTime = gapTime + 120
        let gapOutput = gap.update(now: wakeTime, eligible: true, posesEnabled: true,
                                   wanderingEnabled: true, reduceMotion: false, pointerNear: false)
        try require(gapOutput.origin == nil && !gap.isWandering && gap.currentOrigin == gapOrigin && gap.anchor == home,
                    "An expression wake caught up a stale window journey")
        try require(gapOutput.pose.map { $0 != "idle" && permitted.contains($0) } == true &&
                    gap.nextPoseAt >= wakeTime + 6 && gap.nextPoseAt <= wakeTime + 12,
                    "An overdue expression did not restart one normal cycle on wake")
        for tick in 1...143 {
            let output = gap.update(now: wakeTime + Double(tick) / 24, eligible: true, posesEnabled: true,
                                    wanderingEnabled: true, reduceMotion: false, pointerNear: false)
            try require(output.pose == nil || output.pose == "idle", "Waking replayed a backlog of missed expressions")
            if tick <= 48 {
                try require(output.origin == nil, "Waking bypassed the movement grace period")
            }
        }

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
