import AppKit

/// Where a pinned image was loaded from — drives the X-key "close and clear
/// source" behavior so a stale Finder selection or clipboard image won't keep
/// re-pinning on the next hotkey press.
enum PinSource {
    case finder
    case clipboard
}

/// A borderless, always-on-top window that holds a pinned image. Unlike a plain
/// borderless `NSWindow` it can become key, so it receives keystrokes: Esc
/// closes it, X closes it and clears the source it came from.
final class PinWindow: NSWindow {
    /// Set when the pin came from a hotkey press. nil for editor-created pins,
    /// which have no external source to clear.
    var pinSource: PinSource?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            dismissClearingSource()
        case 53: // Esc — close only.
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    /// Tears the window down and drops it from the manager so it deallocates.
    func dismiss() {
        orderOut(nil)
        contentView = nil
        PinWindowManager.shared.remove(self)
    }

    func dismissClearingSource() {
        clearSource()
        dismiss()
    }

    private func clearSource() {
        switch pinSource {
        case .finder:
            FinderSelection.clearSelection()
        case .clipboard:
            ClipboardImageSource.clear()
        case nil:
            break
        }
    }
}

/// Builds pinned-image windows. Used by the editor's pin button and by the
/// source-specific global pin hotkeys.
enum PinLauncher {
    private static let stackOffset = NSSize(width: 28, height: -28)
    private static let maxDistinctStackOffsets = 8

    /// Pins images currently selected in Finder. This shortcut is intentionally
    /// source-specific: it does not fall back to the clipboard.
    @discardableResult
    static func pinSelectedImagesIfAvailable() -> Bool {
        let finderImages = FinderSelection.currentImageFileURLs().compactMap(loadImage)
        guard !finderImages.isEmpty else {
            ToastWindow.show(message: L10n.selectedImagePinNoImage)
            return false
        }

        pin(images: finderImages, source: .finder)
        ToastWindow.show(message: L10n.pinFromFinderHint)
        return true
    }

    /// Pins the image currently on the clipboard. This shortcut is
    /// source-specific: it does not check the Finder selection.
    @discardableResult
    static func pinClipboardImageIfAvailable() -> Bool {
        guard let image = ClipboardImageSource.currentImage() else {
            ToastWindow.show(message: L10n.clipboardImagePinNoImage)
            return false
        }

        pin(image: image, source: .clipboard)
        ToastWindow.show(message: L10n.pinFromClipboardHint)
        return true
    }

    /// Creates a floating pinned window for `image`. When `origin` is nil the
    /// window is centered on the screen under the cursor. Oversized images are
    /// scaled down to fit the screen.
    static func pin(image: NSImage, at origin: NSPoint? = nil, source: PinSource? = nil) {
        let screen = activeScreen()
        let size = fittedSize(for: image.size, on: screen)
        let frameOrigin = origin ?? centeredOrigin(for: size, on: screen)

        makeWindow(image: image, size: size, origin: frameOrigin, source: source)
    }

    private static func pin(images: [NSImage], source: PinSource) {
        let screen = activeScreen()
        let pins = images.compactMap { image -> (image: NSImage, size: NSSize)? in
            let size = fittedSize(for: image.size, on: screen)
            guard size.width > 0, size.height > 0 else { return nil }
            return (image, size)
        }
        guard let first = pins.first else { return }

        let baseOrigin = centeredOrigin(for: first.size, on: screen)
        for (index, pin) in pins.enumerated() {
            let origin = stackedOrigin(baseOrigin: baseOrigin, index: index, size: pin.size, on: screen)
            makeWindow(image: pin.image, size: pin.size, origin: origin, source: source)
        }
    }

    private static func makeWindow(image: NSImage, size: NSSize, origin: NSPoint, source: PinSource?) {
        let window = PinWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.pinSource = source

        let contentView = PinContentView(frame: NSRect(origin: .zero, size: size))
        contentView.image = image
        contentView.pinWindow = window
        window.contentView = contentView

        PinWindowManager.shared.add(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
    }

    // MARK: - Helpers

    private static func activeScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static func loadImage(from url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
    }

    /// Scales `size` down to fit within the active screen (with a margin),
    /// keeping the aspect ratio. Returns it unchanged when it already fits.
    private static func fittedSize(for size: NSSize, on screen: NSScreen) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let frame = screen.visibleFrame
        let maxWidth = max(200, frame.width - 80)
        let maxHeight = max(200, frame.height - 80)
        let ratio = min(1.0, min(maxWidth / size.width, maxHeight / size.height))
        if ratio >= 1.0 { return size }
        return NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private static func centeredOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
    }

