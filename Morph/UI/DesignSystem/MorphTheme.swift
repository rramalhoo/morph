import SwiftUI

enum MorphColor {
    static let background = Color.black
    static let surface = Color(white: 0x09 / 255)
    static let surfaceSecondary = Color(white: 0x17 / 255)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xAA / 255)
    static let hairline = Color.white.opacity(0.09)
    static let warning = Color(red: 1, green: 0.72, blue: 0.3)
    static let critical = Color(red: 1, green: 0.42, blue: 0.4)
    static let positive = Color(red: 0.45, green: 0.9, blue: 0.6)

    static func accent(_ preference: AccentPreference) -> Color {
        switch preference {
        case .neutral: Color(white: 0.86)
        case .white: .white
        case .blue: Color(red: 0.42, green: 0.68, blue: 1)
        case .mint: Color(red: 0.45, green: 0.9, blue: 0.78)
        case .orange: Color(red: 1, green: 0.66, blue: 0.36)
        case .pink: Color(red: 1, green: 0.52, blue: 0.7)
        }
    }
}

enum MorphFont {
    static let primary = Font.system(size: 13, weight: .semibold)
    static let secondary = Font.system(size: 12, weight: .regular)
    static let label = Font.system(size: 10, weight: .semibold)
    static let compact = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let timer = Font.system(size: 30, weight: .medium, design: .rounded).monospacedDigit()
    static let wordmark = Font.system(size: 12, weight: .bold, design: .rounded)
}

enum MorphSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

enum MorphRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let card: CGFloat = 14
}

enum MorphSize {
    /// Comfortable pointer target, even where the glyph is small.
    static let hitTarget: CGFloat = 28
    static let artwork: CGFloat = 76
    static let compactArtwork: CGFloat = 20
}

extension EnvironmentValues {
    @Entry var morphAccent: Color = MorphColor.accent(.neutral)
    @Entry var morphMotion: MorphMotion = MorphMotion(intensity: .standard, reduced: false)
}
