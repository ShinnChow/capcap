import AppKit
import CoreGraphics
import ImageIO

enum BeautifyRenderer {
    // MARK: - Layout constants

    static let paddingRatio: CGFloat = 0.10
    static let paddingMin: CGFloat = 16
    static let paddingMax: CGFloat = 220
    static let innerCornerRadius: CGFloat = 12
    // Ambient shadow (uniform glow around all edges)
    static let ambientShadowBlur: CGFloat = 20
    static let ambientShadowOpacity: CGFloat = 0.22
    static let ambientShadowOffset: CGSize = CGSize(width: 0, height: 0)
    // Key shadow (slight downward bias for natural depth)
    static let keyShadowBlur: CGFloat = 30
    static let keyShadowOpacity: CGFloat = 0.25
    static let keyShadowOffset: CGSize = CGSize(width: 0, height: -5)

    // MARK: - Slider bounds (user-controlled padding)
    static let paddingSliderMin: CGFloat = 0
    static let paddingSliderMax: CGFloat = 56
    static let paddingSliderDefault: CGFloat = 24

    // MARK: - Geometry

    static func padding(for innerSize: CGSize) -> CGFloat {
        let shortEdge = min(innerSize.width, innerSize.height)
        guard shortEdge > 0 else { return paddingMin }
        let base = shortEdge * paddingRatio
        return max(paddingMin, min(paddingMax, base))
    }

    static func outputSize(for innerSize: CGSize) -> CGSize {
        let p = padding(for: innerSize)
        return CGSize(width: innerSize.width + 2 * p, height: innerSize.height + 2 * p)
    }

    static func innerRect(for innerSize: CGSize) -> CGRect {
        let p = padding(for: innerSize)
        return CGRect(x: p, y: p, width: innerSize.width, height: innerSize.height)
    }

    static func outputSize(innerSize: CGSize, padding: CGFloat) -> CGSize {
        return CGSize(
            width: innerSize.width + 2 * padding,
            height: innerSize.height + 2 * padding
        )
    }

    static func innerRect(innerSize: CGSize, padding: CGFloat) -> CGRect {
        return CGRect(x: padding, y: padding, width: innerSize.width, height: innerSize.height)
    }

    // MARK: - Wallpaper

    /// Longest-edge pixel cap for the cached wallpaper bitmap. The raw desktop
    /// image is often a multi-frame "dynamic" HEIC well over 100 MB; that only
    /// ever fills the thin padding band, so a 2560 px copy is plenty.
    private static let wallpaperMaxEdge: CGFloat = 2560

    /// Decoded + downscaled wallpaper bitmaps, keyed by source file path.
    private static var wallpaperCache: [String: NSImage] = [:]
    private static let wallpaperCacheLock = NSLock()

    /// Loads the desktop wallpaper image for the given screen.
    ///
    /// The desktop image returned by `desktopImageURL` can be a dynamic HEIC
    /// containing many full-resolution frames. Decoding that synchronously —
    /// and re-decoding it on every swatch/preview redraw, since nothing was
    /// cached — froze the editor for several seconds on machines using the
    /// default macOS dynamic wallpaper. We instead decode a single downscaled
    /// thumbnail once (ImageIO never expands the full-size image) and cache it.
    static func wallpaperImage(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let key = url.path

        wallpaperCacheLock.lock()
        if let cached = wallpaperCache[key] {
            wallpaperCacheLock.unlock()
            return cached
        }
        wallpaperCacheLock.unlock()

        guard let image = downscaledWallpaper(url: url) else { return nil }

        wallpaperCacheLock.lock()
        wallpaperCache[key] = image
        wallpaperCacheLock.unlock()
        return image
    }

