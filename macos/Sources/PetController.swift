import AppKit
import ImageIO

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PetFrame {
    let image: NSImage
    let pixels: NSBitmapImageRep
    let isAtlasCell: Bool
    let interpolation: NSImageInterpolation

    init(_ image: CGImage, isAtlasCell: Bool = false) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.pixels = NSBitmapImageRep(cgImage: image)
        self.isAtlasCell = isAtlasCell
        self.interpolation = isAtlasCell ? .none : .high
    }
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
    var cellWidth: CGFloat = 112
    var scaleX: CGFloat = 1 { didSet { if oldValue != scaleX { needsDisplay = true } } }
    var scaleY: CGFloat = 1 { didSet { if oldValue != scaleY { needsDisplay = true } } }
    var offsetX: CGFloat = 0 { didSet { if oldValue != offsetX { needsDisplay = true } } }
    var offsetY: CGFloat = 0 { didSet { if oldValue != offsetY { needsDisplay = true } } }
    var spriteHeight: CGFloat { cellWidth * 208 / 192 }
    var headroomSource: CGFloat = 24
    var jumpHeadroom: CGFloat { cellWidth * headroomSource / 192 }
    var cellRect: NSRect { NSRect(x: (bounds.width - cellWidth) / 2, y: 0, width: cellWidth, height: spriteHeight) }
    var bubble: String? { didSet { needsDisplay = true } }
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onActivate: (() -> Void)?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    var restingSpriteRect: NSRect {
        guard let sprite else { return .zero }
        if sprite.isAtlasCell { return cellRect }
        let size = sprite.image.size
        // The same composition as the Codex atlas: 170px portrait height,
        // foot at y=202 in a 192x208 cell. Draw the original 400px artwork
        // directly so Retina downsamples it instead of enlarging an atlas crop.
        let scale = (170 / max(size.height, 1)) * cellWidth / 192
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: (bounds.width - width) / 2, y: 6 * cellWidth / 192,
                      width: width, height: height)
    }

    var spriteRect: NSRect {
        let resting = restingSpriteRect
        let unit = cellWidth / 192
        let width = resting.width * scaleX
        let foot = 6 * unit
        return NSRect(x: resting.midX - width / 2 + offsetX * unit,
                      y: foot + (resting.minY - foot) * scaleY + offsetY * unit,
                      width: width, height: resting.height * scaleY)
    }

    func containsVisiblePixel(at point: NSPoint) -> Bool {
        containsVisiblePixel(at: point, in: spriteRect)
    }

    func containsRestingPixel(at point: NSPoint) -> Bool {
        containsVisiblePixel(at: point, in: restingSpriteRect)
    }

    private func containsVisiblePixel(at point: NSPoint, in rect: NSRect) -> Bool {
        guard let sprite, rect.width > 0, rect.height > 0, rect.contains(point) else { return false }
        let x = min(sprite.pixels.pixelsWide - 1, max(0, Int((point.x - rect.minX) / rect.width * CGFloat(sprite.pixels.pixelsWide))))
        // Bitmap rows start at the top; AppKit view coordinates start at the bottom.
        let y = min(sprite.pixels.pixelsHigh - 1, max(0, Int((rect.maxY - point.y) / rect.height * CGFloat(sprite.pixels.pixelsHigh))))
        return (sprite.pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.10
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // This transparent view repaints continuously. Clear the previous
        // frame before source-over drawing, including translucent edge pixels.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        if let sprite {
            sprite.image.draw(in: spriteRect, from: .zero, operation: .sourceOver, fraction: 1,
                              respectFlipped: true, hints: [.interpolation: sprite.interpolation])
        }
        guard let bubble, !bubble.isEmpty else { return }
        let rect = NSRect(x: 8, y: spriteHeight + jumpHeadroom + 7, width: bounds.width - 16, height: 29)
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
    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

/// A local, non-activating companion. Construct and call it from the main thread.
final class PetController: NSObject, NSMenuDelegate {
    private let resources: URL
    private let defaults: UserDefaults
    private let panel: PetPanel
    private let petView: PetView
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var expressions: [String: PetFrame] = [:]
    private var originalArtwork: [String: CGImage] = [:]
    private var brightness = PortraitBrightness.codex
    private var codexClips: [String: CodexArtwork.Clip] = [:]
    private var displayFrames: [String: [PetFrame]] = [:]
    private var displayDurations: [String: [TimeInterval]] = [:]
    private var portraitStartedAt: TimeInterval = 0
    private var displayedFrameIndex = 0
    private var currentAnimation = "idle"
    private var currentPortrait = "smile"
    private var motion = PortraitMotion()
    private var hoverTracker = PetHoverTracker()
    private var animationTime: TimeInterval = 0
    private var lastTickTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var bubbleUntil: TimeInterval = 0
    private var manualExpression: String?
    private var manualUntil: TimeInterval?
    private var expressionPinned = false
    private var lastActivityState = "idle"
    private var followsActivity = true
    private var automaticActivityState: String { followsActivity ? lastActivityState : "idle" }
    private var pressTracker = PetPressTracker()
    private var dragMouseOrigin = NSPoint.zero
    private var dragWindowOrigin = NSPoint.zero
    private var isHidden = false
    private var paused = false
    private var staysOnTop = true
    private var currentSize: CGFloat = 112
    private var idleBehavior = IdleBehavior()
    private var idleExpressionsEnabled = true
    private var idleWanderingEnabled = true
    private var statusBubblesEnabled = false
    private var menuOpen = false

    private let expressionOptions: [(String, String)] = [
        ("smile", "微笑"), ("smile-closed", "眯眼笑"), ("typing", "敲键盘"),
        ("notes", "看笔记"), ("knock", "敲敲你"), ("confetti", "撒花"),
        ("panic", "慌张"), ("guilty", "委屈"), ("stone", "石化"),
        ("confident", "自信"), ("crying", "大哭")
    ]

    init(resources: URL, defaults: UserDefaults = .standard) {
        self.resources = resources
        self.defaults = defaults
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 124, height: 140))
        panel = PetPanel(contentRect: petView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        precondition(Thread.isMainThread)
        brightness = PortraitBrightness(rawValue: defaults.string(forKey: "portraitBrightness") ?? "") ?? .codex
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
        if [88.0, 112.0, 160.0].contains(defaults.double(forKey: "petCellWidth")) {
            currentSize = CGFloat(defaults.double(forKey: "petCellWidth"))
        }
        paused = defaults.bool(forKey: "petPaused")
        followsActivity = defaults.object(forKey: "followCodexActivity") == nil ? true : defaults.bool(forKey: "followCodexActivity")
        idleExpressionsEnabled = defaults.object(forKey: "idleExpressions") == nil ? true : defaults.bool(forKey: "idleExpressions")
        if defaults.object(forKey: "videoStyleWandering") != nil {
            idleWanderingEnabled = defaults.bool(forKey: "videoStyleWandering")
        } else {
            // Preserve the previous version's explicit roam preference.
            idleWanderingEnabled = defaults.object(forKey: "idleWandering") == nil ? true : defaults.bool(forKey: "idleWandering")
            defaults.set(idleWanderingEnabled, forKey: "videoStyleWandering")
        }
        statusBubblesEnabled = defaults.bool(forKey: "statusBubbles")
        staysOnTop = defaults.object(forKey: "petOnTop") == nil ? true : defaults.bool(forKey: "petOnTop")
        resizePet(to: currentSize, persist: false)
        panel.level = staysOnTop ? .floating : .normal
        restorePosition()
        resetIdleBehavior()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Claude 娘桌宠")
            button.image?.isTemplate = true
            button.toolTip = "Claude 娘桌宠 · 单击换表情，右键更多选项"
        }
        item.menu = menu
        statusItem = item
        setAnimation("idle", force: true)
        panel.orderFrontRegardless()
        lastTickTime = ProcessInfo.processInfo.systemUptime
        let newTimer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
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
        guard followsActivity && manualExpression == nil && !pressTracker.isPressed else { return }
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
        petView.setAccessibilityRole(.button)
        petView.setAccessibilityLabel("Claude 娘桌宠")
        petView.setAccessibilityHelp("单击切换表情，拖动移动，右键更多选项")
    }

    private func configureInteraction() {
        petView.onMouseDown = { [weak self] event in
            guard let self else { return }
            self.motion.cancelHover()
            self.updatePortraitMotion()
            self.dragMouseOrigin = NSEvent.mouseLocation
            self.dragWindowOrigin = self.panel.frame.origin
            self.pressTracker.begin(at: self.dragMouseOrigin)
            self.panel.ignoresMouseEvents = false
        }
        petView.onMouseDragged = { [weak self] _ in
            guard let self, self.pressTracker.isPressed else { return }
            let mouse = NSEvent.mouseLocation
            let wasDragging = self.pressTracker.isDragging
            guard self.pressTracker.drag(to: mouse) else { return }
            if !wasDragging && !self.paused {
                self.motion.expressionChanged(at: self.animationTime)
                self.updatePortraitMotion()
            }
            // Translate the whole cutout while preserving its current expression.
            // Dragging does not replace a standing pose with a running gait.
            let origin = NSPoint(x: self.dragWindowOrigin.x + mouse.x - self.dragMouseOrigin.x,
                                 y: self.dragWindowOrigin.y + mouse.y - self.dragMouseOrigin.y)
            self.panel.setFrameOrigin(self.clampedOrigin(origin, size: self.panel.frame.size, preferPointerScreen: true))
        }
        petView.onMouseUp = { [weak self] _ in
            guard let self else { return }
            guard self.pressTracker.isPressed else { return }
            let isClick = self.pressTracker.end(at: NSEvent.mouseLocation)
            if isClick { self.cycleExpression() }
            else {
                if self.manualExpression == nil { self.applyAutomaticState(self.automaticActivityState) }
                self.savePosition()
                self.resetIdleBehavior()
            }
            self.updateClickThrough()
        }
        petView.onContextMenu = { [weak self] event in
            guard let self else { return }
            if self.pressTracker.isDragging { self.savePosition(); self.resetIdleBehavior() }
            self.pressTracker.cancel()
            self.motion.cancelHover()
            self.updatePortraitMotion()
            self.menuOpen = true
            defer { self.menuOpen = false }
            NSMenu.popUpContextMenu(self.menu, with: event, for: self.petView)
        }
        petView.onActivate = { [weak self] in
            self?.motion.cancelHover()
            self?.cycleExpression()
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

    private func loadArtwork() {
        if codexClips.isEmpty, let atlas = Self.readImage(resources.appendingPathComponent("Atlas.png")) {
            codexClips = CodexArtwork.clips(atlas: atlas)
            if let extraAtlas = Self.readImage(resources.appendingPathComponent("CodexExtraExpressions.png")) {
                codexClips.merge(CodexArtwork.extraClips(atlas: extraAtlas)) { _, extra in extra }
            }
        }
        for (name, _) in expressionOptions {
            if originalArtwork[name] == nil {
                originalArtwork[name] = Self.readImage(resources.appendingPathComponent("sprites/\(name).png"))
            }
            if brightness == .codex, let clip = codexClips[name] {
                // Classic and supplemental frames share the vivid Codex art
                // direction. Draw their complete cells without color grading.
                displayFrames[name] = clip.frames.map { PetFrame($0, isAtlasCell: true) }
                displayDurations[name] = clip.durations
            } else if let image = originalArtwork[name] {
                let adjusted = PortraitColor.adjusted(image, brightness: brightness)
                if brightness == .codex, let cell = Self.framedPortrait(adjusted) {
                    displayFrames[name] = [PetFrame(cell, isAtlasCell: true)]
                } else {
                    displayFrames[name] = [PetFrame(adjusted)]
                }
                displayDurations[name] = []
            }
            expressions[name] = displayFrames[name]?.first
        }
    }

    private static func framedPortrait(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let height: CGFloat = 170
        let width = CGFloat(image.width) / CGFloat(image.height) * height
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (192 - width) / 2, y: 6, width: width, height: height))
        return context.makeImage()
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
            try require(image.height >= 400, "Retina 绘制需要原始高分辨率立绘：\(name)")
        }

        // Exercise the real hit-testing transform at both a transparent corner
        // and an opaque character pixel, including the bitmap/view Y inversion.
        guard let idleImage = readImage(resources.appendingPathComponent("sprites/smile.png")) else { return }
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 124, height: 140))
        view.cellWidth = 112
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
        try require(abs(view.spriteHeight - 121.3333333) < 0.001 && abs(rect.height - 99.1666667) < 0.001,
                    "默认构图必须匹配 Codex 112pt 格子与170px立绘高度")
        let baseline = view.spriteRect.minY
        view.scaleX = 0.9
        view.scaleY = 1.13
        try require(view.spriteRect.minY == baseline, "表情变形必须固定脚底")
        try require(view.spriteRect.maxY <= view.spriteHeight, "拉伸时不应裁切头部")
        view.offsetY = 24
        view.offsetX = 4
        try require(view.spriteRect.maxY < view.bounds.maxY, "悬停跳跃叠加表情动效不应裁切头部")
        try require(view.spriteRect.minX > 0 && view.spriteRect.maxX < view.bounds.maxX, "动态偏移不应裁切身体")
        let airborneRect = view.spriteRect
        var checkedAirborneHead = false
        for y in 0..<min(80, pixels.pixelsHigh) {
            for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 {
                let point = NSPoint(x: airborneRect.minX + (CGFloat(x) + 0.5) / CGFloat(pixels.pixelsWide) * airborneRect.width,
                                    y: airborneRect.maxY - (CGFloat(y) + 0.5) / CGFloat(pixels.pixelsHigh) * airborneRect.height)
                if point.y > view.restingSpriteRect.maxY {
                    try require(view.containsVisiblePixel(at: point), "跳起后的头部也必须可点击")
                    checkedAirborneHead = true
                    break
                }
            }
            if checkedAirborneHead { break }
        }
        try require(checkedAirborneHead, "未检查跳起位置的实际命中")
        let classic = CodexArtwork.clips(atlas: atlas)
        guard let referenceFrame = classic["notes"]?.frames.last else {
            throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "缺少Codex同款看书帧"])
        }
        let classicView = PetView(frame: NSRect(x: 0, y: 0, width: 124, height: 160))
        classicView.cellWidth = 112
        classicView.headroomSource = 56
        classicView.sprite = PetFrame(referenceFrame, isAtlasCell: true)
        try require(abs(classicView.spriteRect.width - 112) < 0.001 && abs(classicView.spriteRect.height - 121.3333333) < 0.001,
                    "Codex整格必须直接按112pt绘制，不得再次缩小人物")
        try require(classicView.sprite?.interpolation == NSImageInterpolation.none, "Codex同款图帧应使用清晰像素采样")
        classicView.scaleY = 1.13
        classicView.offsetY = 24
        try require(classicView.spriteRect.maxY < classicView.bounds.maxY, "完整Codex帧的跳跃不应裁切")
        let cellFoot = classicView.spriteRect.minY + 6 * 112 / 192 * classicView.scaleY
        try require(abs(cellFoot - (6 + 24) * 112 / 192) < 0.001, "Codex整格变形必须保留正确脚底锚点")
        // Repainting a transparent portrait must not accumulate old alpha or
        // leave a previous expression underneath it.
        guard let paint = CGContext(data: nil, width: 248, height: 280, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建透明重绘测试画布"])
        }
        paint.scaleBy(x: 2, y: 2)
        func paintedSnapshot() throws -> Data {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: paint, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = paint.makeImage()?.dataProvider?.data else {
                throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取透明重绘像素"])
            }
            return Data(bytes: CFDataGetBytePtr(data)!, count: CFDataGetLength(data))
        }
        let firstPaint = try paintedSnapshot()
        let secondPaint = try paintedSnapshot()
        try require(firstPaint == secondPaint, "重复绘制不得叠加透明度或加深颜色")
        try IdleBehavior.selfTest()
        try PortraitMotion.selfTest()
        try PetPressTracker.selfTest()
        try PetHoverTracker.selfTest()
        try PortraitColor.selfTest()
        guard let extraAtlas = readImage(resources.appendingPathComponent("CodexExtraExpressions.png")) else {
            throw NSError(domain: "ClaudeDeskPet.SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "缺少或无法读取CodexExtraExpressions.png补充动画图集"])
        }
        try CodexArtwork.selfTest(atlas: atlas, extraAtlas: extraAtlas)
        try selectionSelfTest(resources: resources)
    }

    /// Exercise the real selection/timeout handlers with isolated preferences.
    /// The panel stays hidden and no activity monitor or timer is started.
    private static func selectionSelfTest(resources: URL) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ClaudeDeskPet.Selection", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let domain = "ClaudeDeskPet.SelectionTest." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: domain) else {
            throw NSError(domain: "ClaudeDeskPet.Selection", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建隔离自测偏好"])
        }
        defer { preferences.removePersistentDomain(forName: domain) }
        let controller = PetController(resources: resources, defaults: preferences)
        controller.applyActivity(state: "idle", text: "")
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = "panic"
        let before = ProcessInfo.processInfo.systemUptime
        controller.selectExpression(item)
        let after = ProcessInfo.processInfo.systemUptime
        try require(controller.manualExpression == "panic" && controller.manualUntil != nil,
                    "普通菜单选表情不得永久阻止待机")
        let expiry = controller.manualUntil ?? -.infinity
        try require(expiry >= before + 15 && expiry <= after + 15,
                    "手动表情必须使用15秒展示时长")
        controller.releaseExpiredSelection(at: expiry - 0.001)
        try require(controller.manualExpression == "panic", "临时表情提前结束")
        controller.releaseExpiredSelection(at: expiry)
        try require(controller.manualExpression == nil && controller.currentPortrait == "smile",
                    "临时表情结束后必须恢复自动待机")

        controller.selectExpression(item)
        controller.toggleExpressionPin()
        controller.releaseExpiredSelection(at: ProcessInfo.processInfo.systemUptime + 600)
        try require(controller.expressionPinned && controller.manualExpression == "panic"
                    && controller.manualUntil == nil, "显式固定表情必须保持到用户解除")
        controller.toggleIdleExpressions() // disable
        controller.toggleIdleExpressions() // enabling random expressions releases the pin
        try require(controller.idleExpressionsEnabled && !controller.expressionPinned
                    && controller.manualExpression == nil, "开启待机随机必须解除旧手选锁")

        for _ in 0..<64 {
            let previous = controller.currentPortrait
            controller.cycleExpression()
            try require(controller.currentPortrait != previous && controller.manualUntil != nil,
                        "随机点击不得连续重复或意外固定")
        }
        controller.resumeFollowing()
        controller.applyActivity(state: "tool", text: "")
        controller.selectExpression(item)
        controller.releaseExpiredSelection(at: ProcessInfo.processInfo.systemUptime + 16)
        try require(controller.currentPortrait == "typing" && controller.manualExpression == nil,
                    "临时表情结束后必须恢复最新工作状态")
        controller.enterFreeIdle()
        controller.applyActivity(state: "tool", text: "")
        try require(controller.currentPortrait == "smile" && controller.automaticActivityState == "idle",
                    "自由待机不得被仍在运行的任务打断")
        controller.selectExpression(item)
        controller.releaseExpiredSelection(at: ProcessInfo.processInfo.systemUptime + 16)
        try require(controller.currentPortrait == "smile" && !controller.followsActivity,
                    "临时表情结束后应保留自由待机模式")
        controller.resumeFollowing()
        try require(controller.currentPortrait == "typing" && controller.followsActivity,
                    "切回跟随模式必须恢复最新任务状态")
        try require(!controller.panel.isVisible, "自测不应显示额外桌宠窗口")
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
            showPortrait("panic"); showBubble("有点慌张", seconds: 6); return
        case "aborted", "interrupted", "guilty":
            showPortrait("guilty"); showBubble("等你再叫我", seconds: 6); return
        case "stone":
            showPortrait("stone"); showBubble("让我缓一缓", seconds: 6); return
        default: animation = "idle"; bubble = "准备好啦"
        }
        let changed = currentAnimation != animation || manualExpression != nil
        setAnimation(animation)
        if changed { showBubble(bubble, seconds: 6) }
    }

    private func setAnimation(_ name: String, force: Bool = false) {
        if !force && currentAnimation == name { return }
        currentAnimation = name
        let portrait: String
        switch name {
        case "running": portrait = "typing"
        case "review": portrait = "notes"
        case "waiting": portrait = "smile-closed"
        case "jumping": portrait = "confetti"
        case "waving": portrait = "knock"
        case "failed": portrait = "crying"
        default: portrait = "smile"
        }
        presentPortrait(portrait, force: force)
    }

    private func showPortrait(_ name: String) {
        currentAnimation = "static:\(name)"
        presentPortrait(name)
    }

    private func presentPortrait(_ name: String, force: Bool = false) {
        guard let frame = expressions[name] else { return }
        if force || currentPortrait != name {
            if paused { motion = PortraitMotion() }
            else { motion.expressionChanged(at: animationTime) }
        }
        currentPortrait = name
        portraitStartedAt = animationTime
        displayedFrameIndex = 0
        petView.sprite = frame
        let label = expressionOptions.first { $0.0 == name }?.1 ?? name
        petView.setAccessibilityValue(label)
        updatePortraitMotion()
    }

    private func updatePortraitMotion() {
        let shape = motion.sample(at: animationTime, expression: currentPortrait,
                                  reducedMotion: paused || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                  loopIntensity: (displayFrames[currentPortrait]?.count ?? 0) > 1 ? 0.2 : 1)
        petView.scaleX = shape.scaleX
        petView.scaleY = shape.scaleY
        petView.offsetX = shape.offsetX
        petView.offsetY = shape.offsetY
    }

    private func updateArtworkFrame() {
        guard let frames = displayFrames[currentPortrait], frames.count > 1,
              let durations = displayDurations[currentPortrait], durations.count == frames.count else { return }
        let total = durations.reduce(0, +)
        guard total > 0 else { return }
        var phase = max(0, animationTime - portraitStartedAt).truncatingRemainder(dividingBy: total)
        var index = frames.count - 1
        for candidate in durations.indices {
            if phase < durations[candidate] { index = candidate; break }
            phase -= durations[candidate]
        }
        if index != displayedFrameIndex {
            displayedFrameIndex = index
            petView.sprite = frames[index]
        }
    }

    private func showBubble(_ message: String, seconds: TimeInterval) {
        guard statusBubblesEnabled else { return }
        petView.bubble = String(message.prefix(18))
        bubbleUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let delta = min(0.1, max(0, now - lastTickTime))
        lastTickTime = now
        let mayAnimate = !pressTracker.isPressed || pressTracker.isDragging
        if !paused && !isHidden && !reduceMotion && mayAnimate && !menuOpen { animationTime += delta }
        updateHover(reducedMotion: reduceMotion)
        releaseExpiredSelection(at: now)
        let wasWandering = idleBehavior.isWandering
        let idle = idleBehavior.update(now: now,
                                       eligible: automaticActivityState == "idle" && manualExpression == nil && !pressTracker.isPressed && !paused && !isHidden && !menuOpen,
                                       posesEnabled: idleExpressionsEnabled,
                                       wanderingEnabled: idleWanderingEnabled,
                                       reduceMotion: reduceMotion,
                                       pointerNear: pointerNearPet())
        if let origin = idle.origin { panel.setFrameOrigin(origin) }
        if !wasWandering && idleBehavior.isWandering && !paused {
            motion.expressionChanged(at: animationTime)
        }
        if let pose = idle.pose {
            if pose.hasPrefix("static:") { showPortrait(String(pose.dropFirst(7))) }
            else { setAnimation(pose) }
        }
        if !paused && !isHidden && !reduceMotion && mayAnimate && !menuOpen { updateArtworkFrame() }
        if !paused && !isHidden && mayAnimate && !menuOpen { updatePortraitMotion() }
        if petView.bubble != nil && now >= bubbleUntil { petView.bubble = nil }
        updateClickThrough()
    }

    private func pointerNearPet() -> Bool {
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = petView.convert(windowPoint, from: nil)
        return petView.cellRect.insetBy(dx: -16, dy: -16).contains(point)
    }

    private func releaseExpiredSelection(at now: TimeInterval) {
        guard let deadline = manualUntil, now >= deadline,
              !pressTracker.isPressed, !menuOpen else { return }
        manualUntil = nil
        manualExpression = nil
        applyAutomaticState(automaticActivityState)
    }

    private func updateHover(reducedMotion: Bool) {
        if reducedMotion || isHidden { motion.cancelHover() }
        let point = petView.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside: Bool
        if isHidden { inside = false }
        else if hoverTracker.isInside {
            // This zone is fixed to the cell, not to the airborne portrait.
            // A jump therefore cannot manufacture its own leave/re-enter.
            let margin = max(8, currentSize * 16 / 192)
            inside = petView.cellRect.insetBy(dx: -margin, dy: -margin).contains(point)
        } else {
            inside = petView.containsRestingPixel(at: point)
        }
        let eligible = !paused && !isHidden && !reducedMotion && !menuOpen && !pressTracker.isPressed
        if hoverTracker.update(isInside: inside, eligible: eligible) {
            _ = motion.hoverEntered(at: animationTime)
        }
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
        if menu === self.menu {
            menuOpen = true
            motion.cancelHover()
            updatePortraitMotion()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuOpen = false }
    }

    private func updateClickThrough() {
        if pressTracker.isPressed { panel.ignoresMouseEvents = false; return }
        guard !isHidden else { panel.ignoresMouseEvents = true; return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let viewPoint = petView.convert(windowPoint, from: nil)
        let visible = petView.containsVisiblePixel(at: viewPoint)
        // Preserve the original opaque silhouette during the short jump, so
        // clicking a foot as it lifts does not fall through to another app.
        let restingDuringJump = motion.isHoverJumping(at: animationTime) && petView.containsRestingPixel(at: viewPoint)
        panel.ignoresMouseEvents = !(visible || restingDuringJump)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let title = NSMenuItem(title: "Claude 娘 · 桌宠", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let follow = addItem("自动跟随 Codex", action: #selector(resumeFollowing))
        follow.state = followsActivity && manualExpression == nil ? .on : .off
        let freeIdle = addItem("自由待机（随机表情）", action: #selector(enterFreeIdle))
        freeIdle.state = !followsActivity && manualExpression == nil ? .on : .off
        addItem("随机换一个表情", action: #selector(nextExpression))
        let randomExpressions = addItem("待机随机表情", action: #selector(toggleIdleExpressions))
        randomExpressions.state = idleExpressionsEnabled ? .on : .off
        let wandering = addItem("自动漫游（可选）", action: #selector(toggleIdleWandering))
        wandering.state = idleWanderingEnabled ? .on : .off

        let pin = addItem("固定当前表情", action: #selector(toggleExpressionPin))
        pin.state = expressionPinned ? .on : .off
        let expressionItem = NSMenuItem(title: expressionPinned ? "切换固定表情" : "切换表情（展示\(Int(IdleBehavior.expressionInterval))秒）", action: nil, keyEquivalent: "")
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

        let brightnessItem = NSMenuItem(title: "显示风格", action: nil, keyEquivalent: "")
        let brightnessMenu = NSMenu()
        for value in PortraitBrightness.allCases {
            let item = NSMenuItem(title: value.title, action: #selector(selectBrightness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = value == brightness ? .on : .off
            brightnessMenu.addItem(item)
        }
        brightnessItem.submenu = brightnessMenu
        menu.addItem(brightnessItem)

        let sizeItem = NSMenuItem(title: "角色大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (label, height) in [("小", 88), ("与 Codex 相同", 112), ("大", 160)] {
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
        let bubbles = addItem("显示状态气泡", action: #selector(toggleStatusBubbles))
        bubbles.state = statusBubblesEnabled ? .on : .off
        let onTop = addItem("保持置顶", action: #selector(toggleOnTop))
        onTop.state = staysOnTop ? .on : .off
        addItem(isHidden ? "显示桌宠" : "隐藏桌宠", action: #selector(toggleVisibility))
        addItem("恢复默认位置", action: #selector(resetPosition))
        addItem("打开 Codex", action: #selector(openCodex))
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
        followsActivity = true
        defaults.set(true, forKey: "followCodexActivity")
        resumeAutomaticExpressions()
        showBubble("跟着 Codex 工作", seconds: 4)
    }

    @objc private func enterFreeIdle() {
        followsActivity = false
        defaults.set(false, forKey: "followCodexActivity")
        idleExpressionsEnabled = true
        defaults.set(true, forKey: "idleExpressions")
        resumeAutomaticExpressions()
        showBubble("自由待机", seconds: 4)
    }

    private func resumeAutomaticExpressions() {
        expressionPinned = false
        manualExpression = nil
        manualUntil = nil
        // Force a fresh first frame even when the selected expression used the same state.
        currentAnimation = ""
        applyAutomaticState(automaticActivityState)
    }

    @objc private func selectExpression(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, expressions[name] != nil else { return }
        manualExpression = name
        manualUntil = expressionPinned ? nil : ProcessInfo.processInfo.systemUptime + IdleBehavior.expressionInterval
        showPortrait(name)
        let label = expressionOptions.first { $0.0 == name }?.1 ?? "切换表情"
        showBubble(label, seconds: 4)
    }

    @objc private func nextExpression() { cycleExpression() }

    @objc private func toggleExpressionPin() {
        expressionPinned.toggle()
        if expressionPinned {
            manualExpression = currentPortrait
            manualUntil = nil
        } else {
            resumeAutomaticExpressions()
        }
    }

    private func cycleExpression() {
        let candidates = expressionOptions.map { $0.0 }.filter { $0 != currentPortrait }
        guard let name = candidates.randomElement() else { return }
        manualExpression = name
        // Ordinary expression selections are temporary. Only the explicit pin
        // action may suspend automatic expressions indefinitely.
        manualUntil = expressionPinned ? nil : ProcessInfo.processInfo.systemUptime + IdleBehavior.expressionInterval
        showPortrait(name)
        let label = expressionOptions.first { $0.0 == name }?.1 ?? name
        showBubble(label, seconds: 3)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let height = sender.representedObject as? Int else { return }
        resizePet(to: CGFloat(height), persist: true)
    }

    @objc private func selectBrightness(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let value = PortraitBrightness(rawValue: raw) else { return }
        brightness = value
        defaults.set(value.rawValue, forKey: "portraitBrightness")
        loadArtwork()
        // Appearance changes preserve the expression and its motion; only
        // the matching texture sequence restarts on the new material.
        petView.sprite = expressions[currentPortrait]
        displayedFrameIndex = 0
        portraitStartedAt = animationTime
        resizePet(to: currentSize, persist: false)
        resetIdleBehavior()
    }

    @objc private func toggleIdleExpressions() {
        idleExpressionsEnabled.toggle()
        defaults.set(idleExpressionsEnabled, forKey: "idleExpressions")
        if idleExpressionsEnabled { resumeAutomaticExpressions() }
        if !idleExpressionsEnabled && manualExpression == nil && automaticActivityState == "idle" { setAnimation("idle") }
    }

    @objc private func toggleIdleWandering() {
        idleWanderingEnabled.toggle()
        defaults.set(idleWanderingEnabled, forKey: "videoStyleWandering")
    }

    @objc private func toggleStatusBubbles() {
        statusBubblesEnabled.toggle()
        defaults.set(statusBubblesEnabled, forKey: "statusBubbles")
        petView.bubble = nil
        resizePet(to: currentSize, persist: false)
        savePosition()
        resetIdleBehavior()
    }

    private func resizePet(to width: CGFloat, persist: Bool) {
        let previous = panel.frame
        currentSize = width
        let headroom: CGFloat = brightness == .codex ? 56 : 24
        let size = NSSize(width: statusBubblesEnabled ? max(188, width + 12) : width + 12,
                          height: width * (208 + headroom) / 192 + (statusBubblesEnabled ? 44 : 4))
        petView.cellWidth = width
        petView.headroomSource = headroom
        var origin = NSPoint(x: previous.midX - size.width / 2, y: previous.minY)
        origin = clampedOrigin(origin, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        petView.frame = NSRect(origin: .zero, size: size)
        petView.needsDisplay = true
        if persist {
            defaults.set(Double(width), forKey: "petCellWidth")
            savePosition()
            resetIdleBehavior()
        }
    }

    @objc private func togglePause() {
        paused.toggle()
        defaults.set(paused, forKey: "petPaused")
        if paused { motion.cancelHover(); updatePortraitMotion() }
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

    @objc private func openCodex() {
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
