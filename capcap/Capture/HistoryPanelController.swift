import AppKit

private enum HistoryPanelLayout {
    static let headerTopInset: CGFloat = 12
    static let headerHeight: CGFloat = 34
    static let verticalGap: CGFloat = 12
}

final class HistoryPanelController {
    private var dialogPanel: NSPanel?
    private var dialogOutsideMonitors: [Any] = []
    private var notchController: HistoryNotchWindowController?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayModesChanged),
            name: .historyPanelDisplayModesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyCacheEnabledChanged),
            name: .historyCacheEnabledDidChange,
            object: nil
        )
        syncNotchAvailability()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        closeDialog()
        notchController?.close()
    }

    func toggleFromUserRequest() {
        guard Defaults.historyCacheEnabled else { return }
        if Defaults.historyPanelDialogEnabled {
            toggleDialog()
            return
        }
        if Defaults.historyPanelNotchEnabled {
            ensureNotchController().toggleFromUserRequest()
        }
    }

    @objc private func displayModesChanged() {
        syncNotchAvailability()
        if !Defaults.historyPanelDialogEnabled {
            closeDialog()
        }
    }

    @objc private func historyCacheEnabledChanged() {
        if !Defaults.historyCacheEnabled {
            closeDialog()
        }
        syncNotchAvailability()
    }

    private func syncNotchAvailability() {
        guard Defaults.historyCacheEnabled, Defaults.historyPanelNotchEnabled else {
            notchController?.close()
            notchController = nil
            return
        }
        _ = ensureNotchController()
    }

    private func ensureNotchController() -> HistoryNotchWindowController {
        if let notchController {
            return notchController
        }
        let controller = HistoryNotchWindowController()
        notchController = controller
        return controller
    }

    private func toggleDialog() {
        if dialogPanel?.isVisible == true {
            closeDialog()
        } else {
            showDialog()
        }
    }

    private func showDialog() {
        closeDialog()

        let screen = NSScreen.screenForMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(max(420, visible.width * 0.70), visible.width - 28)
        let height = HistoryPanelPresentation.dialog.panelHeight
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.maxY - height - 12,
            width: width,
            height: height
        )

        let panel = HistoryFloatingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true

        let chrome = HistoryPanelChromeView()
        chrome.frame = NSRect(origin: .zero, size: frame.size)
        chrome.autoresizingMask = [.width, .height]

        let content = HistoryPanelContentView(presentation: .dialog) { [weak self] in
            self?.closeDialog()
        }
        content.frame = chrome.bounds
        content.autoresizingMask = [.width, .height]
        chrome.addSubview(content)

        panel.contentView = chrome
        panel.orderFrontRegardless()
        dialogPanel = panel
        startDialogOutsideMonitoring(for: panel)
    }

    private func closeDialog() {
        stopDialogOutsideMonitoring()
        dialogPanel?.orderOut(nil)
        dialogPanel = nil
    }

    private func startDialogOutsideMonitoring(for panel: NSPanel) {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if !self.event(event, isInside: panel) {
                self.closeDialog()
            }
            return event
        }
        if let local {
            dialogOutsideMonitors.append(local)
        }

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            DispatchQueue.main.async {
                guard let self, let panel else { return }
                if !self.event(event, isInside: panel) {
                    self.closeDialog()
                }
            }
        }
        if let global {
            dialogOutsideMonitors.append(global)
        }
    }

    private func stopDialogOutsideMonitoring() {
        for monitor in dialogOutsideMonitors {
            NSEvent.removeMonitor(monitor)
        }
        dialogOutsideMonitors.removeAll()
    }

    private func event(_ event: NSEvent, isInside panel: NSPanel) -> Bool {
        let point: NSPoint
        if let eventWindow = event.window {
            point = eventWindow.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            point = NSEvent.mouseLocation
        }
        return panel.frame.contains(point)
    }
}