    private static func stackedOrigin(
        baseOrigin: NSPoint,
        index: Int,
        size: NSSize,
        on screen: NSScreen
    ) -> NSPoint {
        let distinctIndex = index % maxDistinctStackOffsets
        let wrapIndex = index / maxDistinctStackOffsets
        let proposed = NSPoint(
            x: baseOrigin.x + CGFloat(distinctIndex) * stackOffset.width + CGFloat(wrapIndex) * 10,
            y: baseOrigin.y + CGFloat(distinctIndex) * stackOffset.height - CGFloat(wrapIndex) * 10
        )
        return clampedOrigin(proposed, size: size, on: screen)
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let maxX = max(frame.minX, frame.maxX - size.width)
        let maxY = max(frame.minY, frame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
        )
    }
}

// MARK: - Pin Window Manager (retains all pinned windows)

final class PinWindowManager {
    static let shared = PinWindowManager()
    private var windows: [NSWindow] = []

    func add(_ window: NSWindow) {
        windows.append(window)
    }

    func remove(_ window: NSWindow) {
        windows.removeAll { $0 === window }
    }
}

// MARK: - Pin Content View (zoomable image with floating controls)

private enum PinZoom {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 5.0
    static let buttonStep: CGFloat = 0.1
    static let wheelSensitivity: CGFloat = 0.002
    static let toolbarInset: CGFloat = 8
    static let toolbarAnimationDuration: TimeInterval = 0.16
}

final class PinContentView: NSView {
    var image: NSImage? {
        didSet {
            zoomScale = 1.0
            needsDisplay = true
            needsLayout = true
            updateImageInteractionGeometry()
        }
    }
    weak var pinWindow: PinWindow?

    private let baseImageSize: NSSize
    private let toolbar = PinToolbarView()
    private var zoomScale: CGFloat = 1.0 {
        didSet {
            toolbar.zoomScale = zoomScale
            needsDisplay = true
        }
    }
    private var panOffset: NSPoint = .zero {
        didSet { needsDisplay = true }
    }
    private var panStartPoint: NSPoint?
    private var panStartOffset: NSPoint = .zero
    private var imageTrackingArea: NSTrackingArea?
    private var isToolbarVisible = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        baseImageSize = frame.size
        super.init(frame: frame)
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupToolbar() {
        toolbar.alphaValue = 0
        toolbar.isHidden = true

        toolbar.onMoveMouseDown = { [weak self] event in
            self?.pinWindow?.performDrag(with: event)
        }
        toolbar.onZoomOut = { [weak self] in
            self?.adjustZoom(by: -PinZoom.buttonStep)
        }
        toolbar.onZoomIn = { [weak self] in
            self?.adjustZoom(by: PinZoom.buttonStep)
        }
        toolbar.onClose = { [weak self] in
            self?.pinWindow?.dismiss()
        }
        addSubview(toolbar)
    }

    override func layout() {
        super.layout()
        updateToolbarFrame()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateImageTrackingArea()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolbarVisibility(animated: false)
    }

