import AppKit

// MARK: - Shared helpers

/// capcap is an LSUIElement app with no main menu, so Cmd+C/V/X/A never reach
/// the field editor on their own. Route them through the responder chain.
private func dispatchEditingShortcut(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
        return false
    }
    let action: Selector
    switch event.charactersIgnoringModifiers {
    case "x": action = #selector(NSText.cut(_:))
    case "c": action = #selector(NSText.copy(_:))
    case "v": action = #selector(NSText.paste(_:))
    case "a": action = #selector(NSText.selectAll(_:))
    default: return false
    }
    return NSApp.sendAction(action, to: nil, from: nil)
}

/// NSTextView that honors copy/paste shortcuts without a menu.
final class PanelTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if dispatchEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Top-aligned content host for the scroll view's document.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A view whose entire surface is a click target.
private final class ClickableRow: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - OCR + Translation panel

/// Floating dialog shown after the OCR toolbar action. Top-left aligns with
/// the original selection: screenshot thumbnail, recognized text, then a
/// collapsible translation section per configured AI provider.
final class OCRTranslatePanel: NSPanel {

    private static var current: OCRTranslatePanel?

    private let screenshot: NSImage
    /// Screen-space top-left of the original selection rect.
    private let anchorTopLeft: NSPoint
    private let anchorScreen: NSScreen
    private let panelWidth: CGFloat

    private let padding: CGFloat = 14
    private var contentStack: NSStackView!
    private var docView: FlippedView!
    private var clipView: NSClipView!
    private var ocrTextView: PanelTextView!
    private var ocrCopyButton: NSButton!
    private var sections: [TranslationSectionView] = []
    private var keyMonitor: Any?
    private var ocrReady = false

    // MARK: Presentation

    static func present(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        current?.dismiss()
        let panel = OCRTranslatePanel(image: image, anchorRect: anchorRect, screen: screen)
        current = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.runOCR()
    }

    private init(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        self.screenshot = image
        self.anchorScreen = screen
        self.anchorTopLeft = NSPoint(x: anchorRect.minX, y: anchorRect.maxY)
        self.panelWidth = min(max(anchorRect.width, 360), 460)

        super.init(
            contentRect: NSRect(x: anchorRect.minX, y: anchorRect.maxY - 320,
                                width: panelWidth, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildUI()
        installKeyMonitor()
        refreshHeight()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: UI

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1.0).cgColor
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        root.layer?.borderWidth = 1
        contentView = root

        // Scrollable content.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)
        clipView = scrollView.contentView

        docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(contentStack)

        // Close button floats over the top-right corner.
        let closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        root.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -padding),

            docView.topAnchor.constraint(equalTo: contentStack.topAnchor),
            docView.heightAnchor.constraint(equalTo: contentStack.heightAnchor),
            docView.widthAnchor.constraint(equalTo: clipView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: docView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),

            closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        buildScreenshotCard()
        buildOCRCard()
        buildProviderSections()
    }