private final class HistoryFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HistoryPanelChromeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.86).cgColor
        layer?.borderColor = accentGreen.withAlphaComponent(0.34).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class HistoryNotchWindowController: NSWindowController {
    private let rootView = HistoryNotchRootView()
    private var hoverSampler: DispatchSourceTimer?
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var isCollapsing = false

    private let expandDelay: TimeInterval = 0.08
    private let collapseDelay: TimeInterval = 0.28
    private let collapseAnimationDuration: TimeInterval = 0.28
    private let sampleInterval: TimeInterval = 0.08

    init() {
        let screen = NSScreen.screenForMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        let frame = Self.frame(for: screen, expandedSize: rootView.expandedSize)
        let panel = HistoryFloatingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        rootView.frame = NSRect(origin: .zero, size: frame.size)
        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView

        super.init(window: panel)
        rootView.onRequestDismiss = { [weak self] in
            self?.collapse()
        }
        panel.orderFrontRegardless()
        startMouseMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        close()
    }

    override func close() {
        NotificationCenter.default.removeObserver(self)
        stopMouseMonitoring()
        super.close()
    }

    func toggleFromUserRequest() {
        if rootView.isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    private func expand() {
        guard !rootView.isExpanded else { return }
        isCollapsing = false
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        rootView.setExpanded(true, animated: true)
    }

    private func collapse() {
        guard rootView.isExpanded else { return }
        expandWorkItem?.cancel()
        expandWorkItem = nil
        rootView.setExpanded(false, animated: true)
        isCollapsing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseAnimationDuration) { [weak self] in
            guard let self, self.isCollapsing else { return }
            self.isCollapsing = false
            self.window?.ignoresMouseEvents = true
        }
    }

    private func startMouseMonitoring() {
        startHoverSampler()
    }

    private func stopMouseMonitoring() {
        stopHoverSampler()
        expandWorkItem?.cancel()
        collapseWorkItem?.cancel()
        expandWorkItem = nil
        collapseWorkItem = nil
    }

    private func startHoverSampler() {
        guard hoverSampler == nil else { return }
        let sampler = DispatchSource.makeTimerSource(queue: .main)
        sampler.schedule(deadline: .now(), repeating: sampleInterval, leeway: .milliseconds(20))
        sampler.setEventHandler { [weak self] in
            self?.handleMouseMove()
        }
        hoverSampler = sampler
        sampler.resume()
    }

    private func stopHoverSampler() {
        hoverSampler?.setEventHandler {}
        hoverSampler?.cancel()
        hoverSampler = nil
    }

    private func handleMouseMove() {
        guard let window else { return }
        if isCollapsing { return }
        let mouse = NSEvent.mouseLocation
        if rootView.isExpanded {
            let rect = visibleRect(in: window.frame, size: rootView.expandedSize).insetBy(dx: -24, dy: -14)
            if rect.contains(mouse) {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else {
                scheduleCollapse()
            }
        } else {
            let rect = collapsedHitRect().insetBy(dx: -14, dy: -8)
            if rect.contains(mouse) {
                scheduleExpand()
            } else {
                expandWorkItem?.cancel()
                expandWorkItem = nil
            }
        }
    }

    private func scheduleExpand() {
        guard expandWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.expandWorkItem = nil
            self?.expand()
        }
        expandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: workItem)
    }

    private func scheduleCollapse() {
        guard collapseWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.collapseWorkItem = nil
            self?.collapse()
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: workItem)
    }

    private func collapsedHitRect() -> NSRect {
        let screen = window?.screen ?? NSScreen.screenForMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let size = rootView.collapsedSize
        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - max(size.height, screen?.safeAreaInsets.top ?? size.height),
            width: size.width,
            height: max(size.height + 8, screen?.safeAreaInsets.top ?? size.height)
        )
    }

    private func visibleRect(in frame: NSRect, size: NSSize) -> NSRect {
        NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    @objc private func screenDidChange() {
        let screen = NSScreen.screenForMouseLocation() ?? window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        window?.setFrame(Self.frame(for: screen, expandedSize: rootView.expandedSize), display: true)
    }

    private static func frame(for screen: NSScreen?, expandedSize: NSSize) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(max(screenFrame.width * 0.74, expandedSize.width), screenFrame.width - 24)
        let height = expandedSize.height
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }
}

private final class HistoryNotchRootView: NSView {
    let collapsedSize = NSSize(width: 220, height: 32)
    let expandedSize = NSSize(width: 860, height: HistoryPanelPresentation.notch.panelHeight)