    private func updateToolbarFrame() {
        let toolbarWidth = min(PinToolbarView.preferredWidth, max(PinToolbarView.minimumWidth, bounds.width - 12))
        let toolbarHeight = PinToolbarView.preferredHeight
        let imageFrame = imageRect()
        let margin: CGFloat = 6
        let proposedX = imageFrame.minX + PinZoom.toolbarInset
        let proposedY = imageFrame.maxY - toolbarHeight - PinZoom.toolbarInset
        let maxX = max(margin, bounds.width - toolbarWidth - margin)
        let maxY = max(margin, bounds.height - toolbarHeight - margin)

        toolbar.frame = NSRect(
            x: min(max(proposedX, margin), maxX),
            y: min(max(proposedY, margin), maxY),
            width: toolbarWidth,
            height: toolbarHeight
        )
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            pinWindow?.dismissClearingSource()
        case 53: // Esc — close only.
            pinWindow?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard imageHoverRect().contains(point) else { return }

        if zoomScale > 1 {
            panStartPoint = point
            panStartOffset = panOffset
            return
        }

        pinWindow?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoomScale > 1, let start = panStartPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        let proposed = NSPoint(
            x: panStartOffset.x + point.x - start.x,
            y: panStartOffset.y + point.y - start.y
        )
        panOffset = clampedPanOffset(proposed, scale: zoomScale)
        updateImageInteractionGeometry()
    }

    override func mouseUp(with event: NSEvent) {
        panStartPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }

