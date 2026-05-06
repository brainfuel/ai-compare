import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum AppTheme {
    // Primary brand — slate blue #4C75A1
    static let brandTint = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)

    // Canvas
    static let canvasBackground = dynamicColor(light: 0.955, dark: 0.11)

    // Surfaces
#if os(macOS)
    static let surfacePrimary = Color(nsColor: .textBackgroundColor)
#else
    static let surfacePrimary = dynamicColor(light: 0.99, dark: 0.18)
#endif
    static let surfaceSecondary = dynamicColor(light: 0.945, dark: 0.14)
    static let surfaceGrouped = dynamicColor(light: 0.933, dark: 0.09)

    // Node card accents
    static let nodeInput = Color(red: 76.0 / 255.0, green: 137.0 / 255.0, blue: 204.0 / 255.0)
    static let nodeOutput = Color(red: 64.0 / 255.0, green: 166.0 / 255.0, blue: 153.0 / 255.0)
    static let nodeAgent = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)
    static let nodeHuman = Color(red: 82.0 / 255.0, green: 172.0 / 255.0, blue: 120.0 / 255.0)

    // Subtle border for cards
    static let cardBorder = Color.primary.opacity(0.08)
    static let cardShadow = Color.black.opacity(0.06)

    private static func dynamicColor(light: CGFloat, dark: CGFloat) -> Color {
#if canImport(UIKit)
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: dark, alpha: 1)
                : UIColor(white: light, alpha: 1)
        })
#elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) == .darkAqua
                || appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) == .vibrantDark
            return isDark
                ? NSColor(white: dark, alpha: 1)
                : NSColor(white: light, alpha: 1)
        })
#else
        return Color(white: light)
#endif
    }
}