    private let shellView = HistoryNotchShellView()
    private let contentView = HistoryPanelContentView(presentation: .notch)
    private let collapsedLabel = NSTextField(labelWithString: "")
    private let countQueue = DispatchQueue(label: "capcap.historyNotchCount", qos: .utility)

    private(set) var isExpanded = false
    private var currentSize = NSSize(width: 220, height: 32)
    private var countGeneration = 0

    var onRequestDismiss: (() -> Void)? {
        didSet {
            contentView.onRequestDismiss = onRequestDismiss
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        shellView.frame = NSRect(origin: .zero, size: collapsedSize)
        shellView.autoresizingMask = []
        addSubview(shellView)

        contentView.alphaValue = 0
        contentView.isHidden = true
        shellView.addSubview(contentView)

        collapsedLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        collapsedLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        collapsedLabel.alignment = .center
        collapsedLabel.isSelectable = false
        shellView.addSubview(collapsedLabel)

        refreshCollapsedLabel()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshCollapsedLabel),
            name: .historyDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshCollapsedLabel),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutShell(animated: false)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        currentSize = expanded ? expandedSize : collapsedSize

        if expanded {
            contentView.isHidden = false
        } else {
            contentView.resetTransientState(animated: animated)
        }

        let changes = {
            self.layoutShell(animated: true)
            self.contentView.alphaValue = expanded ? 1 : 0
            self.collapsedLabel.alphaValue = expanded ? 0 : 1
            self.shellView.setExpanded(expanded)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                changes()
            } completionHandler: {
                self.contentView.isHidden = !expanded
            }
        } else {
            changes()
            contentView.isHidden = !expanded
        }
    }

    private func layoutShell(animated: Bool) {
        let frame = NSRect(
            x: bounds.midX - currentSize.width / 2,
            y: bounds.maxY - currentSize.height,
            width: currentSize.width,
            height: currentSize.height
        )
        if animated {
            shellView.animator().frame = frame
        } else {
            shellView.frame = frame
        }
        contentView.frame = shellView.bounds
        collapsedLabel.frame = NSRect(
            x: 16,
            y: shellView.bounds.midY - 9,
            width: shellView.bounds.width - 32,
            height: 18
        )
    }

    @objc private func refreshCollapsedLabel() {
        countGeneration += 1
        let generation = countGeneration
        let title = L10n.historyMenu
        collapsedLabel.stringValue = title
        countQueue.async { [weak self] in
            let count = HistoryManager.shared.entries().count
            DispatchQueue.main.async {
                guard let self, self.countGeneration == generation else { return }
                self.collapsedLabel.stringValue = "\(title) \(count)"
            }
        }
    }
}

private final class HistoryNotchShellView: NSView {
    private var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        applyLayer(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        applyLayer(animated: true)
    }

    private func applyLayer(animated: Bool) {
        let radius: CGFloat = isExpanded ? 18 : 14
        let updates = {
            self.layer?.cornerRadius = radius
            self.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.90).cgColor
            self.layer?.borderColor = accentGreen.withAlphaComponent(self.isExpanded ? 0.36 : 0.22).cgColor
            self.layer?.borderWidth = 1
        }
        guard animated else {
            updates()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            updates()
        }
    }
}

private enum HistoryPanelPresentation {
    case dialog
    case notch

    var tileWidth: CGFloat {
        switch self {
        case .dialog: return 180
        case .notch: return 168
        }
    }

    var tileHeight: CGFloat {
        switch self {
        case .dialog: return 146
        case .notch: return 134
        }
    }

    var previewHeight: CGFloat {
        switch self {
        case .dialog: return 98
        case .notch: return 88
        }
    }

    var outerInset: CGFloat {
        switch self {
        case .dialog: return 18
        case .notch: return 16
        }
    }

    var panelHeight: CGFloat {
        HistoryPanelLayout.headerTopInset
            + HistoryPanelLayout.headerHeight
            + HistoryPanelLayout.verticalGap
            + tileHeight
            + HistoryPanelLayout.verticalGap
    }
}

private enum HistoryPanelFilter: CaseIterable {
    case all
    case screenshots
    case gif
    case mp4
    case colors

