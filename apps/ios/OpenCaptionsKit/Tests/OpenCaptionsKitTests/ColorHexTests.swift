import SwiftUI
import Testing
@testable import OpenCaptionsKit

@Suite struct ColorHexTests {
    @Test func hexParsesWithAndWithoutAlpha() throws {
        let opaque = try #require(ColorHex.components("#7C3AED"))
        #expect(abs(opaque.r - 124.0 / 255) < 1e-9 && opaque.a == 1)
        let shadow = try #require(ColorHex.components("#00000080"))
        #expect(shadow.r == 0 && abs(shadow.a - 128.0 / 255) < 1e-9)
        #expect(ColorHex.components("7C3AED") == nil)
        #expect(ColorHex.components("#7C3AE") == nil)
        #expect(ColorHex.components("#GGGGGG") == nil)
    }

    @Test func aColourRoundTripsThroughSwiftUI() {
        for hex in ["#FFFFFF", "#000000", "#7C3AED", "#FF1F6B", "#FFDD00"] {
            #expect(ColorHex.hex(ColorHex.color(hex), withAlpha: false) == hex)
        }
        #expect(ColorHex.hex(ColorHex.color("#000000A0"), withAlpha: true) == "#000000A0")
        #expect(ColorHex.format(r: 1, g: 0, b: 0.5) == "#FF0080")
    }
}
