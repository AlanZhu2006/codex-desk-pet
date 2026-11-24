import AppKit

enum QuotaPanelState {
    case loading
    case missingDependency
    case content(QuotaSnapshot, refreshing: Bool, stale: Bool)
    case failure
}

enum QuotaServicePanelState {
    case loading
    case missingDependency
    case content([QuotaService], updating: Bool, failed: Bool)
    case failure
}

private final class QuotaWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private class QuotaPanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class QuotaServiceToggle: QuotaPanelButton {
    var serviceID = ""
}

private final class QuotaScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class QuotaMeter: NSView {
    private let remaining: Double

    init(remaining: Double) {
        self.remaining = remaining
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard remaining > 0 else { return }
        let fill = NSRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width * remaining, height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
}

/// A separate panel so the pet's translucent hit testing and drag logic stay local to the pet.
final class QuotaPanelController: NSObject, NSSearchFieldDelegate {
    private let panel = QuotaWindowPanel(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let document = QuotaScrollDocument()
    private let panelTitle = NSTextField(labelWithString: "订阅额度")
    private let timestamp = NSTextField(labelWithString: "")
    private let refreshButton = QuotaPanelButton()
    private let manageButton = QuotaPanelButton()
    private let backButton = QuotaPanelButton()
    private let searchField = NSSearchField()
    private var searchRowHeight: NSLayoutConstraint?
    private let onRefresh: () -> Void
    private let onClose: () -> Void
    private let onManage: () -> Void
    private let onBack: () -> Void
    private let onToggleService: (String, Bool) -> Void
    private let onSetup: () -> Void
    private weak var anchor: NSWindow?
    private var state = QuotaPanelState.loading
    private var serviceState: QuotaServicePanelState?
    private var body: NSStackView?
    private var bodyWidthConstraint: NSLayoutConstraint?
    private var outsideClickMonitor: Any?
    private var localMonitor: Any?

    private static let preferredWidth: CGFloat = 360
    private static let bodyMargin: CGFloat = 18
    private static let headerHeight: CGFloat = 68
    private static let serviceSearchHeight: CGFloat = 38
    private static let maximumBodyHeight: CGFloat = 450
    private static let gap: CGFloat = 12
    private static let screenMargin: CGFloat = 8

    private let percentage: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        return formatter
    }()
    private let resetDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
    private let updatedTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    init(onRefresh: @escaping () -> Void, onClose: @escaping () -> Void,
         onManage: @escaping () -> Void, onBack: @escaping () -> Void,
         onToggleService: @escaping (String, Bool) -> Void, onSetup: @escaping () -> Void) {
        self.onRefresh = onRefresh
        self.onClose = onClose
        self.onManage = onManage
        self.onBack = onBack
        self.onToggleService = onToggleService
        self.onSetup = onSetup
        super.init()
        configurePanel()
        render(.loading)
    }

    deinit { stopDismissalMonitors() }

    var isVisible: Bool { panel.isVisible }

    func show(relativeTo pet: NSWindow) {
        anchor = pet
        resizeAndPlace()
        panel.makeKeyAndOrderFront(nil)
        startDismissalMonitors()
    }

    func hide() {
        panel.orderOut(nil)
        anchor = nil
        stopDismissalMonitors()
    }

    func render(_ state: QuotaPanelState) {
        self.state = state
        let returningFromServices = serviceState != nil
        serviceState = nil
        setServiceControls(visible: false)
        replaceBody(makeBody(), resetScroll: returningFromServices)
    }

    func renderServices(_ state: QuotaServicePanelState) {
        let enteringServices = serviceState == nil
        serviceState = state
        if enteringServices { searchField.stringValue = "" }
        setServiceControls(visible: true)
        replaceBody(makeServiceBody(state), resetScroll: enteringServices)
    }

