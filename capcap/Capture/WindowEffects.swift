import AppKit

/// Post-processing for window captures: clip the four corners to the rounded
/// shape of a real macOS window, and add a soft system-style drop shadow.
/// Applied only to single-window screenshots, never to free-drag regions.
enum WindowEffects {
    /// Corner radius of a standard macOS window, in points. macOS does not
    /// expose this value, so it is a fixed approximation that matches the
    /// system look across Big Sur and later.
    static let cornerRadiusPoints: CGFloat = 10

    /// Pixels-per-point of the image's backing bitmap (2 on Retina displays).
    private static func scale(of image: NSImage) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 2
        }
        return CGFloat(cg.width) / max(image.size.width, 1)
    }

    /// Mask the four corners of a window screenshot to transparent so the
    /// result has the rounded silhouette of the original window.
    static func roundedCorners(_ image: NSImage, radiusPoints: CGFloat = cornerRadiusPoints) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let pw = cg.width
        let ph = cg.height
        guard pw > 0, ph > 0 else { return image }

        let pxScale = CGFloat(pw) / max(image.size.width, 1)
        // Never round more than half the shorter side.
        let radius = min(radiusPoints * pxScale, CGFloat(min(pw, ph)) / 2)

        // Keep the screenshot's own color space (often Display P3) so the
        // corner mask doesn't shift the gamut.
        let colorSpace: CGColorSpace = {
            if let cs = cg.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()

        guard let context = CGContext(
            data: nil,
            width: pw,
            height: ph,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        let rect = CGRect(x: 0, y: 0, width: pw, height: ph)
        context.interpolationQuality = .high
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.clip()
        context.draw(cg, in: rect)

        guard let out = context.makeImage() else { return image }
        return NSImage(cgImage: out, size: image.size)
    }

    /// Draw `image` (already corner-masked) onto a larger transparent canvas
    /// with a soft drop shadow. `size` is the shadow magnitude in points —
    /// larger values blur wider and offset further, so the window reads as
    /// floating higher above the background. `size <= 0` is a no-op.
    static func withShadow(_ image: NSImage, size: CGFloat) -> NSImage {
        guard size > 0 else { return image }

        let pxScale = scale(of: image)
        let blur = size
        let drop = size * 0.4                       // downward offset magnitude
        let margin = (blur * 1.8 + 6).rounded()     // room for the blur fringe

        let padLeft = margin
        let padRight = margin
        let padTop = margin
        let padBottom = (margin + drop).rounded()

        let canvasSize = NSSize(
            width: image.size.width + padLeft + padRight,
            height: image.size.height + padTop + padBottom
        )
        let pixelW = Int((canvasSize.width * pxScale).rounded())
        let pixelH = Int((canvasSize.height * pxScale).rounded())
        guard pixelW > 0, pixelH > 0 else { return image }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }
        rep.size = canvasSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = blur
        // Non-flipped context: negative y casts the shadow downward.
        shadow.shadowOffset = NSSize(width: 0, height: -drop)
        shadow.set()

        let drawRect = NSRect(
            x: padLeft,
            y: padBottom,
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: canvasSize)
        out.addRepresentation(rep)
        return out
    }
}
