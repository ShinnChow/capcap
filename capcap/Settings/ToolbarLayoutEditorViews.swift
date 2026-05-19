import AppKit

/// Renders an SF Symbol flat-tinted to a single color.
func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return nil
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let symbol = base.withSymbolConfiguration(config) else { return nil }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    return tinted
}

// MARK: - Tool tile

/// A single draggable tool icon in a `ToolbarSlotGridView`.
final class ToolbarItemTile: NSView {
    let itemID: ToolbarItemID

    init(itemID: ToolbarItemID) {
        self.itemID = itemID
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        wantsLayer = true
        toolTip = itemID.tooltip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconColor: NSColor {
        switch itemID {
        case .close:   return toolbarDangerRed
        case .confirm: return accentGreen
        default:       return NSColor.white.withAlphaComponent(0.85)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.08).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        body.lineWidth = 1
        body.stroke()

        if let icon = tintedSymbol(itemID.symbolName, pointSize: 15, color: iconColor) {
            let size = icon.size
            icon.draw(in: NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
    }
}

// MARK: - Slot grid

/// A wrapping grid of tool tiles for one toolbar section. Drag-and-drop
/// editing is added in a later phase; for now it lays the tiles out and
/// draws empty placeholder slots.
final class ToolbarSlotGridView: NSView {
    static let tile: CGFloat = 34
    static let gap: CGFloat = 8

    let section: ToolbarSection
    private(set) var items: [ToolbarItemID] = []

    /// Fired after a drag-and-drop edit changes this grid's contents.
    var onLayoutChanged: (() -> Void)?
    /// Supplies all sibling grids so a drag can move tiles across sections.
    var gridProvider: (() -> [ToolbarSlotGridView])?

    private var tiles: [ToolbarItemTile] = []
    private var heightConstraint: NSLayoutConstraint!
    private(set) var columns: Int = 10

    init(section: ToolbarSection) {
        self.section = section
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightConstraint = heightAnchor.constraint(equalToConstant: rowHeight(rows: 2))
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func setItems(_ newItems: [ToolbarItemID]) {
        items = newItems
        tiles.forEach { $0.removeFromSuperview() }
        tiles = newItems.map { id in
            let tile = ToolbarItemTile(itemID: id)
            addSubview(tile)
            return tile
        }
        needsLayout = true
        needsDisplay = true
    }

    private func rowHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * Self.tile + CGFloat(max(0, rows - 1)) * Self.gap
    }

    /// Rows to display — always at least 2, so there's room to drop into.
    private var displayRows: Int {
        max(2, Int(ceil(Double(items.count) / Double(max(1, columns)))))
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        columns = max(1, Int((bounds.width + Self.gap) / (Self.tile + Self.gap)))
        for (index, tile) in tiles.enumerated() {
            tile.frame = slotFrame(at: index)
        }
        let height = rowHeight(rows: displayRows)
        if abs(heightConstraint.constant - height) > 0.5 {
            heightConstraint.constant = height
        }
        needsDisplay = true
    }

    /// Frame of the slot at a flow index (flipped: row 0 sits at the top).
    func slotFrame(at index: Int) -> NSRect {
        let col = index % columns
        let row = index / columns
        return NSRect(
            x: CGFloat(col) * (Self.tile + Self.gap),
            y: CGFloat(row) * (Self.tile + Self.gap),
            width: Self.tile,
            height: Self.tile
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let total = displayRows * columns
        guard items.count < total else { return }
        NSColor.white.withAlphaComponent(0.12).setStroke()
        for index in items.count..<total {
            let rect = slotFrame(at: index).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            path.lineWidth = 1
            path.setLineDash([3, 3], count: 2, phase: 0)
            path.stroke()
        }
    }
}

// MARK: - Layout preview

/// A non-interactive miniature of the editor showing where the current
/// layout places the primary and side toolbars around a selection.
final class ToolbarLayoutPreviewView: NSView {
    var layout: ToolbarLayout = .default {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let miniButton: CGFloat = 15
    private let miniGap: CGFloat = 3
    private let miniPad: CGFloat = 6

    /// Length of a toolbar capsule holding `count` mini buttons.
    private func capsuleRun(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * miniButton
            + CGFloat(count - 1) * miniGap
            + miniPad * 2
    }

    private var capsuleThickness: CGFloat { miniButton + miniPad * 2 }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // Backdrop — a soft lake-ish gradient standing in for a screenshot.
        if let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.17, green: 0.33, blue: 0.50, alpha: 1),
            NSColor(srgbRed: 0.13, green: 0.42, blue: 0.45, alpha: 1),
        ]) {
            gradient.draw(in: b, angle: -90)
        }

        // Selection rect — leaves room below for the primary toolbar and to
        // the right for the side toolbar.
        let selection = NSRect(
            x: b.minX + 44,
            y: b.minY + capsuleThickness + 16,
            width: b.width - 44 - 70,
            height: b.height - (capsuleThickness + 16) - 22
        )
        guard selection.width > 20, selection.height > 20 else { return }

        let dashed = NSBezierPath(rect: selection)
        dashed.lineWidth = 1.5
        dashed.setLineDash([5, 3], count: 2, phase: 0)
        accentGreen.setStroke()
        dashed.stroke()
        drawHandles(around: selection)

        // Primary toolbar — horizontal capsule centered below the selection.
        if !layout.primary.isEmpty {
            let run = capsuleRun(layout.primary.count)
            let rect = NSRect(
                x: selection.midX - run / 2,
                y: selection.minY - 10 - capsuleThickness,
                width: run,
                height: capsuleThickness
            )
            drawCapsule(rect, items: layout.primary, orientation: .horizontal)
        }

        // Side toolbar — vertical capsule centered to the right.
        if !layout.side.isEmpty {
            let run = capsuleRun(layout.side.count)
            let rect = NSRect(
                x: selection.maxX + 10,
                y: selection.midY - run / 2,
                width: capsuleThickness,
                height: run
            )
            drawCapsule(rect, items: layout.side, orientation: .vertical)
        }
    }

    private func drawHandles(around rect: NSRect) {
        let points = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.midY),
            NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        accentGreen.setFill()
        for point in points {
            let dot = NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    private func drawCapsule(
        _ rect: NSRect,
        items: [ToolbarItemID],
        orientation: ToolbarView.Orientation
    ) {
        let body = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor(white: 0.12, alpha: 0.95).setFill()
        body.fill()

        for (index, id) in items.enumerated() {
            let offset = miniPad + CGFloat(index) * (miniButton + miniGap)
            let slot: NSRect
            switch orientation {
            case .horizontal:
                slot = NSRect(x: rect.minX + offset, y: rect.minY + miniPad,
                              width: miniButton, height: miniButton)
            case .vertical:
                // First item at the top of the vertical capsule.
                slot = NSRect(x: rect.minX + miniPad,
                              y: rect.maxY - miniPad - miniButton - CGFloat(index) * (miniButton + miniGap),
                              width: miniButton, height: miniButton)
            }
            let color: NSColor
            switch id {
            case .close:   color = toolbarDangerRed
            case .confirm: color = accentGreen
            default:       color = .white
            }
            if let icon = tintedSymbol(id.symbolName, pointSize: 9, color: color) {
                let size = icon.size
                icon.draw(in: NSRect(
                    x: slot.midX - size.width / 2,
                    y: slot.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
        }
    }
}
