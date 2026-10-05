import SwiftUI

/// `#RRGGBB` and `#RRGGBBAA`, the colour format the API and the engine use.
public enum ColorHex {
    /// Components 0...1, or nil if `hex` is not a colour.
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let byte = { (shift: UInt64) in Double((value >> shift) & 0xFF) / 255 }
        return hasAlpha
            ? (byte(24), byte(16), byte(8), byte(0)) : (byte(16), byte(8), byte(0), 1)
    }

    public static func format(r: Double, g: Double, b: Double, a: Double? = nil) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        guard let a else { return rgb }
        return rgb + String(format: "%02X", byte(a))
    }

    public static func color(_ hex: String) -> Color {
        let c = components(hex) ?? (0, 0, 0, 1)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// The hex of a colour; `withAlpha` keeps its opacity (the shadow's colour has one).
    public static func hex(_ color: Color, withAlpha: Bool) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        return format(
            r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue),
            a: withAlpha ? Double(resolved.opacity) : nil)
    }
}