        let normalizedDelta = event.hasPreciseScrollingDeltas ? delta : delta * 10
        let factor = pow(1 + PinZoom.wheelSensitivity, normalizedDelta)
        setZoom(zoomScale * factor)
    }

    override func magnify(with event: NSEvent) {
        let factor = max(0.1, 1 + event.magnification)
        setZoom(zoomScale * factor)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let context = NSGraphicsContext.current
        let oldInterpolation = context?.imageInterpolation
        context?.imageInterpolation = .high
        image.draw(in: imageRect())
        if let oldInterpolation {
            context?.imageInterpolation = oldInterpolation
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolbarVisibility(for: event, animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolbarVisibility(for: event, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateToolbarVisibility(for: event, animated: true)
    }

    private func adjustZoom(by delta: CGFloat) {
        setZoom(zoomScale + delta)
    }

    private func setZoom(_ proposedScale: CGFloat) {
        let newScale = min(max(proposedScale, PinZoom.minScale), PinZoom.maxScale)
        guard abs(newScale - zoomScale) > 0.001 else { return }

        zoomScale = newScale
        panOffset = newScale > 1 ? clampedPanOffset(panOffset, scale: newScale) : .zero
        resizeWindowKeepingTopLeft(for: newScale)
        updateImageInteractionGeometry()
    }

    private func imageRect() -> NSRect {
        let size = scaledImageSize(for: zoomScale)
        return NSRect(
            x: panOffset.x,
            y: bounds.height - size.height + panOffset.y,
            width: size.width,
            height: size.height
        )
    }

    private func scaledImageSize(for scale: CGFloat) -> NSSize {
        NSSize(
            width: max(1, floor(baseImageSize.width * scale)),
            height: max(1, floor(baseImageSize.height * scale))
        )
    }

    private func windowSize(for scale: CGFloat) -> NSSize {
        let imageSize = scaledImageSize(for: scale)
        let naturalSize = scale > 1 ? baseImageSize : imageSize
        return NSSize(
            width: max(naturalSize.width, PinToolbarView.minimumWidth + 12),
            height: max(naturalSize.height, PinToolbarView.preferredHeight + PinZoom.toolbarInset * 2)
        )
    }

    private func clampedPanOffset(_ offset: NSPoint, scale: CGFloat) -> NSPoint {
        guard scale > 1 else { return .zero }

        let imageSize = scaledImageSize(for: scale)
        let minX = min(0, bounds.width - imageSize.width)
        let maxY = max(0, imageSize.height - bounds.height)
        return NSPoint(
            x: min(max(offset.x, minX), 0),
            y: min(max(offset.y, 0), maxY)
        )
    }

    private func resizeWindowKeepingTopLeft(for scale: CGFloat) {
        let targetSize = windowSize(for: scale)
        guard let window else {
            setFrameSize(targetSize)
            return
        }

        let currentFrame = window.frame
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        guard abs(targetFrame.width - currentFrame.width) > 0.5 ||
              abs(targetFrame.height - currentFrame.height) > 0.5
        else { return }

        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func imageHoverRect() -> NSRect {
        guard image != nil else { return .zero }
        let rect = imageRect().intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .zero }
        return rect
    }

    private func updateImageInteractionGeometry() {
        updateToolbarFrame()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: true)
    }

    private func updateImageTrackingArea() {
        if let imageTrackingArea {
            removeTrackingArea(imageTrackingArea)
            self.imageTrackingArea = nil
        }

        let rect = imageHoverRect()
        guard rect.width > 0, rect.height > 0 else {
            setToolbarVisible(false, animated: false)
            return
        }

        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        imageTrackingArea = area
    }

    private func updateToolbarVisibility(for event: NSEvent, animated: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        setToolbarVisible(imageHoverRect().contains(point), animated: animated)
    }

    private func refreshToolbarVisibility(animated: Bool) {
        guard let window else {
            setToolbarVisible(false, animated: false)
            return
        }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setToolbarVisible(imageHoverRect().contains(point), animated: animated)
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        if visible {
            toolbar.isHidden = false
        }

        let finish = { [weak self] in
            guard let self else { return }
            if !self.isToolbarVisible {
                self.toolbar.isHidden = true
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PinZoom.toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                toolbar.animator().alphaValue = visible ? 1 : 0
            } completionHandler: {
                finish()
            }
        } else {
            toolbar.alphaValue = visible ? 1 : 0
            finish()
        }
    }
}

// MARK: - Pin Toolbar

private final class PinToolbarView: NSView {
    static let preferredWidth: CGFloat = 186
    static let minimumWidth: CGFloat = 142
    static let preferredHeight: CGFloat = 34

    var onMoveMouseDown: ((NSEvent) -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onClose: (() -> Void)?

    var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomLabel.stringValue = "\(Int(round(zoomScale * 100)))%"
        }
    }

    private let moveButton = PinToolbarMoveButton(symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                                  accessibilityLabel: "Move pinned image")
    private let zoomOutButton = PinToolbarIconButton(symbolName: "minus", accessibilityLabel: "Zoom out")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let zoomInButton = PinToolbarIconButton(symbolName: "plus", accessibilityLabel: "Zoom in")
    private let closeButton = PinToolbarIconButton(symbolName: "xmark",
                                                   accessibilityLabel: "Close pinned image")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        moveButton.onMouseDown = { [weak self] event in
            self?.onMoveMouseDown?(event)
        }

        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTapped)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        zoomLabel.alignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        zoomLabel.backgroundColor = .clear
        zoomLabel.isBezeled = false
        zoomLabel.isEditable = false
        zoomLabel.isSelectable = false

        addSubview(moveButton)
        addSubview(zoomOutButton)
        addSubview(zoomLabel)
        addSubview(zoomInButton)
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()

        let buttonSide = min(28, max(22, bounds.height - 6))
        let buttonY = (bounds.height - buttonSide) / 2
        let horizontalInset: CGFloat = 4
        let gap: CGFloat = 8

        moveButton.frame = NSRect(x: horizontalInset, y: buttonY, width: buttonSide, height: buttonSide)
        closeButton.frame = NSRect(
            x: bounds.width - horizontalInset - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )

        let centerX = moveButton.frame.maxX + gap
        let centerWidth = max(72, closeButton.frame.minX - gap - centerX)
        let stepWidth = min(24, max(20, centerWidth * 0.22))
        let labelWidth = max(36, centerWidth - stepWidth * 2)

        zoomOutButton.frame = NSRect(x: centerX, y: buttonY, width: stepWidth, height: buttonSide)
        zoomLabel.frame = NSRect(x: zoomOutButton.frame.maxX, y: buttonY + 5,
                                 width: labelWidth, height: buttonSide - 10)
        zoomInButton.frame = NSRect(x: zoomLabel.frame.maxX, y: buttonY,
                                    width: stepWidth, height: buttonSide)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        NSColor(white: 0.08, alpha: 0.78).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    @objc private func zoomOutTapped() {
        onZoomOut?()
    }

    @objc private func zoomInTapped() {
        onZoomIn?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

private class PinToolbarIconButton: NSButton {
    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        focusRingType = .none
        contentTintColor = NSColor.white.withAlphaComponent(0.88)
        setAccessibilityLabel(accessibilityLabel)

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            self.image = image.withSymbolConfiguration(config)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }
}

private final class PinToolbarMoveButton: PinToolbarIconButton {
    var onMouseDown: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
}
