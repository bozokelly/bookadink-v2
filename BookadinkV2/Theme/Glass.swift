import SwiftUI

// MARK: - Card

struct GlassCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color = Brand.cardBackground

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Brand.softOutline, lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Primary CTA Button (dark fill, white label)

struct PrimaryCTAButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        return configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.primaryText.opacity(isPressed ? 0.82 : 1.0))
            )
            .scaleEffect(isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

// MARK: - Secondary Button (white surface, dark outline)

struct SecondaryFrostedButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let foreground = Brand.primaryText.opacity(isPressed ? 0.7 : 1.0)

        return configuration.label
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

// MARK: - View Extensions

extension View {
    func glassCard(cornerRadius: CGFloat = 24, tint: Color = Brand.cardBackground) -> some View {
        modifier(GlassCardStyle(cornerRadius: cornerRadius, tint: tint))
    }

    func actionBorder(cornerRadius: CGFloat = 16, color: Color, lineWidth: CGFloat = 1.25) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(color, lineWidth: lineWidth)
        )
    }

    /// Segment / tab pill — active: dark fill + white label; inactive: outline only.
    func segmentPillStyle(active: Bool, cornerRadius: CGFloat = 18) -> some View {
        let foreground: Color = active ? .white : Brand.secondaryText
        let fill: Color       = active ? Brand.primaryText : Color.clear
        let stroke: Color     = active ? Color.clear : Brand.softOutline

        return self
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    /// Filter chip — selected: secondary surface fill; unselected: outline only.
    func filterChipStyle(selected: Bool, cornerRadius: CGFloat = 12) -> some View {
        let foreground: Color = selected ? Brand.primaryText : Brand.secondaryText
        let fill: Color       = selected ? Brand.secondarySurface : Color.clear

        return self
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
    }

    func appErrorCardStyle(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.errorRed.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.errorRed.opacity(0.22), lineWidth: 1)
            )
    }
}