    private func addStackRow(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func buildScreenshotCard() {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = screenshot
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        imageView.layer?.borderWidth = 1

        let size = screenshot.size
        let aspect = size.width > 0 ? size.height / size.width : 0.5
        let contentWidth = panelWidth - padding * 2
        let height = min(max(contentWidth * aspect, 56), 240)
        imageView.heightAnchor.constraint(equalToConstant: height).isActive = true

        addStackRow(imageView)
    }

    private func buildOCRCard() {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        // Header: title + copy button.
        let title = makeLabel(L10n.ocrTextHeader, size: 12, weight: .semibold,
                              alpha: 0.92)
        ocrCopyButton = makeSmallButton(L10n.ocrCopy, action: #selector(copyOCRTapped))
        ocrCopyButton.target = self
        ocrCopyButton.isEnabled = false
        let header = NSStackView(views: [title, flexSpacer(), ocrCopyButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        // Recognized text — editable so the user can correct OCR before translating.
        let (scroll, textView) = makeTextScroll(editable: true, height: 104)
        ocrTextView = textView
        ocrTextView.string = L10n.ocrRecognizing
        ocrTextView.textColor = NSColor.white.withAlphaComponent(0.4)
        inner.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        addStackRow(card)
    }

    private func buildProviderSections() {
        let usable = TranslationConfigStore.usableKinds()
        guard !usable.isEmpty else {
            addStackRow(makeNoProviderCard())
            return
        }
        for kind in usable {
            let section = TranslationSectionView(kind: kind)
            section.translatesAutoresizingMaskIntoConstraints = false
            section.ocrTextProvider = { [weak self] in
                self?.ocrTextView.string ?? ""
            }
            section.onToggle = { [weak self] in self?.refreshHeight() }
            section.setEnabled(false) // unlocked once OCR finishes with text
            sections.append(section)
            addStackRow(section)
        }
    }

    private func makeNoProviderCard() -> NSView {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        let title = makeLabel(L10n.ocrNoProviderTitle, size: 12, weight: .semibold, alpha: 0.9)
        let hint = makeLabel(L10n.ocrNoProviderHint, size: 11, weight: .regular, alpha: 0.55)
        hint.lineBreakMode = .byWordWrapping
        hint.usesSingleLineMode = false
        hint.preferredMaxLayoutWidth = panelWidth - padding * 2 - 24
        let button = makeSmallButton(L10n.ocrOpenSettings, action: #selector(openSettingsTapped))
        button.target = self

        inner.addArrangedSubview(title)
        inner.addArrangedSubview(hint)
        inner.addArrangedSubview(button)
        return card
    }

    // MARK: OCR

    private func runOCR() {
        Task { @MainActor in
            let text = await OCRService.recognize(image: screenshot)
            self.ocrReady = true
            if text.isEmpty {
                self.ocrTextView.string = L10n.ocrNoText
                self.ocrTextView.textColor = NSColor.white.withAlphaComponent(0.4)
                self.ocrCopyButton.isEnabled = false
            } else {
                self.ocrTextView.string = text
                self.ocrTextView.textColor = NSColor.white.withAlphaComponent(0.9)
                self.ocrCopyButton.isEnabled = true
                for section in self.sections { section.setEnabled(true) }
            }
            self.refreshHeight()
        }
    }

    // MARK: Sizing

    /// Resizes the panel to fit its content while keeping the top-left corner
    /// pinned to the original selection.
    private func refreshHeight() {
        contentView?.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        let desired = contentHeight + padding * 2
        let visible = anchorScreen.visibleFrame
        let maxHeight = min(660, visible.height - 32)
        let height = max(180, min(desired, maxHeight))

        var originX = anchorTopLeft.x
        var originY = anchorTopLeft.y - height
        if originX + panelWidth > visible.maxX { originX = visible.maxX - panelWidth }
        if originX < visible.minX { originX = visible.minX }
        if originY < visible.minY { originY = visible.minY }
        if originY + height > visible.maxY { originY = visible.maxY - height }

        setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: height),
                 display: true, animate: false)
    }

    // MARK: Actions

    @objc private func closeTapped() { dismiss() }

    @objc private func openSettingsTapped() {
        SettingsWindowController.shared.showAsSettings()
        dismiss()
    }

    @objc private func copyOCRTapped() {
        guard ocrReady else { return }
        let text = ocrTextView.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashButton(ocrCopyButton, to: L10n.ocrCopied, restore: L10n.ocrCopy)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            if event.keyCode == 53 { // Escape
                self.dismiss()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        for section in sections { section.cancelTranslation() }
        orderOut(nil)
        if OCRTranslatePanel.current === self { OCRTranslatePanel.current = nil }
    }

    // MARK: Shared builders

    fileprivate static func styleCard(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        view.layer?.borderWidth = 1
    }

    private func makeCard() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        Self.styleCard(v)
        return v
    }

    private func makeCardStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
}

// MARK: - Free-standing builders

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = NSColor.white.withAlphaComponent(alpha)
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func flexSpacer() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return v
}

func makeSmallButton(_ title: String, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: nil, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .small
    b.font = NSFont.systemFont(ofSize: 11)
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
}

func pin(_ child: NSView, to parent: NSView, inset: CGFloat) {
    NSLayoutConstraint.activate([
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
}

/// A bordered scroll view wrapping a `PanelTextView` of fixed height.
func makeTextScroll(editable: Bool, height: CGFloat) -> (NSScrollView, PanelTextView) {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = NSColor.black.withAlphaComponent(0.22)
    scroll.borderType = .noBorder
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 6
    scroll.layer?.cornerCurve = .continuous
    scroll.layer?.masksToBounds = true
    scroll.heightAnchor.constraint(equalToConstant: height).isActive = true

    let textView = PanelTextView()
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: 12)
    textView.textColor = NSColor.white.withAlphaComponent(0.9)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = textView
    return (scroll, textView)
}

/// Flips a button title to a confirmation string for a moment.
func flashButton(_ button: NSButton, to confirm: String, restore: String) {
    button.title = confirm
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in
        button?.title = restore
    }
}

// MARK: - Translation section

/// One collapsible AI-provider translation block. Translation starts the
/// first time the section is expanded.
final class TranslationSectionView: NSView {
    let kind: TranslationProviderKind

    var ocrTextProvider: (() -> String)?
    /// Called after expand/collapse so the panel can resize.
    var onToggle: (() -> Void)?

    private let chevron = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyContainer = NSView()
    private var bodyTextView: PanelTextView!
    private var copyButton: NSButton!
    private var retryButton: NSButton!
    private var sectionStack: NSStackView!

    private var expanded = false
    private var didStart = false
    private var enabled = false
    private var task: Task<Void, Never>?

    init(kind: TranslationProviderKind) {
        self.kind = kind
        super.init(frame: .zero)
        OCRTranslatePanel.styleCard(self)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { task?.cancel() }

    private func buildUI() {
        sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 8
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionStack)
        pin(sectionStack, to: self, inset: 10)

        // Header row — clicking anywhere toggles.
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let title = makeLabel(kind.displayName, size: 12, weight: .semibold, alpha: 0.92)

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        let headerStack = NSStackView(views: [chevron, title, flexSpacer(), statusLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let header = ClickableRow()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.toggle() }
        header.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        sectionStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true

        // Body — translated text + actions.
        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])

        let (scroll, textView) = makeTextScroll(editable: false, height: 120)
        bodyTextView = textView
        bodyStack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        retryButton = makeSmallButton(L10n.ocrRetry, action: #selector(retryTapped))
        retryButton.target = self
        retryButton.isHidden = true
        copyButton = makeSmallButton(L10n.ocrCopy, action: #selector(copyTapped))
        copyButton.target = self

        let footer = NSStackView(views: [flexSpacer(), retryButton, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        sectionStack.addArrangedSubview(bodyContainer)
        bodyContainer.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        bodyContainer.isHidden = true
    }

    /// OCR-not-ready sections are dimmed and ignore clicks.
    func setEnabled(_ on: Bool) {
        enabled = on
        alphaValue = on ? 1.0 : 0.45
    }

    private func toggle() {
        guard enabled else { return }
        expanded.toggle()
        bodyContainer.isHidden = !expanded
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        if expanded { startTranslationIfNeeded() }
        onToggle?()
    }

    private func startTranslationIfNeeded() {
        guard !didStart else { return }
        runTranslation()
    }

    @objc private func retryTapped() { runTranslation() }

    private func runTranslation() {
        didStart = true
        task?.cancel()
        retryButton.isHidden = true

        let text = (ocrTextProvider?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusLabel.stringValue = L10n.ocrNoText
            bodyTextView.string = ""
            return
        }

        statusLabel.stringValue = L10n.ocrTranslating
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        bodyTextView.string = ""

        let config = TranslationConfigStore.load(kind)
        let target = Defaults.translationTargetLanguage
        let kind = self.kind

        task = Task { @MainActor [weak self] in
            do {
                let stream = TranslationService.stream(
                    text: text, target: target, kind: kind, config: config
                )
                for try await delta in stream {
                    guard let self else { return }
                    self.bodyTextView.string += delta
                    self.bodyTextView.scrollRangeToVisible(
                        NSRange(location: self.bodyTextView.string.count, length: 0)
                    )
                }
                self?.statusLabel.stringValue = ""
            } catch is CancellationError {
                // Panel closed or retried — nothing to show.
            } catch {
                guard let self else { return }
                self.statusLabel.stringValue = L10n.ocrTranslateFailedPrefix
                    + error.localizedDescription
                self.statusLabel.textColor = NSColor.systemOrange
                self.retryButton.isHidden = false
            }
        }
    }

    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bodyTextView.string, forType: .string)
        flashButton(copyButton, to: L10n.ocrCopied, restore: L10n.ocrCopy)
    }

    func cancelTranslation() {
        task?.cancel()
        task = nil
    }
}
