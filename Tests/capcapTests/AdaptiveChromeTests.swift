import AppKit
import XCTest
@testable import capcap

final class AdaptiveChromeTests: XCTestCase {
    func testAppearanceClassification() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertFalse(AdaptiveChrome.isDark(light))
        XCTAssertTrue(AdaptiveChrome.isDark(dark))
    }

    func testToolbarBackgroundResolvesDifferentlyAcrossAppearances() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColor = try colorComponents(
            AdaptiveChrome.resolvedCGColor(AdaptiveChrome.toolbarBackground, for: light)
        )
        let darkColor = try colorComponents(
            AdaptiveChrome.resolvedCGColor(AdaptiveChrome.toolbarBackground, for: dark)
        )

        XCTAssertGreaterThan(lightColor.red, darkColor.red)
        XCTAssertGreaterThan(lightColor.green, darkColor.green)
        XCTAssertGreaterThan(lightColor.blue, darkColor.blue)
    }

    private func colorComponents(_ color: CGColor) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let converted = try XCTUnwrap(
            color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        )
        let components = try XCTUnwrap(converted.components)
        XCTAssertGreaterThanOrEqual(components.count, 3)
        return (components[0], components[1], components[2])
    }
}
