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