    var title: String {
        switch self {
        case .all: return L10n.historyPanelFilterAll
        case .screenshots: return L10n.historyPanelFilterScreenshots
        case .gif: return L10n.historyPanelFilterGIF
        case .mp4: return L10n.historyPanelFilterMP4
        case .colors: return L10n.historyPanelFilterColors
        }
    }
}

private final class HistoryPanelContentView: NSView {
    private let presentation: HistoryPanelPresentation
    var onRequestDismiss: (() -> Void)?

    private var selectedFilter: HistoryPanelFilter = .all
    private var filterButtons: [HistoryPanelFilter: HistoryPanelFilterButton] = [:]
    private let entriesQueue = DispatchQueue(label: "capcap.historyPanelEntries", qos: .userInitiated)
    private let scrollView = NSScrollView()
    private let stripView = HistoryPanelStripView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let deleteButton = HistoryPanelDeleteButton()
    private let finderButton = HistoryPanelActionButton(symbolName: "folder", title: "")
    private var deleteButtonWidthConstraint: NSLayoutConstraint?
    private var confirmationDismissMonitor: Any?
    private weak var activeHoverTile: HistoryPanelTileView?
    private var reloadGeneration = 0
    private var isConfirmingDelete = false

    init(presentation: HistoryPanelPresentation, onRequestDismiss: (() -> Void)? = nil) {
        self.presentation = presentation
        self.onRequestDismiss = onRequestDismiss
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupUI()
        reloadEntries()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadEntries),
            name: .historyDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLocalization),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopConfirmationDismissMonitoring()
    }

    override func layout() {
        super.layout()
        layoutStrip()
    }

    private func setupUI() {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(toolbar)

        for filter in HistoryPanelFilter.allCases {
            let button = HistoryPanelFilterButton(filter: filter)
            button.target = self
            button.action = #selector(filterClicked(_:))
            filterButtons[filter] = button
            toolbar.addArrangedSubview(button)
        }
        updateFilterSelection()

        finderButton.target = self
        finderButton.action = #selector(showHistoryInFinderClicked)
        finderButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(finderButton)

        deleteButton.target = self
        deleteButton.action = #selector(deleteHistoryClicked)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(deleteButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.documentView = stripView
        addSubview(scrollView)

        emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let inset = presentation.outerInset
        let deleteWidth = deleteButton.widthAnchor.constraint(equalToConstant: HistoryPanelDeleteButton.collapsedWidth)
        deleteButtonWidthConstraint = deleteWidth
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: HistoryPanelLayout.headerTopInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            header.heightAnchor.constraint(equalToConstant: HistoryPanelLayout.headerHeight),

            toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            toolbar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),

            deleteButton.trailingAnchor.constraint(equalTo: finderButton.leadingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            deleteWidth,
            deleteButton.heightAnchor.constraint(equalToConstant: 28),

            finderButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            finderButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HistoryPanelLayout.verticalGap),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HistoryPanelLayout.verticalGap),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])

        refreshLocalization()
        startConfirmationDismissMonitoring()
    }

    @objc private func refreshLocalization() {
        for (filter, button) in filterButtons {
            button.title = filter.title
        }
        deleteButton.title = L10n.historyClear
        deleteButton.toolTip = L10n.historyClear
        finderButton.title = L10n.historyShowInFinder
        finderButton.toolTip = L10n.historyShowInFinder
        if isConfirmingDelete {
            deleteButtonWidthConstraint?.constant = deleteButton.expandedWidth
        }
        emptyLabel.stringValue = L10n.historyPanelEmpty
        reloadEntries()
    }

    @objc private func filterClicked(_ sender: HistoryPanelFilterButton) {
        selectedFilter = sender.filter
        updateFilterSelection()
        reloadEntries()
    }

    private func updateFilterSelection() {
        for (filter, button) in filterButtons {
            button.isSelected = filter == selectedFilter
        }
    }

    @objc private func deleteHistoryClicked() {
        guard deleteButton.isEnabled else { return }
        if isConfirmingDelete {
            HistoryManager.shared.clearAll {
                ToastWindow.show(message: L10n.historyCleared)
            }
            setDeleteConfirmation(false, animated: false)
            onRequestDismiss?()
        } else {
            setDeleteConfirmation(true, animated: true)
        }
    }

    @objc private func showHistoryInFinderClicked() {
        setDeleteConfirmation(false, animated: true)
        NSWorkspace.shared.open(HistoryManager.shared.cacheDirectoryURL())
        onRequestDismiss?()
    }

    @objc private func reloadEntries() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let filter = selectedFilter
        entriesQueue.async { [weak self] in
            let allEntries = HistoryManager.shared.entries()
            let entries = Self.filteredEntries(from: allEntries, filter: filter)
            DispatchQueue.main.async {
                guard let self, self.reloadGeneration == generation else { return }
                self.applyEntries(entries, hasAnyEntries: !allEntries.isEmpty)
            }
        }
    }

    private func applyEntries(_ entries: [HistoryEntry], hasAnyEntries: Bool) {
        activeHoverTile?.setHovered(false)
        activeHoverTile = nil
        stripView.subviews.forEach { $0.removeFromSuperview() }
        for entry in entries {
            let tile = HistoryPanelTileView(
                entry: entry,
                presentation: presentation,
                onRequestDismiss: { [weak self] in
                    self?.onRequestDismiss?()
                },
                onHoverChanged: { [weak self] tile, isHovered in
                    self?.updateActiveHoverTile(tile, isHovered: isHovered)
                }
            )
            stripView.addSubview(tile)
        }
        deleteButton.isEnabled = hasAnyEntries
        deleteButton.alphaValue = deleteButton.isEnabled ? 1 : 0.35
        if !hasAnyEntries {
            setDeleteConfirmation(false, animated: true)
        }
        emptyLabel.isHidden = !entries.isEmpty
        layoutStrip()
    }

    private func setDeleteConfirmation(_ confirming: Bool, animated: Bool) {
        guard isConfirmingDelete != confirming else { return }
        isConfirmingDelete = confirming
        let width = confirming ? deleteButton.expandedWidth : HistoryPanelDeleteButton.collapsedWidth

        guard animated else {
            deleteButtonWidthConstraint?.constant = width
            deleteButton.setConfirming(confirming, animated: false)
            layoutSubtreeIfNeeded()
            return
        }

        layoutSubtreeIfNeeded()
        deleteButton.setConfirming(confirming, animated: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            deleteButtonWidthConstraint?.constant = width
            animator().layoutSubtreeIfNeeded()
        }
    }

    func resetTransientState(animated: Bool) {
        setDeleteConfirmation(false, animated: animated)
        activeHoverTile?.setHovered(false)
        activeHoverTile = nil
    }

    private func updateActiveHoverTile(_ tile: HistoryPanelTileView, isHovered: Bool) {
        if isHovered {
            if activeHoverTile !== tile {
                activeHoverTile?.setHovered(false)
                activeHoverTile = tile
            }
            tile.setHovered(true)
        } else if activeHoverTile === tile {
            tile.setHovered(false)
            activeHoverTile = nil
        } else {
            tile.setHovered(false)
        }
    }

    private func startConfirmationDismissMonitoring() {
        guard confirmationDismissMonitor == nil else { return }
        confirmationDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.collapseDeleteConfirmationIfNeeded(for: event)
            return event
        }
    }

    private func stopConfirmationDismissMonitoring() {
        if let confirmationDismissMonitor {
            NSEvent.removeMonitor(confirmationDismissMonitor)
            self.confirmationDismissMonitor = nil
        }
    }

    private func collapseDeleteConfirmationIfNeeded(for event: NSEvent) {
        guard isConfirmingDelete else { return }
        guard let eventWindow = event.window, let hostWindow = window, eventWindow === hostWindow else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        let deleteRect = deleteButton.convert(deleteButton.bounds, to: self)
        if !deleteRect.contains(point) {
            setDeleteConfirmation(false, animated: true)
        }
    }

    private static func filteredEntries(from entries: [HistoryEntry], filter: HistoryPanelFilter) -> [HistoryEntry] {
        entries.filter { entry in
            switch filter {
            case .all:
                return true
            case .screenshots:
                guard case .image = entry.kind else { return false }
                return entry.fileURL.pathExtension.lowercased() != "gif"
            case .gif:
                guard case .image = entry.kind else { return false }
                return entry.fileURL.pathExtension.lowercased() == "gif"
            case .mp4:
                guard case .video = entry.kind else { return false }
                return true
            case .colors:
                guard case .color = entry.kind else { return false }
                return true
            }
        }
    }

    private func layoutStrip() {
        let tileWidth = presentation.tileWidth
        let tileHeight = presentation.tileHeight
        let gap: CGFloat = 14
        var x: CGFloat = 0
        for tile in stripView.subviews {
            tile.frame = NSRect(x: x, y: 0, width: tileWidth, height: tileHeight)
            x += tileWidth + gap
        }
        let totalWidth = max(scrollView.contentSize.width, x > 0 ? x - gap : 0)
        stripView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: tileHeight)
    }
}