    /// Decodes only the primary frame of `url`, downscaled so the longest edge
    /// is at most `wallpaperMaxEdge`. `CGImageSourceCreateThumbnailAtIndex`
    /// performs the scaling inside ImageIO, so a 100 MB+ dynamic wallpaper is
    /// never fully decoded into memory.
    private static func downscaledWallpaper(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: wallpaperMaxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Drawing primitives

    /// Draws a linear gradient across `outerRect` using the preset colors and angle.
    /// For wallpaper presets the area is left clear (caller draws wallpaper separately).
    static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset) {
        if preset.isWallpaper { return }
        guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
            preset.startColor.setFill()
            outerRect.fill()
            return
        }
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    }

    /// Draws a wallpaper image as background, aspect-fill centered in `outerRect`.
    static func drawWallpaperBackground(in outerRect: CGRect, wallpaper: NSImage) {
        let wpSize = wallpaper.size
        guard wpSize.width > 0, wpSize.height > 0 else { return }
        let scaleX = outerRect.width / wpSize.width
        let scaleY = outerRect.height / wpSize.height
        let scale = max(scaleX, scaleY)
        let drawSize = CGSize(width: wpSize.width * scale, height: wpSize.height * scale)
        let drawRect = CGRect(
            x: outerRect.origin.x + (outerRect.width - drawSize.width) / 2,
            y: outerRect.origin.y + (outerRect.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        wallpaper.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    /// Draws a two-layer shadow (ambient + key light) cast by a rounded-rect
    /// silhouette at `innerRect`, creating a natural floating-card effect.
    /// The fill used to cast the shadow is clipped out, so transparent pixels
    /// in the screenshot reveal the beautify background instead of a black
    /// backing rectangle.
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        let path = CGPath(
            roundedRect: innerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // Pass 1: ambient shadow — uniform glow around all edges
        drawShadowOnly(
            path: path,
            innerRect: innerRect,
            offset: ambientShadowOffset,
            blur: ambientShadowBlur,
            opacity: ambientShadowOpacity,
            context: context
        )

        // Pass 2: key shadow — slight downward offset for natural depth
        drawShadowOnly(
            path: path,
            innerRect: innerRect,
            offset: keyShadowOffset,
            blur: keyShadowBlur,
            opacity: keyShadowOpacity,
            context: context
        )
    }

    private static func drawShadowOnly(
        path: CGPath,
        innerRect: CGRect,
        offset: CGSize,
        blur: CGFloat,
        opacity: CGFloat,
        context: CGContext
    ) {
        let shadowOutset = blur * 3 + max(abs(offset.width), abs(offset.height)) + 2
        let clipRect = innerRect.insetBy(dx: -shadowOutset, dy: -shadowOutset)

        context.saveGState()
        context.addRect(clipRect)
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: offset,
            blur: blur,
            color: NSColor.black.withAlphaComponent(opacity).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Full composite

    /// Measures the inner image's pixel density (pixels per point).
    private static func pixelScale(of innerImage: NSImage) -> CGFloat {
        let pointWidth = innerImage.size.width
        guard pointWidth > 0 else { return 1 }
        let maxPixelsWide = innerImage.representations
            .map(\.pixelsWide)
            .filter { $0 > 0 }
            .max() ?? 0
        guard maxPixelsWide > 0 else { return 1 }
        return max(CGFloat(maxPixelsWide) / pointWidth, 1)
    }

    /// Returns a new NSImage containing `innerImage` wrapped in the beautified frame.
    static func render(innerImage: NSImage, preset: BeautifyPreset) -> NSImage {
        return render(
            innerImage: innerImage,
            preset: preset,
            padding: padding(for: innerImage.size),
            wallpaperImage: nil
        )
    }

    /// Variant of `render` that uses an explicit padding value (in points)
    /// instead of running the auto-ratio `padding(for:)`. Used by the
    /// beautify editor when the user drives padding from the sub-toolbar slider.
    static func render(
        innerImage: NSImage,
        preset: BeautifyPreset,
        padding: CGFloat,
        wallpaperImage: NSImage? = nil,
        shadowEnabled: Bool = true
    ) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        let outer = outputSize(innerSize: innerSize, padding: padding)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(innerSize: innerSize, padding: padding)

        // Preserve backing scale by mirroring the inner image's pixel density.
        let innerPixelScale = pixelScale(of: innerImage)
        let pixelsWide = Int((outer.width * innerPixelScale).rounded())
        let pixelsHigh = Int((outer.height * innerPixelScale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            return innerImage
        }
        rep.size = outer

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return innerImage }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let cg = ctx.cgContext

        // 1. Background
        if preset.isWallpaper, let wp = wallpaperImage {
            drawWallpaperBackground(in: outerRect, wallpaper: wp)
        } else {
            drawBackground(in: outerRect, preset: preset)
        }

        // 2. Soft shadow under the inner rounded rect
        if shadowEnabled {
            drawInnerShadow(innerRect: inner, cornerRadius: innerCornerRadius, context: cg)
        }

        // 3. Clip to the inner rounded rect and draw the image
        cg.saveGState()
        let clipPath = CGPath(
            roundedRect: inner,
            cornerWidth: innerCornerRadius,
            cornerHeight: innerCornerRadius,
            transform: nil
        )
        cg.addPath(clipPath)
        cg.clip()
        innerImage.draw(
            in: inner,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        return image
    }
}
