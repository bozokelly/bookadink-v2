import SwiftUI

struct GlassCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color = Brand.frostedSurface
    var strokeOpacity: Double = 0.18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(strokeOpacity), lineWidth: 1)
                    )
            )
            .shadow(color: Brand.brandPrimaryDarker.opacity(0.12), radius: 14, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
    }
}

struct PrimaryCTAButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let fillColor = Brand.emeraldAction.opacity(isPressed ? 0.9 : 1)
        let shadowColor = Brand.emeraldAction.opacity(isPressed ? 0.12 : 0.22)
        let shadowRadius: CGFloat = isPressed ? 6 : 10
        let shadowY: CGFloat = isPressed ? 3 : 6

        return configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .scaleEffect(isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

struct SecondaryFrostedButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let foreground = Color.white.opacity(isPressed ? 0.9 : 1)
        let fill = Color.white.opacity(isPressed ? 0.16 : 0.20)

        return configuration.label
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Brand.brandPrimaryDarker.opacity(0.08), radius: 8, x: 0, y: 4)
            .scaleEffect(isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24, tint: Color = Brand.frostedSurface) -> some View {
        modifier(GlassCardStyle(cornerRadius: cornerRadius, tint: tint))
    }

    func actionBorder(cornerRadius: CGFloat = 16, color: Color, lineWidth: CGFloat = 1.25) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(color, lineWidth: lineWidth)
        )
    }

    func segmentPillStyle(active: Bool, cornerRadius: CGFloat = 18) -> some View {
        let foreground: Color = active ? .white : Color.white.opacity(0.68)
        let fill = active ? Brand.brandPrimaryLight.opacity(0.88) : Color.white.opacity(0.14)
        let stroke = active ? Color.white.opacity(0.26) : Color.white.opacity(0.16)

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
            .shadow(color: active ? Brand.brandPrimaryDarker.opacity(0.12) : .clear, radius: 8, x: 0, y: 3)
    }

    func filterChipStyle(selected: Bool, cornerRadius: CGFloat = 12) -> some View {
        let foreground = selected ? Color.white : Brand.brandPrimaryDarker
        let fill = selected ? Brand.brandPrimary.opacity(0.9) : Color.white.opacity(0.78)
        let stroke = selected ? Color.white.opacity(0.18) : Brand.brandPrimary.opacity(0.14)

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
                    .stroke(stroke, lineWidth: 1)
            )
    }

    func appErrorCardStyle(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.errorRed.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.errorRed.opacity(0.25), lineWidth: 1)
            )
    }
}