private final class HistoryPanelStripView: NSView {
    override var isFlipped: Bool { true }
}

private final class HistoryPanelCenteredTextView: NSView {
    var stringValue: String = "" {
        didSet { needsDisplay = true }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 13, weight: .semibold) {
        didSet { needsDisplay = true }
    }

    var textColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    var alignment: NSTextAlignment = .center {
        didSet { needsDisplay = true }
    }

    var horizontalInset: CGFloat = 8 {
        didSet { needsDisplay = true }
    }

    override var toolTip: String? {
        didSet { super.toolTip = toolTip }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !stringValue.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: stringValue, attributes: attributes)
        let textBounds = bounds.insetBy(dx: horizontalInset, dy: 0)
        let measured = attributed.boundingRect(
            with: NSSize(width: textBounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textRect = NSRect(
            x: textBounds.minX,
            y: textBounds.midY - ceil(measured.height) / 2,
            width: textBounds.width,
            height: ceil(measured.height)
        )
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

private final class HistoryPanelDeleteButton: NSControl {
    static let collapsedWidth: CGFloat = 28
    static let minimumExpandedWidth: CGFloat = 96
    private static let iconSize: CGFloat = 14
    private static let contentSpacing: CGFloat = 8
    private static let horizontalPadding: CGFloat = 12

    private let iconView = NSImageView()
    private let label = HistoryPanelCenteredTextView()
    private var isConfirming = false

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    var expandedWidth: CGFloat {
        let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font]).width)
        return max(
            Self.minimumExpandedWidth,
            Self.iconSize + Self.contentSpacing + textWidth + Self.horizontalPadding * 2
        )
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.35
        }
    }

    override var toolTip: String? {
        didSet {
            iconView.toolTip = toolTip
            label.toolTip = toolTip
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L10n.historyClear)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor.systemRed.withAlphaComponent(0.88)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .left
        label.horizontalInset = 0
        label.alphaValue = 0
        addSubview(label)

        setConfirming(false, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let textWidth = isConfirming
            ? min(
                max(0, bounds.width - Self.iconSize - Self.contentSpacing - Self.horizontalPadding * 2),
                ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font]).width)
            )
            : 0
        let groupWidth = isConfirming ? Self.iconSize + Self.contentSpacing + textWidth : Self.iconSize
        let groupStartX = max(0, bounds.midX - groupWidth / 2)

        iconView.frame = NSRect(
            x: groupStartX,
            y: bounds.midY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        label.frame = NSRect(
            x: iconView.frame.maxX + Self.contentSpacing,
            y: 0,
            width: textWidth,
            height: bounds.height
        )
    }

    func setConfirming(_ confirming: Bool, animated: Bool) {
        layoutSubtreeIfNeeded()
        isConfirming = confirming

        let backgroundColor = confirming
            ? NSColor.systemRed.withAlphaComponent(0.86).cgColor
            : NSColor.clear.cgColor
        layer?.backgroundColor = backgroundColor
        iconView.contentTintColor = confirming
            ? .white
            : NSColor.systemRed.withAlphaComponent(0.88)

        guard animated else {
            label.alphaValue = confirming ? 1 : 0
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }

        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            label.animator().alphaValue = confirming ? 1 : 0
            animator().layoutSubtreeIfNeeded()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class HistoryPanelActionButton: NSControl {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    override var toolTip: String? {
        didSet {
            iconView.toolTip = toolTip
            label.toolTip = toolTip
        }
    }

    init(symbolName: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.68)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.68)
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 46, height: 28)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class HistoryPanelFilterButton: NSControl {
    let filter: HistoryPanelFilter
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var isSelected: Bool = false {
        didSet { applyAppearance() }
    }

    init(filter: HistoryPanelFilter) {
        self.filter = filter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.isSelectable = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        title = filter.title
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 36, height: 28)
    }

    private func applyAppearance() {
        if isSelected {
            layer?.backgroundColor = accentGreen.withAlphaComponent(0.95).cgColor
            label.textColor = .black
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            label.textColor = NSColor.white.withAlphaComponent(0.66)
        }
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}