    private func setServiceControls(visible: Bool) {
        let title = visible ? "管理订阅服务" : "订阅额度"
        panel.title = title
        panelTitle.stringValue = title
        manageButton.isHidden = visible
        backButton.isHidden = !visible
        searchField.isHidden = !visible
        searchRowHeight?.constant = visible ? Self.serviceSearchHeight : 0
        let refreshLabel = visible ? "重新读取服务" : "刷新额度"
        refreshButton.toolTip = refreshLabel
        refreshButton.setAccessibilityLabel(refreshLabel)
    }

    private func replaceBody(_ content: NSStackView, resetScroll: Bool = false) {
        let previousY = resetScroll ? 0 : scroll.contentView.bounds.minY
        body?.removeFromSuperview()
        document.addSubview(content)
        body = content
        content.translatesAutoresizingMaskIntoConstraints = false
        let width = content.widthAnchor.constraint(equalToConstant: Self.preferredWidth - 2 * Self.bodyMargin)
        bodyWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.bodyMargin),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 14)
        ])
        resizeAndPlace()
        let newY = min(previousY, max(0, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: newY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func configurePanel() {
        panel.title = "订阅额度"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        panelTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        timestamp.font = .systemFont(ofSize: 11)
        timestamp.textColor = .secondaryLabelColor
        timestamp.lineBreakMode = .byTruncatingTail
        let titleBlock = verticalStack([panelTitle, timestamp], spacing: 4)
        titleBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let close = QuotaPanelButton()
        configureIconButton(refreshButton, symbol: "arrow.clockwise", name: "刷新额度", action: #selector(refreshRequested))
        configureIconButton(manageButton, symbol: "gearshape", name: "管理服务", action: #selector(manageRequested))
        configureIconButton(backButton, symbol: "chevron.left", name: "返回额度面板", action: #selector(backRequested))
        configureIconButton(close, symbol: "xmark", name: "关闭额度面板", action: #selector(closeRequested))
        let header = NSStackView(views: [backButton, titleBlock, spacer, refreshButton, manageButton, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5
        header.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(header)

        let searchRow = NSView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(searchRow)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索服务"
        searchField.setAccessibilityLabel("搜索服务")
        searchField.delegate = self
        searchRow.addSubview(searchField)
        let searchHeight = searchRow.heightAnchor.constraint(equalToConstant: 0)
        searchRowHeight = searchHeight

        let rule = separator()
        effect.addSubview(rule)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: effect.topAnchor),
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Self.bodyMargin),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            searchRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            searchRow.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Self.bodyMargin),
            searchRow.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Self.bodyMargin),
            searchHeight,
            searchField.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: searchRow.topAnchor),
            rule.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        ])
    }

    private func makeServiceBody(_ state: QuotaServicePanelState) -> NSStackView {
        switch state {
        case .loading:
            timestamp.stringValue = "正在读取 CodexBar"
            refreshButton.isEnabled = false
            return verticalStack([label("正在获取服务列表…", color: .secondaryLabelColor)], spacing: 8)
        case .missingDependency:
            timestamp.stringValue = "需要 CodexBar"
            refreshButton.isEnabled = true
            return verticalStack([
                label("安装 CodexBar 后即可管理额度面板显示的服务。", color: .secondaryLabelColor, wraps: true),
                setupButton("安装 CodexBar")
            ], spacing: 8, fillWidth: [0])
        case .failure:
            timestamp.stringValue = "服务列表读取失败"
            refreshButton.isEnabled = true
            return verticalStack([
                label("请点刷新再试一次，或在 CodexBar 设置中管理服务。", color: .secondaryLabelColor, wraps: true),
                serviceLoginControls()
            ], spacing: 10, fillWidth: [0, 1])
        case let .content(services, updating, failed):
            let enabledCount = services.filter(\.enabled).count
            if updating {
                timestamp.stringValue = "正在保存服务设置…"
            } else if failed {
                timestamp.stringValue = "保存失败，请重试"
            } else {
                timestamp.stringValue = "已启用 \(enabledCount) 项服务"
            }
            refreshButton.isEnabled = !updating
            let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = services.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
            }.sorted { lhs, rhs in
                if lhs.enabled != rhs.enabled { return lhs.enabled }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            var rows: [NSView] = [serviceLoginControls(), separator()]
            if filtered.isEmpty {
                rows.append(label(query.isEmpty ? "暂无可管理的服务" : "未找到匹配的服务", color: .secondaryLabelColor))
            } else {
                rows.append(contentsOf: filtered.map { service in
                    let toggle = QuotaServiceToggle(checkboxWithTitle: service.name, target: self, action: #selector(serviceToggled(_:)))
                    toggle.serviceID = service.id
                    toggle.state = service.enabled ? .on : .off
                    toggle.isEnabled = !updating
                    return toggle
                })
            }
            return verticalStack(rows, spacing: 10, fillWidth: Array(rows.indices))
        }
    }

    private func serviceLoginControls() -> NSView {
        verticalStack([
            label("勾选要在额度面板显示的服务。登录或调整数据来源，请从菜单栏 CodexBar 图标进入 Settings → Providers。",
                  font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true),
            setupButton("打开 CodexBar")
        ], spacing: 7, fillWidth: [0])
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField,
              let serviceState else { return }
        replaceBody(makeServiceBody(serviceState), resetScroll: true)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, name: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func makeBody() -> NSStackView {
        switch state {
        case .loading:
            timestamp.stringValue = "正在读取 CodexBar"
            refreshButton.isEnabled = false
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
            spinner.startAnimation(nil)
            let progress = NSStackView(views: [spinner, label("正在获取订阅额度…")])
            progress.orientation = .horizontal
            progress.alignment = .centerY
            progress.spacing = 8
            return verticalStack([progress], spacing: 8)
        case .missingDependency:
            timestamp.stringValue = "需要 CodexBar"
            refreshButton.isEnabled = true
            return verticalStack([
                label("先安装 CodexBar，再在 CodexBar 中启用需要显示的服务。", color: .secondaryLabelColor, wraps: true),
                setupButton("安装 CodexBar")
            ], spacing: 10, fillWidth: [0])
        case .failure:
            timestamp.stringValue = "刷新失败"
            refreshButton.isEnabled = true
            return verticalStack([
                label("暂时读不到额度。请确认 CodexBar 里的服务可用，再点刷新。", color: .secondaryLabelColor, wraps: true),
                setupButton("打开 CodexBar")
            ], spacing: 8, fillWidth: [0])
        case let .content(snapshot, refreshing, stale):
            refreshButton.isEnabled = !refreshing
            let update = updatedTime.string(from: snapshot.fetchedAt)
            if refreshing {
                timestamp.stringValue = "正在刷新 · 上次 \(update)"
            } else if stale {
                timestamp.stringValue = "刷新失败 · 上次 \(update)"
            } else {
                timestamp.stringValue = "更新于 \(update)"
            }
            guard !snapshot.providers.isEmpty else {
                return verticalStack([
                    label("没有可显示的订阅。请在 CodexBar 中启用并连接服务，然后点刷新。", color: .secondaryLabelColor, wraps: true),
                    setupButton("打开 CodexBar")
                ], spacing: 8, fillWidth: [0])
            }
            var rows: [NSView] = []
            for provider in snapshot.providers {
                if !rows.isEmpty { rows.append(separator()) }
                rows.append(providerBlock(provider))
            }
            return verticalStack(rows, spacing: 14, fillWidth: Array(rows.indices))
        }
    }

    private func providerBlock(_ provider: QuotaProvider) -> NSView {
        let name = label(provider.name, font: .systemFont(ofSize: 14, weight: .semibold))
        var rows: [NSView] = [name]
        if let plan = provider.plan, !plan.isEmpty {
            rows.append(label(plan, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true))
        }
        rows.append(contentsOf: provider.windows.map(windowBlock))
        rows.append(contentsOf: provider.details.map {
            label($0, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
        })
        if provider.unavailable || (provider.windows.isEmpty && provider.details.isEmpty) {
            rows.append(label("额度明细暂不可用", color: .secondaryLabelColor, wraps: true))
        }
        return verticalStack(rows, spacing: 8, fillWidth: Array(rows.indices))
    }

    private func windowBlock(_ window: QuotaWindow) -> NSView {
        let remaining = min(1, max(0, 1 - window.usedPercent / 100))
        let percent = percentage.string(from: NSNumber(value: remaining)) ?? "—"
        let name = label(window.label)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let value = label("剩余 \(percent)", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [name, spacer, value])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        var rows: [NSView] = [heading, QuotaMeter(remaining: remaining)]
        if let date = window.resetsAt {
            rows.append(label("重置于 \(resetDate.string(from: date))", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true))
        } else if let description = window.resetDescription, !description.isEmpty {
            rows.append(label("重置 \(description)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true))
        }
        return verticalStack(rows, spacing: 5, fillWidth: Array(rows.indices))
    }

    private func label(_ text: String, font: NSFont = .systemFont(ofSize: 12),
                       color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat, fillWidth: [Int] = []) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for index in fillWidth {
            views[index].widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func separator() -> NSBox {
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func setupButton(_ title: String) -> NSButton {
        let button = QuotaPanelButton(title: title, target: self, action: #selector(setupRequested))
        button.bezelStyle = .rounded
        return button
    }

    private func resizeAndPlace() {
        guard let body else { return }
        let screen = anchor?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let width = min(Self.preferredWidth, available?.width ?? Self.preferredWidth)
        bodyWidthConstraint?.constant = max(1, width - 2 * Self.bodyMargin)
        document.layoutSubtreeIfNeeded()
        let contentHeight = ceil(body.fittingSize.height) + 28
        let topHeight = Self.headerHeight + (searchRowHeight?.constant ?? 0) + 1
        let maxHeight = min(Self.maximumBodyHeight, (available?.height ?? 600) - topHeight)
        let bodyHeight = min(max(serviceState == nil ? 72 : 300, contentHeight), max(1, maxHeight))
        let size = NSSize(width: width, height: topHeight + bodyHeight)
        document.setFrameSize(NSSize(width: width, height: max(contentHeight, bodyHeight)))
        if let anchor, let available {
            let origin = placement(size: size, beside: anchor.frame, inside: available)
            panel.setFrame(NSRect(origin: origin, size: size), display: panel.isVisible)
        } else {
            panel.setContentSize(size)
        }
        effect.layoutSubtreeIfNeeded()
    }

    private func placement(size: NSSize, beside pet: NSRect, inside available: NSRect) -> NSPoint {
        var x: CGFloat
        var y = pet.maxY - size.height
        if pet.maxX + Self.gap + size.width <= available.maxX {
            x = pet.maxX + Self.gap
        } else if pet.minX - Self.gap - size.width >= available.minX {
            x = pet.minX - Self.gap - size.width
        } else {
            x = pet.midX - size.width / 2
            if pet.maxY + Self.gap + size.height <= available.maxY {
                y = pet.maxY + Self.gap
            } else {
                y = pet.minY - Self.gap - size.height
            }
        }
        return NSPoint(
            x: min(max(x, available.minX), available.maxX - size.width),
            y: min(max(y, available.minY), available.maxY - size.height)
        )
    }

    private func startDismissalMonitors() {
        guard outsideClickMonitor == nil, localMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.onClose()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.onClose()
                return nil
            }
            if event.window !== self.panel && event.window !== self.anchor { self.onClose() }
            return event
        }
    }

    private func stopDismissalMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideClickMonitor = nil
        localMonitor = nil
    }

    @objc private func refreshRequested() {
        if serviceState != nil { onManage() } else { onRefresh() }
    }
    @objc private func manageRequested() { onManage() }
    @objc private func backRequested() { onBack() }
    @objc private func serviceToggled(_ sender: QuotaServiceToggle) {
        onToggleService(sender.serviceID, sender.state == .on)
    }
    @objc private func closeRequested() { onClose() }
    @objc private func setupRequested() { onSetup() }
}
