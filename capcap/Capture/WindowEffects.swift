import AppKit
import QuartzCore

/// Post-processing for window captures: clip the four corners to the rounded
/// shape of a real macOS window, and add a soft system-style drop shadow.
/// Applied only to single-window screenshots, never to free-drag regions.
enum WindowEffects {
    /// Fallback corner radius when a real WindowServer alpha mask is not
    /// available. Normal clicked-window captures use the system-provided mask
    /// instead, because macOS varies the actual corner shape by OS/window style.
    static let cornerRadiusPoints: CGFloat = 16

    /// Pixels-per-point of the image's backing bitmap (2 on Retina displays).
    private static func scale(of image: NSImage) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 2
        }
        return CGFloat(cg.width) / max(image.size.width, 1)
    }

    /// Mask the four corners of a window screenshot to transparent. This is a
    /// fallback for cases where a clicked-window capture could not provide the
    /// real WindowServer alpha mask.
    static func roundedCorners(_ image: NSImage, radiusPoints: CGFloat = cornerRadiusPoints) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let pw = cg.width
        let ph = cg.height
        guard pw > 0, ph > 0 else { return image }

        guard let mask = continuousCornerMask(
            pixelWidth: pw,
            pixelHeight: ph,
            pointSize: image.size,
            radiusPoints: radiusPoints
        ) else {
            return image
        }

        return applyMask(mask, to: image)
    }

    /// Clip the supplied context to the alpha silhouette of `maskImage`.
    /// The clip is scaled into `rect`, so callers can use an image whose pixel
    /// dimensions differ from the current CGContext backing store.
    @discardableResult
    static func clip(_ context: CGContext, toAlphaOf maskImage: NSImage, in rect: CGRect) -> Bool {
        guard let maskCG = maskImage.cgImagePreservingBacking(),
              let alphaMask = alphaMask(from: maskCG, width: maskCG.width, height: maskCG.height)
        else {
            return false
        }

        context.clip(to: rect, mask: alphaMask)
        return true
    }

    private static func continuousCornerMask(
        pixelWidth: Int,
        pixelHeight: Int,
        pointSize: NSSize,
        radiusPoints: CGFloat
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let scaleX = CGFloat(pixelWidth) / max(pointSize.width, 1)
        let scaleY = CGFloat(pixelHeight) / max(pointSize.height, 1)
        let scale = max(scaleX, scaleY)
        let radius = min(radiusPoints, min(pointSize.width, pointSize.height) / 2)

        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scaleX, y: scaleY)

        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: pointSize)
        layer.backgroundColor = NSColor.white.cgColor
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.masksToBounds = true
        layer.render(in: context)

        return context.makeImage()
    }

    private static func alphaMask(from source: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drewSource = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drewSource else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rgbaRow = y * bytesPerRow
            let alphaRow = y * width
            for x in 0..<width {
                alpha[alphaRow + x] = rgba[rgbaRow + x * bytesPerPixel + 3]
            }
        }

        let data = Data(alpha)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func applyMask(_ mask: CGImage, to image: NSImage) -> NSImage {
        guard let cg = image.cgImagePreservingBacking() else { return image }
        let pw = cg.width
        let ph = cg.height
        guard pw > 0, ph > 0 else { return image }

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
        context.clip(to: rect, mask: mask)
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