private final class HistoryPanelTileView: NSView, NSDraggingSource {
    private let entry: HistoryEntry
    private let presentation: HistoryPanelPresentation
    private let onRequestDismiss: (() -> Void)?
    private let onHoverChanged: ((HistoryPanelTileView, Bool) -> Void)?
    private let imageView = NSImageView()
    private let overlayLabel = HistoryPanelCenteredTextView()
    private let badgeView = HistoryMediaBadgeView()
    private let metaLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var previewRequest: HistoryImagePreviewRequest?
    private var mouseDownPoint: NSPoint?
    private var isHovered = false
    private var didStartDrag = false
    private var didDismissForCurrentDrag = false

    init(
        entry: HistoryEntry,
        presentation: HistoryPanelPresentation,
        onRequestDismiss: (() -> Void)? = nil,
        onHoverChanged: ((HistoryPanelTileView, Bool) -> Void)? = nil
    ) {
        self.entry = entry
        self.presentation = presentation
        self.onRequestDismiss = onRequestDismiss
        self.onHoverChanged = onHoverChanged
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 1

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        addSubview(imageView)

        overlayLabel.stringValue = supportsDrag ? L10n.historyPanelCopyDragHint : L10n.historyPanelCopyHint
        overlayLabel.font = NSFont.systemFont(ofSize: presentation == .dialog ? 13 : 12, weight: .bold)
        overlayLabel.textColor = .white
        overlayLabel.alignment = .center
        overlayLabel.horizontalInset = 10
        overlayLabel.alphaValue = 0
        overlayLabel.layer?.cornerRadius = 5
        overlayLabel.layer?.cornerCurve = .continuous
        overlayLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.56).cgColor
        addSubview(overlayLabel)

