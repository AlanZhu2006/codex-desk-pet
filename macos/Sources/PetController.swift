import AppKit
import ImageIO

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PetFrame {
    let image: NSImage
    let pixels: NSBitmapImageRep

    init(_ image: CGImage) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.pixels = NSBitmapImageRep(cgImage: image)
    }
}

private struct PetAnimation {
    let frames: [PetFrame]
    let durations: [TimeInterval]
}

private struct AtlasMetadata: Decodable {
    struct Animation: Decodable {
        let row: Int
        let state: String
        let frames: Int
        let durationMs: [Double]
    }
    let cellWidth: Int
    let cellHeight: Int
    let columns: Int
    let rows: Int
    let width: Int
    let height: Int
    let frameCount: Int
    let animations: [Animation]
}

private final class PetView: NSView {
    var sprite: PetFrame? { didSet { needsDisplay = true } }
    var spriteHeight: CGFloat = 208
    var bubble: String? { didSet { needsDisplay = true } }
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    var spriteRect: NSRect {
        guard let sprite else { return .zero }
        let size = sprite.image.size
        let scale = min((bounds.width - 8) / max(size.width, 1), spriteHeight / max(size.height, 1))
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: height)
    }

    func containsVisiblePixel(at point: NSPoint) -> Bool {
        guard let sprite, spriteRect.contains(point) else { return false }
        let rect = spriteRect
        let x = min(sprite.pixels.pixelsWide - 1, max(0, Int((point.x - rect.minX) / rect.width * CGFloat(sprite.pixels.pixelsWide))))
        // Bitmap rows start at the top; AppKit view coordinates start at the bottom.
        let y = min(sprite.pixels.pixelsHigh - 1, max(0, Int((rect.maxY - point.y) / rect.height * CGFloat(sprite.pixels.pixelsHigh))))
        return (sprite.pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.10
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        sprite?.image.draw(in: spriteRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        guard let bubble, !bubble.isEmpty else { return }
        let rect = NSRect(x: 8, y: spriteHeight + 7, width: bounds.width - 16, height: 29)
        NSColor(calibratedWhite: 0.99, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedRed: 0.87, green: 0.68, blue: 0.46, alpha: 0.65).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.32, green: 0.22, blue: 0.18, alpha: 1),
            .paragraphStyle: paragraph
        ]
        (bubble as NSString).draw(in: rect.insetBy(dx: 8, dy: 6), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
    override func otherMouseDown(with event: NSEvent) { onContextMenu?(event) }
}

/// A local, non-activating companion. Construct and call it from the main thread.
final class PetController: NSObject, NSMenuDelegate {
    private let resources: URL
    private let defaults = UserDefaults.standard
    private let panel: PetPanel
    private let petView: PetView
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var animations: [String: PetAnimation] = [:]
    private var expressions: [String: PetFrame] = [:]
    private var currentAnimation = "idle"
    private var frameIndex = 0
    private var nextFrameTime: TimeInterval = 0
    private var bubbleUntil: TimeInterval = 0
    private var manualExpression: String?
    private var lastActivityState = "idle"
    private var isDragging = false
    private var dragMouseOrigin = NSPoint.zero
    private var dragWindowOrigin = NSPoint.zero
    private var isHidden = false
    private var paused = false
    private var staysOnTop = true
    private var currentSize: CGFloat = 208
    private var idleBehavior = IdleBehavior()
    private var idleExpressionsEnabled = true
    private var idleWanderingEnabled = true
    private var menuOpen = false

    private let expressionOptions: [(String, String)] = [
        ("smile", "微笑"), ("smile-closed", "眯眼笑"), ("typing", "敲键盘"),
        ("notes", "看笔记"), ("knock", "敲敲你"), ("confetti", "撒花"),
        ("panic", "慌张"), ("guilty", "委屈"), ("stone", "石化"),
        ("confident", "自信"), ("crying", "大哭")
    ]

    init(resources: URL) {
        self.resources = resources
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 224, height: 252))
        panel = PetPanel(contentRect: petView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        precondition(Thread.isMainThread)
        loadArtwork()
        configurePanel()
        configureInteraction()
        menu.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        if [156.0, 208.0, 280.0].contains(defaults.double(forKey: "petSize")) {
            currentSize = CGFloat(defaults.double(forKey: "petSize"))
        }
        paused = defaults.bool(forKey: "petPaused")
        idleExpressionsEnabled = defaults.object(forKey: "idleExpressions") == nil ? true : defaults.bool(forKey: "idleExpressions")
        idleWanderingEnabled = defaults.object(forKey: "idleWandering") == nil ? true : defaults.bool(forKey: "idleWandering")
        staysOnTop = defaults.object(forKey: "petOnTop") == nil ? true : defaults.bool(forKey: "petOnTop")
        resizePet(to: currentSize, persist: false)
        panel.level = staysOnTop ? .floating : .normal
        restorePosition()
        resetIdleBehavior()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Claude 娘桌宠")
            button.image?.isTemplate = true
            button.toolTip = "Claude 娘桌宠 · 右键角色可切换表情"
        }
        item.menu = menu
        statusItem = item
        setAnimation("idle", force: true)
        showBubble("待机时会自己玩一会儿", seconds: 5)
        panel.orderFrontRegardless()
        let newTimer = Timer(timeInterval: 1.0 / 24.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
        tick()
    }

    func applyActivity(state: String, text: String) {
        precondition(Thread.isMainThread)
        // Deliberately derive the bubble from a small vocabulary. Paths, prompts,
        // tool arguments, and other user content never appear on the desktop.
        _ = text
        lastActivityState = state
        guard manualExpression == nil && !isDragging else { return }
        applyAutomaticState(state)
    }

    private func configurePanel() {
        panel.contentView = petView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.title = "Claude 娘桌宠"
        petView.setAccessibilityElement(true)
        petView.setAccessibilityRole(.image)
        petView.setAccessibilityLabel("Claude 娘桌宠")
    }

    private func configureInteraction() {
        petView.onMouseDown = { [weak self] event in
            guard let self else { return }
            if event.clickCount == 2 {
                self.isDragging = false
                self.openCodex()
                return
            }
            self.isDragging = true
            self.dragMouseOrigin = NSEvent.mouseLocation
            self.dragWindowOrigin = self.panel.frame.origin
            self.panel.ignoresMouseEvents = false
        }
        petView.onMouseDragged = { [weak self] _ in
            guard let self, self.isDragging else { return }
            let mouse = NSEvent.mouseLocation
            // Translate the whole cutout while preserving its current expression.
            // Dragging does not replace a standing pose with a running gait.
            let origin = NSPoint(x: self.dragWindowOrigin.x + mouse.x - self.dragMouseOrigin.x,
                                 y: self.dragWindowOrigin.y + mouse.y - self.dragMouseOrigin.y)
            self.panel.setFrameOrigin(self.clampedOrigin(origin, size: self.panel.frame.size, preferPointerScreen: true))
        }
        petView.onMouseUp = { [weak self] _ in
            guard let self else { return }
            self.isDragging = false
            if self.manualExpression == nil { self.applyAutomaticState(self.lastActivityState) }
            self.savePosition()
            self.resetIdleBehavior()
            self.updateClickThrough()
        }
        petView.onContextMenu = { [weak self] event in
            guard let self else { return }
            self.isDragging = false
            NSMenu.popUpContextMenu(self.menu, with: event, for: self.petView)
        }
    }

    private static func readImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func cropCell(atlas: CGImage, metadata: AtlasMetadata, row: Int, column: Int) -> CGImage? {
        guard row >= 0, column >= 0, row < metadata.rows, column < metadata.columns else { return nil }
        // CGImage cropping uses the PNG's top-left origin; row zero is idle.
        let rect = CGRect(x: column * metadata.cellWidth, y: row * metadata.cellHeight,
                          width: metadata.cellWidth, height: metadata.cellHeight)
        guard rect.maxX <= CGFloat(atlas.width), rect.maxY <= CGFloat(atlas.height) else { return nil }
        return atlas.cropping(to: rect)
    }

    private static func framedPortrait(_ image: CGImage) -> CGImage? {
        // Match the atlas's character height and foot baseline. Raw portraits
        // are tightly cropped, so drawing them at cell height would make the
        // character grow each time an idle expression changes.
        guard let context = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(174 / CGFloat(image.height), 160 / CGFloat(image.width))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (192 - size.width) / 2, y: 6, width: size.width, height: size.height))
        return context.makeImage()
    }

    private func loadArtwork() {
        for (name, _) in expressionOptions {
            if let image = Self.readImage(resources.appendingPathComponent("sprites/\(name).png")),
               let framed = Self.framedPortrait(image) {
                expressions[name] = PetFrame(framed)
            }
        }
        guard let atlas = Self.readImage(resources.appendingPathComponent("Atlas.png")),
              let data = try? Data(contentsOf: resources.appendingPathComponent("animation.json")),
              let metadata = try? JSONDecoder().decode(AtlasMetadata.self, from: data),
              metadata.cellWidth > 0, metadata.cellHeight > 0, metadata.columns > 0 else { return }
        for description in metadata.animations where description.frames > 0 && description.row >= 0 {
            var frames: [PetFrame] = []
            var durations: [TimeInterval] = []
            for index in 0..<min(description.frames, metadata.columns) {
                guard let image = Self.cropCell(atlas: atlas, metadata: metadata, row: description.row, column: index) else { continue }
                frames.append(PetFrame(image))
                let milliseconds = index < description.durationMs.count ? description.durationMs[index] : 160
                durations.append(max(0.04, milliseconds / 1000))
            }
            if !frames.isEmpty { animations[description.state] = PetAnimation(frames: frames, durations: durations) }
        }
    }

    /// Validate the exact bundled resources and the same top-origin crops used
    /// for rendering, without constructing or launching a desktop window.
    static func selfTest(resources: URL) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func maximumAlpha(_ image: CGImage) -> Double {
            let pixels = NSBitmapImageRep(cgImage: image)
            guard pixels.hasAlpha else { return 1 }
            if pixels.bitsPerSample == 8 && !pixels.isPlanar,
               let data = pixels.bitmapData, pixels.samplesPerPixel >= 2 {
                let offset = pixels.bitmapFormat.contains(.alphaFirst) ? 0 : pixels.samplesPerPixel - 1
                var maximum: UInt8 = 0
                for y in 0..<pixels.pixelsHigh {
                    for x in 0..<pixels.pixelsWide {
                        maximum = max(maximum, data[y * pixels.bytesPerRow + x * pixels.samplesPerPixel + offset])
                        if maximum == 255 { return 1 }
                    }
                }
                return Double(maximum) / 255
            }
            var maximum = 0.0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    maximum = max(maximum, Double(pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0))
                    if maximum >= 1 { return 1 }
                }
            }
            return maximum
        }

        try require(Thread.isMainThread, "桌宠资源自检必须在主线程运行")
        guard let atlas = readImage(resources.appendingPathComponent("Atlas.png")) else {
            throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法加载 Atlas.png"])
        }
        let metadata = try JSONDecoder().decode(AtlasMetadata.self, from: Data(contentsOf: resources.appendingPathComponent("animation.json")))
        try require(metadata.columns == 8 && metadata.rows == 9, "图集必须是 8 列 × 9 行")
        try require(metadata.cellWidth == 192 && metadata.cellHeight == 208, "图集单格尺寸不符")
        try require(metadata.width == atlas.width && metadata.height == atlas.height &&
                    metadata.width == metadata.columns * metadata.cellWidth && metadata.height == metadata.rows * metadata.cellHeight,
                    "图集尺寸与元数据不一致")
        let expected: [String: (Int, Int)] = [
            "idle": (0, 6), "running-right": (1, 8), "running-left": (2, 8),
            "waving": (3, 4), "jumping": (4, 5), "failed": (5, 8),
            "waiting": (6, 6), "running": (7, 6), "review": (8, 6)
        ]
        try require(metadata.animations.count == expected.count, "应有 9 组动画")
        var used = Set<Int>()
        var states = Set<String>()
        for animation in metadata.animations {
            guard let specification = expected[animation.state] else {
                throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "未知动画：\(animation.state)"])
            }
            try require(states.insert(animation.state).inserted, "动画状态重复")
            try require(animation.row == specification.0 && animation.frames == specification.1, "动画行或帧数不符：\(animation.state)")
            try require(animation.durationMs.count == animation.frames && animation.durationMs.allSatisfy { $0.isFinite && $0 > 0 }, "动画时长不完整：\(animation.state)")
            for column in 0..<animation.frames {
                used.insert(animation.row * metadata.columns + column)
            }
        }
        try require(used.count == 57 && metadata.frameCount == 57, "应有 57 个使用中的动画格")
        var unusedCount = 0
        for row in 0..<metadata.rows {
            for column in 0..<metadata.columns {
                guard let image = cropCell(atlas: atlas, metadata: metadata, row: row, column: column) else {
                    throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法裁切图集格子"])
                }
                let alpha = maximumAlpha(image)
                if used.contains(row * metadata.columns + column) {
                    try require(alpha > 0.1, "动画格为空：第 \(row) 行，第 \(column) 列")
                } else {
                    unusedCount += 1
                    try require(alpha == 0, "未使用的图集格并非全透明：第 \(row) 行，第 \(column) 列")
                }
            }
        }
        try require(unusedCount == 15, "应有 15 个透明空格")
        for name in ["smile", "smile-closed", "typing", "notes", "knock", "confetti", "panic", "guilty", "stone", "confident", "crying"] {
            guard let image = readImage(resources.appendingPathComponent("sprites/\(name).png")) else {
                throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法加载原版表情：\(name)"])
            }
            try require(image.width > 0 && image.height > 0 && maximumAlpha(image) > 0.1, "原版表情为空：\(name)")
            guard let framed = framedPortrait(image) else {
                throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "表情对齐失败：\(name)"])
            }
            try require(framed.width == 192 && framed.height == 208 && maximumAlpha(framed) > 0.1, "表情对齐尺寸或像素不符：\(name)")
        }

        // Exercise the real hit-testing transform at both a transparent corner
        // and an opaque character pixel, including the bitmap/view Y inversion.
        guard let idleImage = cropCell(atlas: atlas, metadata: metadata, row: 0, column: 0) else { return }
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 224, height: 252))
        view.sprite = PetFrame(idleImage)
        let pixels = view.sprite!.pixels
        let rect = view.spriteRect
        func viewPoint(x: Int, y: Int) -> NSPoint {
            NSPoint(x: rect.minX + (CGFloat(x) + 0.5) / CGFloat(pixels.pixelsWide) * rect.width,
                    y: rect.maxY - (CGFloat(y) + 0.5) / CGFloat(pixels.pixelsHigh) * rect.height)
        }
        try require((pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 0) <= 0.1, "首帧左上角应透明")
        try require(!view.containsVisiblePixel(at: viewPoint(x: 0, y: 0)), "透明角落应穿透")
        try require(!view.containsVisiblePixel(at: NSPoint(x: -1, y: -1)), "角色矩形外应穿透")
        var testedBody = false
        outer: for y in 0..<pixels.pixelsHigh {
            for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 {
                try require(view.containsVisiblePixel(at: viewPoint(x: x, y: y)), "人物内部像素应可交互")
                testedBody = true
                break outer
            }
        }
        try require(testedBody, "首帧没有不透明的人物像素")
        try IdleBehavior.selfTest()
    }

    private func applyAutomaticState(_ state: String) {
        let animation: String
        let bubble: String
        switch state {
        case "tool", "working", "running", "typing": animation = "running"; bubble = "正在写代码"
        case "reading", "review": animation = "review"; bubble = "正在阅读"
        case "thinking": animation = "review"; bubble = "让我想一想"
        case "waiting", "approval", "input": animation = "waiting"; bubble = "等你回复"
        case "celebrate", "complete", "completed", "success", "jumping": animation = "jumping"; bubble = "完成啦！"
        case "crying", "failed", "error": animation = "failed"; bubble = "呜呜，没成功"
        case "panic":
            showStatic("panic"); showBubble("有点慌张", seconds: 6); return
        case "aborted", "interrupted", "guilty":
            showStatic("guilty"); showBubble("等你再叫我", seconds: 6); return
        case "stone":
            showStatic("stone"); showBubble("让我缓一缓", seconds: 6); return
        default: animation = "idle"; bubble = "准备好啦"
        }
        let changed = currentAnimation != animation || manualExpression != nil
        setAnimation(animation)
        if changed { showBubble(bubble, seconds: 6) }
    }

    private func setAnimation(_ name: String, force: Bool = false) {
        if !force && currentAnimation == name { return }
        currentAnimation = name
        frameIndex = 0
        if let animation = animations[name], let first = animation.frames.first {
            petView.sprite = first
            nextFrameTime = ProcessInfo.processInfo.systemUptime + animation.durations[0]
        } else {
            petView.sprite = expressions[name == "failed" ? "crying" : "smile"]
            nextFrameTime = .greatestFiniteMagnitude
        }
    }

    private func showStatic(_ name: String) {
        currentAnimation = "static:\(name)"
        if let frame = expressions[name] { petView.sprite = frame }
        nextFrameTime = .greatestFiniteMagnitude
    }

    private func showBubble(_ message: String, seconds: TimeInterval) {
        petView.bubble = String(message.prefix(18))
        bubbleUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let idle = idleBehavior.update(now: now,
                                       eligible: lastActivityState == "idle" && manualExpression == nil && !isDragging && !paused && !isHidden && !menuOpen,
                                       posesEnabled: idleExpressionsEnabled,
                                       wanderingEnabled: idleWanderingEnabled,
                                       reduceMotion: reduceMotion,
                                       pointerNear: pointerNearPet())
        if let origin = idle.origin { panel.setFrameOrigin(origin) }
        if let pose = idle.pose {
            if pose.hasPrefix("static:") { showStatic(String(pose.dropFirst(7))) }
            else { setAnimation(pose) }
        }
        if !paused && !isHidden && !reduceMotion, now >= nextFrameTime, let animation = animations[currentAnimation] {
            frameIndex = (frameIndex + 1) % animation.frames.count
            petView.sprite = animation.frames[frameIndex]
            nextFrameTime = now + animation.durations[frameIndex]
        }
        if petView.bubble != nil && now >= bubbleUntil { petView.bubble = nil }
        updateClickThrough()
    }

    private func pointerNearPet() -> Bool {
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = petView.convert(windowPoint, from: nil)
        return petView.spriteRect.insetBy(dx: -16, dy: -16).contains(point)
    }

    private func idleAllowedRect() -> CGRect {
        let candidate = panel.frame
        let screen = NSScreen.screens.max { a, b in
            let left = a.visibleFrame.intersection(candidate)
            let right = b.visibleFrame.intersection(candidate)
            return max(0, left.width) * max(0, left.height) < max(0, right.width) * max(0, right.height)
        }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? candidate
        return CGRect(x: visible.minX, y: visible.minY,
                      width: max(0, visible.width - candidate.width),
                      height: max(0, visible.height - candidate.height))
    }

    private func resetIdleBehavior() {
        idleBehavior.reset(now: ProcessInfo.processInfo.systemUptime, origin: panel.frame.origin, allowedRect: idleAllowedRect())
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { menuOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuOpen = false }
    }

    private func updateClickThrough() {
        if isDragging { panel.ignoresMouseEvents = false; return }
        guard !isHidden else { panel.ignoresMouseEvents = true; return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let viewPoint = petView.convert(windowPoint, from: nil)
        panel.ignoresMouseEvents = !petView.containsVisiblePixel(at: viewPoint)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let title = NSMenuItem(title: "Claude 娘 · 桌宠", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let follow = addItem("自动跟随 Codex", action: #selector(resumeFollowing))
        follow.state = manualExpression == nil ? .on : .off
        let randomExpressions = addItem("待机随机表情", action: #selector(toggleIdleExpressions))
        randomExpressions.state = idleExpressionsEnabled ? .on : .off
        let wandering = addItem("待机小范围漫游", action: #selector(toggleIdleWandering))
        wandering.state = idleWanderingEnabled ? .on : .off

        let expressionItem = NSMenuItem(title: "切换表情", action: nil, keyEquivalent: "")
        let expressionMenu = NSMenu()
        for (name, label) in expressionOptions {
            let item = NSMenuItem(title: label, action: #selector(selectExpression(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = expressions[name] != nil
            item.state = manualExpression == name ? .on : .off
            expressionMenu.addItem(item)
        }
        expressionItem.submenu = expressionMenu
        menu.addItem(expressionItem)

        let sizeItem = NSMenuItem(title: "角色大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (label, height) in [("小", 156), ("中", 208), ("大", 280)] {
            let item = NSMenuItem(title: label, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = height
            item.state = Int(currentSize) == height ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let pause = addItem("暂停动画", action: #selector(togglePause))
        pause.state = paused ? .on : .off
        let onTop = addItem("保持置顶", action: #selector(toggleOnTop))
        onTop.state = staysOnTop ? .on : .off
        addItem(isHidden ? "显示桌宠" : "隐藏桌宠", action: #selector(toggleVisibility))
        addItem("恢复默认位置", action: #selector(resetPosition))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出桌宠", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)
    }

    @discardableResult private func addItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func resumeFollowing() {
        manualExpression = nil
        // Force a fresh first frame even when the selected expression used the same state.
        currentAnimation = ""
        applyAutomaticState(lastActivityState)
        showBubble("跟着 Codex 工作", seconds: 4)
    }

    @objc private func selectExpression(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, expressions[name] != nil else { return }
        manualExpression = name
        showStatic(name)
        let label = expressionOptions.first { $0.0 == name }?.1 ?? "切换表情"
        showBubble(label, seconds: 4)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let height = sender.representedObject as? Int else { return }
        resizePet(to: CGFloat(height), persist: true)
    }

    @objc private func toggleIdleExpressions() {
        idleExpressionsEnabled.toggle()
        defaults.set(idleExpressionsEnabled, forKey: "idleExpressions")
        if !idleExpressionsEnabled && manualExpression == nil && lastActivityState == "idle" { setAnimation("idle") }
    }

    @objc private func toggleIdleWandering() {
        idleWanderingEnabled.toggle()
        defaults.set(idleWanderingEnabled, forKey: "idleWandering")
    }

    private func resizePet(to height: CGFloat, persist: Bool) {
        let previous = panel.frame
        currentSize = height
        let size = NSSize(width: max(188, height + 16), height: height + 44)
        petView.spriteHeight = height
        var origin = NSPoint(x: previous.midX - size.width / 2, y: previous.minY)
        origin = clampedOrigin(origin, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        petView.frame = NSRect(origin: .zero, size: size)
        petView.needsDisplay = true
        if persist {
            defaults.set(Double(height), forKey: "petSize")
            savePosition()
            resetIdleBehavior()
        }
    }

    @objc private func togglePause() {
        paused.toggle()
        defaults.set(paused, forKey: "petPaused")
        if !paused, let animation = animations[currentAnimation] {
            nextFrameTime = ProcessInfo.processInfo.systemUptime + animation.durations[frameIndex]
        }
    }

    @objc private func toggleOnTop() {
        staysOnTop.toggle()
        panel.level = staysOnTop ? .floating : .normal
        defaults.set(staysOnTop, forKey: "petOnTop")
        if !isHidden { panel.orderFrontRegardless() }
    }

    @objc private func toggleVisibility() {
        isHidden.toggle()
        if isHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        updateClickThrough()
    }

    private func openCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func restorePosition() {
        if defaults.object(forKey: "petPositionX") != nil && defaults.object(forKey: "petPositionY") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "petPositionX"), y: defaults.double(forKey: "petPositionY"))
            panel.setFrameOrigin(clampedOrigin(origin, size: panel.frame.size))
        } else { resetPosition() }
    }

    @objc private func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - panel.frame.width - 38, y: visible.minY + 38)
        panel.setFrameOrigin(clampedOrigin(origin, size: panel.frame.size))
        savePosition()
        resetIdleBehavior()
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, preferPointerScreen: Bool = false) -> NSPoint {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return origin }
        let candidate = NSRect(origin: origin, size: size)
        let pointer = NSEvent.mouseLocation
        let pointerScreen = preferPointerScreen ? screens.first { $0.frame.contains(pointer) } : nil
        let intersecting = screens.max { a, b in
            let left = a.visibleFrame.intersection(candidate)
            let right = b.visibleFrame.intersection(candidate)
            return max(0, left.width) * max(0, left.height) < max(0, right.width) * max(0, right.height)
        }
        let hasIntersection = intersecting.map { !$0.visibleFrame.intersection(candidate).isEmpty } ?? false
        let screen = pointerScreen ?? (hasIntersection ? intersecting : nil) ?? NSScreen.main ?? screens[0]
        let visible = screen.visibleFrame
        // Clamp the whole panel, including its status bubble, to the usable display.
        return NSPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                       y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }

    @objc private func screensChanged() {
        panel.setFrameOrigin(clampedOrigin(panel.frame.origin, size: panel.frame.size))
        savePosition()
        resetIdleBehavior()
    }

    private func savePosition() {
        // Called only for deliberate placement changes; roaming never writes preferences.
        defaults.set(Double(panel.frame.origin.x), forKey: "petPositionX")
        defaults.set(Double(panel.frame.origin.y), forKey: "petPositionY")
    }
}
