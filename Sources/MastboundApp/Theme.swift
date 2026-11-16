import SwiftUI

/// One small set of design tokens. Dark only.
enum Theme {
    static let background = Color(red: 0.055, green: 0.059, blue: 0.067)   // #0E0F11
    static let surface = Color(red: 0.090, green: 0.094, blue: 0.106)      // #17181B
    static let surfaceRaised = Color(red: 0.122, green: 0.125, blue: 0.141) // #1F2024
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.16)
    static let textPrimary = Color(red: 0.949, green: 0.949, blue: 0.953)  // #F2F2F3
    static let textSecondary = Color(red: 0.545, green: 0.553, blue: 0.576) // #8B8D93
    static let textTertiary = Color(red: 0.373, green: 0.380, blue: 0.400)  // #5F6166
    static let accent = Color(red: 0.494, green: 0.820, blue: 0.722)        // #7ED1B8, the one accent
    static let warning = Color(red: 0.929, green: 0.733, blue: 0.420)       // #EDBB6B, recovery only

    static let radius: CGFloat = 12
    static let spacing: CGFloat = 8
    static let windowSize = CGSize(width: 400, height: 560)
}

/// Full-width primary button: light fill, dark text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.textPrimary.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.3))
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet secondary button: outline only.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfaceRaised : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.stroke)
            )
            .contentShape(Rectangle())
    }
}

/// Small caps label above a section.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
