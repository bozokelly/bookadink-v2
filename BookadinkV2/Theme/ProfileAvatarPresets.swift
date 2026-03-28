import SwiftUI
import UIKit

struct ProfileAvatarPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let assetName: String
    let fallbackSymbol: String
    let fallbackTop: Color
    let fallbackBottom: Color
}

enum ProfileAvatarPresets {
    static let all: [ProfileAvatarPreset] = [
        .init(id: "paddle",       name: "Paddle",        assetName: "avatar_paddle",       fallbackSymbol: "figure.pickleball", fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "paddle-ball",  name: "Paddle & Ball", assetName: "avatar_paddle_ball",  fallbackSymbol: "figure.pickleball", fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "paddles-ball", name: "Paddles",       assetName: "avatar_paddles_ball", fallbackSymbol: "figure.pickleball", fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "ball",         name: "Ball",          assetName: "avatar_ball",         fallbackSymbol: "circle.dotted",     fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "net",          name: "Net",           assetName: "avatar_net",          fallbackSymbol: "square.grid.3x3",   fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "court",        name: "Court",         assetName: "avatar_court",        fallbackSymbol: "rectangle.split.2x2", fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "visor",        name: "Visor",         assetName: "avatar_visor",        fallbackSymbol: "theatermasks",      fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
        .init(id: "cap",          name: "Cap",           assetName: "avatar_cap",          fallbackSymbol: "person.fill",       fallbackTop: Color(hex: "#1A3A2A"), fallbackBottom: Color(hex: "#0D1F15")),
    ]

    static func preset(for id: String?) -> ProfileAvatarPreset? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }
}

struct ProfileAvatarArtwork: View {
    enum Variant {
        case standard
        case club
    }

    let preset: ProfileAvatarPreset
    var variant: Variant = .standard

    var body: some View {
        ZStack {
            if let image = UIImage(named: preset.assetName) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: variant == .club ? .fill : .fit)
                    .scaleEffect(variant == .club ? 1.08 : 1.0)
                    .padding(variant == .club ? 0 : 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .mask(
                        RadialGradient(
                            colors: [.white, .white, .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 46
                        )
                    )
            } else {
                Image(systemName: preset.fallbackSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Brand.slateBlue)
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }
}

struct ProfileAvatarBadge: View {
    let presetID: String?
    let fallbackInitials: String

    var body: some View {
        if let preset = ProfileAvatarPresets.preset(for: presetID) {
            ProfileAvatarArtwork(preset: preset)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.slateBlue.opacity(0.88))
                .overlay(
                    Text(fallbackInitials)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
    }
}
