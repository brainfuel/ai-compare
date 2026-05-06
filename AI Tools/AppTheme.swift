import SwiftUI

enum AppTheme {
    // Primary brand — slate blue #4C75A1
    static let brandTint = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)

    // Canvas
    static let canvasBackground = Color(white: 0.955)

    // Surfaces
#if os(macOS)
    static let surfacePrimary = Color(nsColor: .textBackgroundColor)
    static let surfaceSecondary = Color(white: 0.945)
    static let surfaceGrouped = Color(white: 0.933)
#else
    static let surfacePrimary = Color(white: 0.99)
    static let surfaceSecondary = Color(white: 0.945)
    static let surfaceGrouped = Color(white: 0.933)
#endif

    // Node card accents
    static let nodeInput = Color(red: 76.0 / 255.0, green: 137.0 / 255.0, blue: 204.0 / 255.0)
    static let nodeOutput = Color(red: 64.0 / 255.0, green: 166.0 / 255.0, blue: 153.0 / 255.0)
    static let nodeAgent = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)
    static let nodeHuman = Color(red: 82.0 / 255.0, green: 172.0 / 255.0, blue: 120.0 / 255.0)

    // Subtle border for cards
    static let cardBorder = Color.black.opacity(0.06)
    static let cardShadow = Color.black.opacity(0.06)
}
