import SwiftUI

/// Design tokens for the easemo UI (dark theme, purple accent, SF Pro).
enum EasemoTheme {
    // MARK: Background
    static let bgPrimary = Color(red: 11 / 255, green: 15 / 255, blue: 26 / 255)
    static let bgGradientTop = Color(red: 21 / 255, green: 26 / 255, blue: 46 / 255)
    static let bgGradientBottom = Color(red: 28 / 255, green: 31 / 255, blue: 58 / 255)

    // MARK: Panels
    static let panelFill = Color(red: 26 / 255, green: 30 / 255, blue: 50 / 255).opacity(0.8)
    static let panelBorder = Color.white.opacity(0.05)

    // MARK: Accent gradient
    static let accentPurple = Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
    static let accentIndigo = Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentPurple, accentIndigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Recording
    static let recordRed = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
    static let recordRedDim = Color(red: 200 / 255, green: 45 / 255, blue: 40 / 255)
    static let recordGlow = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255).opacity(0.4)

    // MARK: Text
    static let textPrimary = Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255)
    static let textSecondary = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
    static let textMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)

    // MARK: Controls
    static let sliderTrackInactive = Color(red: 42 / 255, green: 52 / 255, blue: 74 / 255)

    // MARK: Layout
    static let radiusButton: CGFloat = 10
    static let radiusPanel: CGFloat = 13
    static let radiusInput: CGFloat = 8

    static let panelShadow = Shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 10)

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}

extension View {
    func easemoPanelStyle() -> some View {
        self
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.35)
                    RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                        .fill(EasemoTheme.panelFill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                    .stroke(EasemoTheme.panelBorder, lineWidth: 1)
            )
            .shadow(
                color: EasemoTheme.panelShadow.color,
                radius: EasemoTheme.panelShadow.radius,
                x: EasemoTheme.panelShadow.x,
                y: EasemoTheme.panelShadow.y
            )
    }
}
