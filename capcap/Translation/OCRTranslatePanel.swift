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

// MARK: - OCR image preview

private final class OCRPreviewView: NSView {
    private let image: NSImage
    var showsLineBoxes = false {
        didSet { needsDisplay = true }
    }
    var lines: [RecognizedTextLine] = [] {
        didSet { needsDisplay = true }
    }
    var onCopyText: ((String) -> Void)?

    private var copiedLineIndex: Int?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let imageRect = fittedImageRect()
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        NSColor.black.withAlphaComponent(0.26).setFill()
        bounds.fill()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        if showsLineBoxes {
            for (index, line) in lines.enumerated() {
                let rect = displayRect(for: line.boundingBox, in: imageRect)
                    .insetBy(dx: -2, dy: -1)
                guard rect.width > 2, rect.height > 2 else { continue }
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                let isCopied = index == copiedLineIndex
                (isCopied
                    ? NSColor.systemGreen.withAlphaComponent(0.24)
                    : NSColor.systemTeal.withAlphaComponent(0.12)
                ).setFill()
                path.fill()
                (isCopied
                    ? NSColor.systemGreen.withAlphaComponent(0.95)
                    : NSColor.systemTeal.withAlphaComponent(0.88)
                ).setStroke()
                path.lineWidth = isCopied ? 2 : 1.2
                path.stroke()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard showsLineBoxes else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = fittedImageRect()
        for (index, line) in lines.enumerated().reversed() {
            let rect = displayRect(for: line.boundingBox, in: imageRect).insetBy(dx: -4, dy: -3)
            guard rect.contains(point) else { continue }
            copiedLineIndex = index
            onCopyText?(line.text)
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard self?.copiedLineIndex == index else { return }
                self?.copiedLineIndex = nil
                self?.needsDisplay = true
            }
            return
        }
        super.mouseDown(with: event)
    }

    private func fittedImageRect() -> NSRect {
        guard image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func displayRect(for normalizedRect: CGRect, in imageRect: NSRect) -> NSRect {
        NSRect(
            x: imageRect.minX + normalizedRect.minX * imageRect.width,
            y: imageRect.minY + normalizedRect.minY * imageRect.height,
            width: normalizedRect.width * imageRect.width,
            height: normalizedRect.height * imageRect.height
        )
    }
}

// MARK: - OCR / screenshot translation panel

/// Floating dialog shown after text recognition or screenshot translation.
/// It stays centered near the top of the target screen.
final class OCRTranslatePanel: NSPanel {

    private enum Mode {
        case textRecognition
        case screenshotTranslation
    }

    private static var current: OCRTranslatePanel?
    private static let topMargin: CGFloat = 24

    private let screenshot: NSImage
    private let anchorScreen: NSScreen
    private let panelWidth: CGFloat
    private let mode: Mode

    private let padding: CGFloat = 14
    private var contentStack: NSStackView!
    private var docView: FlippedView!
    private var clipView: NSClipView!
    private var previewView: OCRPreviewView!

    private var ocrTextView: PanelTextView?
    private var ocrCopyButton: NSButton?
    private var translationTextView: PanelTextView?
    private var translationStatusLabel: NSTextField?
    private var translationProviderLabel: NSTextField?
    private var translationCopyButton: NSButton?
    private var translationRetryButton: NSButton?
    private var translationLanguageButton: NSButton?

    private var keyMonitor: Any?
    private var languagePopover: NSPopover?
    private var translationTask: Task<Void, Never>?
    private var recognizedText = ""
    private var ocrReady = false
    private var selectedTarget = TranslationLanguage.appDefault

    // MARK: Presentation

    static func present(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        presentTextRecognition(image: image, anchorRect: anchorRect, screen: screen)
    }

    static func presentTextRecognition(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        present(image: image, anchorRect: anchorRect, screen: screen, mode: .textRecognition)
    }

    static func presentScreenshotTranslation(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        present(image: image, anchorRect: anchorRect, screen: screen, mode: .screenshotTranslation)
    }

    private static func present(image: NSImage, anchorRect: NSRect, screen: NSScreen, mode: Mode) {
        current?.dismiss()
        let panel = OCRTranslatePanel(image: image, anchorRect: anchorRect, screen: screen, mode: mode)
        current = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.runOCR()
    }