        if let badgeKind = HistoryMediaBadgeKind(entry: entry) {
            badgeView.title = badgeKind.title
            badgeView.isHidden = false
        } else {
            badgeView.isHidden = true
        }
        addSubview(badgeView)

        metaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        metaLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        metaLabel.alignment = .center
        addSubview(metaLabel)

        loadEntryPreview()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        previewRequest?.cancel()
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let padding: CGFloat = 12
        imageView.frame = NSRect(
            x: padding,
            y: padding,
            width: bounds.width - padding * 2,
            height: presentation.previewHeight
        )
        overlayLabel.frame = imageView.frame
        if !badgeView.isHidden {
            let badgeSize = badgeView.intrinsicContentSize
            badgeView.frame = NSRect(
                x: imageView.frame.maxX - badgeSize.width - 7,
                y: imageView.frame.minY + 7,
                width: badgeSize.width,
                height: badgeSize.height
            )
        }
        metaLabel.frame = NSRect(
            x: padding,
            y: imageView.frame.maxY + 9,
            width: bounds.width - padding * 2,
            height: 18
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if let onHoverChanged {
            onHoverChanged(self, true)
        } else {
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let onHoverChanged {
            onHoverChanged(self, false)
        } else {
            setHovered(false)
        }
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        layer?.borderColor = hovered
            ? accentGreen.withAlphaComponent(0.80).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.backgroundColor = hovered
            ? NSColor.white.withAlphaComponent(0.11).cgColor
            : NSColor.white.withAlphaComponent(0.075).cgColor
        overlayLabel.alphaValue = hovered ? 1 : 0
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        didDismissForCurrentDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        guard hypot(dx, dy) > 4 else { return }
        didStartDrag = true
        guard supportsDrag else { return }

        let item = NSDraggingItem(pasteboardWriter: entry.fileURL as NSURL)
        let draggingImage = imageView.image
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            ?? NSImage(size: imageView.bounds.size)
        item.setDraggingFrame(imageView.frame, contents: draggingImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private var supportsDrag: Bool {
        guard case .color = entry.kind else { return true }
        return false
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            didStartDrag = false
            mouseDownPoint = nil
        }
        guard !didStartDrag else { return }
        if HistoryPanelEntryActions.copy(entry) {
            onRequestDismiss?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard !didDismissForCurrentDrag else { return }
        guard let window, !window.frame.contains(screenPoint) else { return }
        didDismissForCurrentDrag = true
        DispatchQueue.main.async { [weak self] in
            self?.onRequestDismiss?()
        }
    }

    private func loadEntryPreview() {
        switch entry.kind {
        case .image:
            loadPreview()
        case .video:
            loadVideoPreview()
        case .color(let hex):
            configureColorPreview(hex: hex)
        }
    }

    private func loadPreview() {
        let pixelSize = Int(max(presentation.tileWidth, presentation.previewHeight) * (NSScreen.main?.backingScaleFactor ?? 2))
        let url = entry.fileURL
        previewRequest?.cancel()
        previewRequest = HistoryImagePreviewLoader.shared.load(url: url, pixelSize: pixelSize) { [weak self] preview in
            guard let self, self.entry.fileURL == url else { return }
            if let cgImage = preview.cgImage {
                self.imageView.image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                self.imageView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            self.metaLabel.stringValue = HistoryImagePreview.metadata(
                pixelWidth: preview.pixelWidth,
                pixelHeight: preview.pixelHeight,
                date: self.entry.createdAt
            )
        }
    }

    private func loadVideoPreview() {
        configureVideoPlaceholder()
        let pixelSize = Int(max(presentation.tileWidth, presentation.previewHeight) * (NSScreen.main?.backingScaleFactor ?? 2))
        let url = entry.fileURL
        previewRequest?.cancel()
        previewRequest = HistoryImagePreviewLoader.shared.loadVideoFrame(url: url, pixelSize: pixelSize) { [weak self] preview in
            guard let self, self.entry.fileURL == url else { return }
            if let cgImage = preview.cgImage {
                self.imageView.image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                self.imageView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            if preview.pixelWidth > 0, preview.pixelHeight > 0 {
                self.metaLabel.stringValue = HistoryImagePreview.metadata(
                    pixelWidth: preview.pixelWidth,
                    pixelHeight: preview.pixelHeight,
                    date: self.entry.createdAt
                )
            }
        }
    }

    private func configureVideoPlaceholder() {
        let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        let image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: L10n.historyPanelFilterMP4)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        imageView.image = image
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.34).cgColor
        metaLabel.stringValue = Self.metadata(label: L10n.historyPanelFilterMP4, date: entry.createdAt)
    }

    private func configureColorPreview(hex: String) {
        imageView.image = nil
        imageView.layer?.backgroundColor = (NSColor(hex: hex) ?? .black).cgColor
        metaLabel.stringValue = Self.metadata(label: hex.uppercased(), date: entry.createdAt)
    }

    private static func metadata(label: String, date: Date) -> String {
        "\(label)  ·  \(dateFormatter.string(from: date))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum HistoryPanelEntryActions {
    static func copy(_ entry: HistoryEntry) -> Bool {
        switch entry.kind {
        case .image:
            if let cloudURL = entry.cloudURL {
                let asMarkdown = NSEvent.modifierFlags.contains(.command)
                let copyText = asMarkdown
                    ? "![](\(cloudURL.absoluteString))"
                    : cloudURL.absoluteString
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(copyText, forType: .string)
                ToastWindow.show(message: asMarkdown ? L10n.uploadCopiedMarkdown : L10n.uploadCopied)
                return true
            }

            guard let image = NSImage(contentsOf: entry.fileURL) else { return false }
            ClipboardManager.copyToClipboard(image: image)
            ToastWindow.show()
            return true
        case .video:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([entry.fileURL as NSURL])
            ToastWindow.show(message: L10n.copiedToClipboard)
            return true
        case .color(let hex):
            ClipboardManager.copyToClipboard(text: hex.uppercased())
            ToastWindow.show(message: L10n.colorCopied(hex.uppercased()))
            return true
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

private extension NSScreen {
    static func screenForMouseLocation() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }
}
