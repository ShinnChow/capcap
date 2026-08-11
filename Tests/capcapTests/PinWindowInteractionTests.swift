import AppKit
import XCTest
@testable import capcap

@MainActor
final class PinWindowInteractionTests: XCTestCase {
    func testImagePinAcceptsActivationMouseDown() {
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testTransparentImagePinDoesNotAddASecondWindowShadow() throws {
        let image = try Self.makeImage(edgeAlpha: 0)

        XCTAssertFalse(PinLauncher.shouldUseSystemWindowShadow(for: image))
    }

    func testOpaqueImagePinKeepsSystemWindowShadow() throws {
        let image = try Self.makeImage(edgeAlpha: 255)

        XCTAssertTrue(PinLauncher.shouldUseSystemWindowShadow(for: image))
    }

    func testPinImageScalingKeepsTheFullAspectRatioAtLargeZoomLevels() {
        let baseSize = NSSize(width: 1_200, height: 800)

        let scaledSize = PinImageLayout.scaledSize(baseSize: baseSize, scale: 3.5)

        XCTAssertEqual(scaledSize.width, 4_200, accuracy: 0.001)
        XCTAssertEqual(scaledSize.height, 2_800, accuracy: 0.001)
        XCTAssertEqual(
            scaledSize.width / scaledSize.height,
            baseSize.width / baseSize.height,
            accuracy: 0.000_001
        )
    }

    func testPinImageScalingKeepsExtremeAspectRatios() {
        let baseSize = NSSize(width: 1, height: 100)

        let scaledSize = PinImageLayout.scaledSize(baseSize: baseSize, scale: 0.25)

        XCTAssertEqual(scaledSize.width, 0.25, accuracy: 0.001)
        XCTAssertEqual(scaledSize.height, 25, accuracy: 0.001)
        XCTAssertEqual(
            scaledSize.width / scaledSize.height,
            baseSize.width / baseSize.height,
            accuracy: 0.000_001
        )
    }

    func testPinImageFocusedZoomKeepsTheSameImagePointUnderThePointer() {
        let currentFrame = NSRect(x: 120, y: 240, width: 400, height: 200)
        let focus = NSPoint(x: 0.25, y: 0.75)

        let resizedFrame = PinImageLayout.resizedFrame(
            from: currentFrame,
            to: NSSize(width: 800, height: 400),
            focusing: focus
        )

        XCTAssertEqual(
            resizedFrame.minX + resizedFrame.width * focus.x,
            currentFrame.minX + currentFrame.width * focus.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            resizedFrame.minY + resizedFrame.height * focus.y,
            currentFrame.minY + currentFrame.height * focus.y,
            accuracy: 0.001
        )
    }

    func testPinToolbarIsInsetInsideTheImageTopLeftCorner() {
        let imageBounds = NSRect(x: 0, y: 0, width: 800, height: 500)

        let toolbarFrame = PinImageLayout.toolbarFrame(
            in: imageBounds,
            preferredSize: NSSize(width: 174, height: 32)
        )

        XCTAssertEqual(toolbarFrame.minX, 8, accuracy: 0.001)
        XCTAssertEqual(toolbarFrame.maxY, imageBounds.maxY - 8, accuracy: 0.001)
        XCTAssertTrue(imageBounds.contains(toolbarFrame))
    }

    func testPinToolbarIsAnImageSubviewWithoutZoomStepButtons() throws {
        let contentView = PinContentView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let toolbar = try XCTUnwrap(contentView.subviews.first { $0 is PinToolbarView } as? PinToolbarView)

        XCTAssertEqual(toolbar.subviews.compactMap { $0 as? NSButton }.count, 5)
    }

    private static func makeImage(edgeAlpha: UInt8) throws -> NSImage {
        let width = 3
        let height = 3
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where x == 0 || x == width - 1 || y == 0 || y == height - 1 {
                let offset = (y * width + x) * 4
                pixels[offset] = edgeAlpha
                pixels[offset + 1] = edgeAlpha
                pixels[offset + 2] = edgeAlpha
                pixels[offset + 3] = edgeAlpha
            }
        }

        let cgImage = pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }
        return NSImage(
            cgImage: try XCTUnwrap(cgImage),
            size: NSSize(width: width, height: height)
        )
    }
}