    private init(image: NSImage, anchorRect: NSRect, screen: NSScreen, mode: Mode) {
        let panelWidth = min(max(anchorRect.width, 360), 500)
        self.screenshot = image
        self.anchorScreen = screen
        self.panelWidth = panelWidth
        self.mode = mode
        let initialHeight: CGFloat = 320
        let initialFrame = Self.topCenteredFrame(
            width: panelWidth,
            height: initialHeight,
            on: screen
        )

        super.init(
            contentRect: initialFrame,
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
        switch mode {
        case .textRecognition:
            buildOCRCard()
        case .screenshotTranslation:
            buildTranslationCard()
        }
    }

    private func addStackRow(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func buildScreenshotCard() {
        previewView = OCRPreviewView(image: screenshot)
        previewView.showsLineBoxes = mode == .textRecognition
        previewView.onCopyText = { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ToastWindow.show(message: L10n.ocrLineCopied, duration: 0.9)
            if let button = self?.ocrCopyButton {
                flashButton(button, to: L10n.ocrCopied, restore: L10n.ocrCopy)
            }
        }

        let size = screenshot.size
        let aspect = size.width > 0 ? size.height / size.width : 0.5
        let contentWidth = panelWidth - padding * 2
        let height = min(max(contentWidth * aspect, 64), 260)
        previewView.heightAnchor.constraint(equalToConstant: height).isActive = true

        addStackRow(previewView)
    }

    private func buildOCRCard() {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        let title = makeLabel(L10n.ocrTextHeader, size: 12, weight: .semibold, alpha: 0.92)
        let copyButton = makeSmallButton(L10n.ocrCopy, action: #selector(copyOCRTapped))
        copyButton.target = self
        copyButton.isEnabled = false
        ocrCopyButton = copyButton

        let header = NSStackView(views: [title, flexSpacer(), copyButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let (scroll, textView) = makeTextScroll(editable: true, height: 116)
        textView.string = L10n.ocrRecognizing
        textView.textColor = NSColor.white.withAlphaComponent(0.4)
        ocrTextView = textView
        inner.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        addStackRow(card)
    }

    private func buildTranslationCard() {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        let title = makeLabel(L10n.screenshotTranslationHeader, size: 12, weight: .semibold, alpha: 0.92)

        let provider = makeLabel("", size: 10, weight: .medium, alpha: 0.48)
        translationProviderLabel = provider

        let languageButton = makeSmallButton(languageButtonTitle(), action: #selector(languageTapped))
        languageButton.target = self
        translationLanguageButton = languageButton

        let header = NSStackView(views: [title, provider, flexSpacer(), languageButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let status = makeLabel(L10n.ocrRecognizing, size: 11, weight: .medium, alpha: 0.52)
        translationStatusLabel = status
        inner.addArrangedSubview(status)

        let (scroll, textView) = makeTextScroll(editable: false, height: 156)
        textView.string = ""
        translationTextView = textView
        inner.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let retryButton = makeSmallButton(L10n.ocrRetry, action: #selector(translationRetryTapped))
        retryButton.target = self
        retryButton.isHidden = true
        translationRetryButton = retryButton

        let copyButton = makeSmallButton(L10n.ocrCopy, action: #selector(copyTranslationTapped))
        copyButton.target = self
        copyButton.isEnabled = false
        translationCopyButton = copyButton

        let footer = NSStackView(views: [flexSpacer(), retryButton, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        addStackRow(card)
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

    // MARK: OCR / Translation

    private func runOCR() {
        Task { @MainActor in
            let lines = await OCRService.recognizeLines(image: screenshot)
            self.previewView.lines = lines
            self.recognizedText = lines.map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.ocrReady = true

            switch self.mode {
            case .textRecognition:
                self.finishTextRecognition()
            case .screenshotTranslation:
                self.finishOCRAndStartTranslation()
            }
            self.refreshHeight()
        }
    }

    private func finishTextRecognition() {
        guard let textView = ocrTextView, let copyButton = ocrCopyButton else { return }
        if recognizedText.isEmpty {
            textView.string = L10n.ocrNoText
            textView.textColor = NSColor.white.withAlphaComponent(0.4)
            copyButton.isEnabled = false
        } else {
            textView.string = recognizedText
            textView.textColor = NSColor.white.withAlphaComponent(0.9)
            copyButton.isEnabled = true
        }
    }

    private func finishOCRAndStartTranslation() {
        guard !recognizedText.isEmpty else {
            translationStatusLabel?.stringValue = L10n.ocrNoText
            translationTextView?.string = ""
            translationCopyButton?.isEnabled = false
            return
        }
        runTranslation(target: selectedTarget)
    }

    private func runTranslation(target: TranslationLanguage) {
        translationTask?.cancel()
        translationRetryButton?.isHidden = true
        translationCopyButton?.isEnabled = false
        translationTextView?.string = ""
        translationStatusLabel?.stringValue = L10n.ocrTranslating
        translationStatusLabel?.textColor = NSColor.white.withAlphaComponent(0.52)

        guard let kind = TranslationConfigStore.usableKinds().first else {
            translationStatusLabel?.stringValue = L10n.ocrNoProviderTitle
            translationTextView?.string = L10n.ocrNoProviderHint
            translationProviderLabel?.stringValue = ""
            translationRetryButton?.isHidden = true
            return
        }

        translationProviderLabel?.stringValue = kind.displayName
        let config = TranslationConfigStore.load(kind)
        let text = recognizedText

        translationTask = Task { @MainActor [weak self] in
            do {
                let stream = TranslationService.stream(
                    text: text, target: target, kind: kind, config: config
                )
                for try await delta in stream {
                    guard let self else { return }
                    self.translationTextView?.string += delta
                    if let textView = self.translationTextView {
                        textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))
                    }
                }
                guard let self else { return }
                self.translationStatusLabel?.stringValue = ""
                self.translationCopyButton?.isEnabled = self.translationTextView?.string.isEmpty == false
            } catch is CancellationError {
                // Panel closed, retried, or target language changed.
            } catch {
                guard let self else { return }
                self.translationStatusLabel?.stringValue = L10n.ocrTranslateFailedPrefix
                    + error.localizedDescription
                self.translationStatusLabel?.textColor = NSColor.systemOrange
                self.translationRetryButton?.isHidden = false
            }
        }
    }

    // MARK: Sizing

    /// Resizes the panel to fit its content while keeping it centered near the
    /// top of the target screen.
    private func refreshHeight() {
        contentView?.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        let desired = contentHeight + padding * 2
        let visible = anchorScreen.visibleFrame
        let maxHeight = min(700, visible.height - Self.topMargin - 16)
        let height = max(180, min(desired, maxHeight))

        setFrame(Self.topCenteredFrame(width: panelWidth, height: height, on: anchorScreen),
                 display: true, animate: false)
    }

    private static func topCenteredFrame(width: CGFloat, height: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let originX = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        let originY = visible.maxY - topMargin - height
        return NSRect(x: originX, y: max(originY, visible.minY), width: width, height: height)
    }

    // MARK: Actions

    @objc private func closeTapped() { dismiss() }

    @objc private func openSettingsTapped() {
        SettingsWindowController.shared.showAsSettings()
        dismiss()
    }

    @objc private func copyOCRTapped() {
        guard ocrReady, !recognizedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedText, forType: .string)
        if let button = ocrCopyButton {
            flashButton(button, to: L10n.ocrCopied, restore: L10n.ocrCopy)
        }
    }

    @objc private func copyTranslationTapped() {
        guard let text = translationTextView?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let button = translationCopyButton {
            flashButton(button, to: L10n.ocrCopied, restore: L10n.ocrCopy)
        }
    }

    @objc private func translationRetryTapped() {
        guard !recognizedText.isEmpty else { return }
        runTranslation(target: selectedTarget)
    }

    @objc private func languageTapped() {
        languagePopover?.performClose(nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = LanguagePickerView(selected: selectedTarget) { [weak self, weak popover] language in
            popover?.performClose(nil)
            self?.selectTargetLanguage(language)
        }
        popover.contentViewController = controller
        languagePopover = popover

        if let button = translationLanguageButton {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    private func selectTargetLanguage(_ language: TranslationLanguage) {
        guard selectedTarget != language else { return }
        selectedTarget = language
        translationLanguageButton?.title = languageButtonTitle()
        if !recognizedText.isEmpty {
            runTranslation(target: language)
        }
    }

    private func languageButtonTitle() -> String {
        L10n.screenshotTranslationLanguageButton(selectedTarget.displayName)
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
        translationTask?.cancel()
        translationTask = nil
        languagePopover?.performClose(nil)
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

private final class LanguagePickerView: NSView {
    private var sleeves: [ClosureSleeve] = []

    init(selected: TranslationLanguage, onSelect: @escaping (TranslationLanguage) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 1))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for language in TranslationLanguage.allCases {
            let title = language == selected ? "✓ \(language.displayName)" : language.displayName
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.font = NSFont.systemFont(ofSize: 12, weight: language == selected ? .semibold : .regular)
            button.contentTintColor = NSColor.white.withAlphaComponent(language == selected ? 0.95 : 0.78)
            button.translatesAutoresizingMaskIntoConstraints = false
            let sleeve = ClosureSleeve { onSelect(language) }
            sleeves.append(sleeve)
            button.target = sleeve
            button.action = #selector(ClosureSleeve.invoke)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(equalToConstant: 220),
        ])

        let height = CGFloat(TranslationLanguage.allCases.count) * 26 + 16
        frame.size = NSSize(width: 220, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ClosureSleeve: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    @objc func invoke() { closure() }
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
