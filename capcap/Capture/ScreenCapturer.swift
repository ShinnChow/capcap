import AppKit
import ScreenCaptureKit

struct ScreenCapturer {
    /// - Parameter excludingWindowNumbers: window numbers (`NSWindow.windowNumber`)
    ///   to omit from the capture — used so capcap's own scroll-capture chrome
    ///   (e.g. the on-screen hint toast) is never baked into a captured frame.
    static func capture(
        rect: CGRect,
        screen: NSScreen,
        excludingWindowNumbers: [CGWindowID] = []
    ) -> NSImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        let excludedWindowNumbers = effectiveExcludedWindowNumbers(excludingWindowNumbers)
        CaptureDiagnostics.log("display-capture-sync-begin", metadata: [
            "rect": CaptureDiagnostics.rect(rect),
            "excludedWindowCount": excludedWindowNumbers.count,
        ])

        var resultImage: NSImage?
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let image = try await captureAsync(
                    rect: rect,
                    screen: screen,
                    excludingWindowNumbers: excludedWindowNumbers
                )
                resultImage = image
            } catch {
                NSLog("capcap: Screen capture failed: \(error)")
                CaptureDiagnostics.log("display-capture-sync-error", metadata: [
                    "error": error.localizedDescription,
                ])
            }
            semaphore.signal()
        }

        semaphore.wait()
        CaptureDiagnostics.log("display-capture-sync-end", metadata: [
            "durationMs": CaptureDiagnostics.elapsedMilliseconds(since: start),
            "success": resultImage != nil,
            "imageSize": resultImage.map { CaptureDiagnostics.size($0.size) } ?? "nil",
        ])
        return resultImage
    }

    private static func effectiveExcludedWindowNumbers(_ windowNumbers: [CGWindowID]) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        return (windowNumbers + ToastWindow.captureExcludedWindowNumbers).filter { windowNumber in
            windowNumber > 0 && seen.insert(windowNumber).inserted
        }
    }

    /// Capture one WindowServer window directly, preserving its real alpha
    /// silhouette. This gives window screenshots the exact system corner mask
    /// instead of relying on a guessed radius.
    static func capture(windowID: CGWindowID, pointSize: NSSize? = nil) -> NSImage? {
        let start = ProcessInfo.processInfo.systemUptime
        CaptureDiagnostics.log("window-capture-sync-begin", metadata: [
            "windowID": windowID,
            "pointSize": pointSize.map(CaptureDiagnostics.size) ?? "nil",
        ])
        var resultImage: NSImage?
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                resultImage = try await captureWindowAsync(windowID: windowID, pointSize: pointSize)
            } catch {
                NSLog("capcap: Window capture failed: \(error)")
                CaptureDiagnostics.log("window-capture-sync-error", metadata: [
                    "windowID": windowID,
                    "error": error.localizedDescription,
                ])
            }
            semaphore.signal()
        }

        semaphore.wait()
        CaptureDiagnostics.log("window-capture-sync-end", metadata: [
            "windowID": windowID,
            "durationMs": CaptureDiagnostics.elapsedMilliseconds(since: start),
            "success": resultImage != nil,
            "imageSize": resultImage.map { CaptureDiagnostics.size($0.size) } ?? "nil",
        ])
        return resultImage
    }

    static func isEffectivelyTransparent(_ image: NSImage, alphaThreshold: UInt8 = 3) -> Bool {
        guard let cgImage = image.cgImagePreservingBacking() else { return false }

        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return true }

        let sampleMaxDimension = 32
        let sampleScale = min(
            1,
            CGFloat(sampleMaxDimension) / CGFloat(max(width, height))
        )
        let sampleWidth = max(1, Int(ceil(CGFloat(width) * sampleScale)))
        let sampleHeight = max(1, Int(ceil(CGFloat(height) * sampleScale)))
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * sampleHeight)

        let drewImage = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }

        guard drewImage else { return false }

        for index in stride(from: 3, to: rgba.count, by: bytesPerPixel) {
            if rgba[index] > alphaThreshold {
                return false
            }
        }
        return true
    }

    private static func captureAsync(
        rect: CGRect,
        screen: NSScreen,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> NSImage? {
        let requestedDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let contentStart = ProcessInfo.processInfo.systemUptime
        let content = try await SCShareableContent.current
        CaptureDiagnostics.log("display-shareable-content", metadata: [
            "durationMs": CaptureDiagnostics.elapsedMilliseconds(since: contentStart),
            "displayCount": content.displays.count,
            "windowCount": content.windows.count,
            "requestedDisplayID": requestedDisplayID.map(String.init) ?? "nil",
        ])
        let excludedWindows = excludingWindowNumbers.isEmpty
            ? []
            : content.windows.filter { excludingWindowNumbers.contains($0.windowID) }

        // Find the matching SCDisplay for this screen
        guard let display = content.displays.first(where: { display in
            display.displayID == requestedDisplayID
        }) else {
            // Fallback: use first display
            CaptureDiagnostics.log("display-capture-fallback-display", metadata: [
                "requestedDisplayID": requestedDisplayID.map(String.init) ?? "nil",
            ])
            guard let display = content.displays.first else { return nil }
            return try await captureDisplay(display, rect: rect, excludingWindows: excludedWindows)
        }

        return try await captureDisplay(display, rect: rect, excludingWindows: excludedWindows)
    }

    private static func captureWindowAsync(windowID: CGWindowID, pointSize: NSSize?) async throws -> NSImage? {
        let contentStart = ProcessInfo.processInfo.systemUptime
        let content = try await SCShareableContent.current
        CaptureDiagnostics.log("window-shareable-content", metadata: [
            "windowID": windowID,
            "durationMs": CaptureDiagnostics.elapsedMilliseconds(since: contentStart),
            "displayCount": content.displays.count,
            "windowCount": content.windows.count,
        ])
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            CaptureDiagnostics.log("window-capture-window-missing", metadata: [
                "windowID": windowID,
            ])
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let contentSize = filter.contentRect.size
        let imageSize = pointSize ?? NSSize(width: contentSize.width, height: contentSize.height)

        let config = SCStreamConfiguration()
        config.width = max(Int(ceil(contentSize.width * scale)), 1)
        config.height = max(Int(ceil(contentSize.height * scale)), 1)
        config.capturesAudio = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false

        let captureStart = ProcessInfo.processInfo.systemUptime
        CaptureDiagnostics.log("window-capture-image-begin", metadata: [
            "windowID": windowID,
            "contentSize": CaptureDiagnostics.size(contentSize),
            "scale": String(format: "%.2f", Double(scale)),
            "configPixels": "\(config.width)x\(config.height)",
        ])
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        CaptureDiagnostics.log("window-capture-image-end", metadata: [
            "windowID": windowID,
            "durationMs": CaptureDiagnostics.elapsedMilliseconds(since: captureStart),
            "imagePixels": "\(image.width)x\(image.height)",
        ])

        return NSImage(cgImage: image, size: imageSize)
    }

    private static func captureDisplay(
        _ display: SCDisplay,
        rect: CGRect,
        excludingWindows: [SCWindow]
    ) async throws -> NSImage? {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let scale = max(screenScale(for: display), 1)

        // sourceRect must be in the display's local coordinate space (top-left
        // origin of *this* display), not the global CG coordinate space. For
        // extended displays whose CGDisplayBounds origin is non-zero, passing
        // the global rect captures the wrong region (or nothing).
        let displayBounds = CGDisplayBounds(display.displayID)
        let localRect = CGRect(
            x: rect.origin.x - displayBounds.origin.x,
            y: rect.origin.y - displayBounds.origin.y,
            width: rect.width,
            height: rect.height
        )

        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        config.width = max(Int(ceil(rect.width * scale)), 1)
        config.height = max(Int(ceil(rect.height * scale)), 1)
        config.capturesAudio = false
        config.showsCursor = false

        let captureStart = ProcessInfo.processInfo.systemUptime
        CaptureDiagnostics.log("display-capture-image-begin", metadata: [
            "displayID": display.displayID,
            "localRect": CaptureDiagnostics.rect(localRect),
            "scale": String(format: "%.2f", Double(scale)),
            "configPixels": "\(config.width)x\(config.height)",
            "excludedWindowCount": excludingWindows.count,
        ])
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        CaptureDiagnostics.log("display-capture-image-end", metadata: [
            "displayID": display.displayID,
            "durationMs": CaptureDiagnostics.elapsedMilliseconds(since: captureStart),
            "imagePixels": "\(image.width)x\(image.height)",
        ])

        return NSImage(cgImage: image, size: NSSize(width: rect.width, height: rect.height))
    }

    /// Crop a region from a pre-captured full-screen CGImage (e.g. from CGDisplayCreateImage).
    static func crop(from snapshot: CGImage, captureRect: CGRect, screen: NSScreen) -> NSImage? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let displayBounds = CGDisplayBounds(displayID)

        // Convert global CG rect to display-local coordinates
        let localRect = CGRect(
            x: captureRect.origin.x - displayBounds.origin.x,
            y: captureRect.origin.y - displayBounds.origin.y,
            width: captureRect.width,
            height: captureRect.height
        )

        // Scale to image pixel coordinates (Retina)
        let scaleX = CGFloat(snapshot.width) / displayBounds.width
        let scaleY = CGFloat(snapshot.height) / displayBounds.height
        let imageRect = CGRect(
            x: localRect.origin.x * scaleX,
            y: localRect.origin.y * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        )

        guard let cropped = snapshot.cropping(to: imageRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: captureRect.width, height: captureRect.height))
    }

    private static func screenScale(for display: SCDisplay) -> CGFloat {
        guard
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            })
        else {
            return 2
        }

        return screen.backingScaleFactor
    }
}
