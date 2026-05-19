import AppKit
import CoreImage

struct MosaicRegion {
    let rect: NSRect
    let pixelatedImage: NSImage
}

struct MosaicTool {
    /// Pixelate the part of `baseImage` framed by `rect` (drag-rectangle).
    static func createMosaicRegion(
        rect: NSRect,
        imageSize: NSSize,
        baseImage: NSImage,
        blockSize: CGFloat = 12
    ) -> MosaicRegion? {
        // Clamp the dragged rect to the image bounds.
        let clamped = rect.intersection(NSRect(origin: .zero, size: imageSize))
        guard clamped.width > 0, clamped.height > 0 else { return nil }

        // Extract the sub-image for this region.
        guard let cgImage = baseImage.cgImagePreservingBacking() else { return nil }

        // Convert to CG coordinates (flip Y).
        let scale = CGFloat(cgImage.width) / imageSize.width
        let cgRegion = CGRect(
            x: clamped.origin.x * scale,
            y: (imageSize.height - clamped.origin.y - clamped.height) * scale,
            width: clamped.width * scale,
            height: clamped.height * scale
        )

        guard let croppedCG = cgImage.cropping(to: cgRegion) else { return nil }

        // Apply pixelation using CIFilter.
        let ciImage = CIImage(cgImage: croppedCG)
        let pixelateFilter = CIFilter(name: "CIPixellate")!
        pixelateFilter.setValue(ciImage, forKey: kCIInputImageKey)
        pixelateFilter.setValue(max(blockSize, 4), forKey: kCIInputScaleKey)
        pixelateFilter.setValue(CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY), forKey: kCIInputCenterKey)

        guard let outputCI = pixelateFilter.outputImage else { return nil }

        let context = CIContext()
        guard let outputCG = context.createCGImage(outputCI, from: ciImage.extent) else { return nil }

        let pixelatedImage = NSImage(cgImage: outputCG, size: clamped.size)
        return MosaicRegion(rect: clamped, pixelatedImage: pixelatedImage)
    }
}
