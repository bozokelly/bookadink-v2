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
        .init(id: "cool-dink", name: "Cool Dink", assetName: "avatar_cool_dink", fallbackSymbol: "sunglasses", fallbackTop: Color(hex: "#FFE15A"), fallbackBottom: Color(hex: "#F6A100")),
        .init(id: "rally-runner", name: "Rally Runner", assetName: "avatar_rally_runner", fallbackSymbol: "figure.pickleball", fallbackTop: Color(hex: "#80D67A"), fallbackBottom: Color(hex: "#3D8CFF")),
        .init(id: "court-pin", name: "Court Pin", assetName: "avatar_court_pin", fallbackSymbol: "mappin.circle.fill", fallbackTop: Color(hex: "#FFBE32"), fallbackBottom: Color(hex: "#FF8A00")),
        .init(id: "pickle-wink", name: "Pickle Wink", assetName: "avatar_pickle_wink", fallbackSymbol: "face.smiling.inverse", fallbackTop: Color(hex: "#8ED4FF"), fallbackBottom: Color(hex: "#3D8CFF")),
        .init(id: "crossed-paddles", name: "Crossed Paddles", assetName: "avatar_crossed_paddles", fallbackSymbol: "figure.pickleball", fallbackTop: Color(hex: "#7ED9A6"), fallbackBottom: Color(hex: "#34B36B")),
        .init(id: "neon-rally", name: "Neon Rally", assetName: "avatar_neon_rally", fallbackSymbol: "sparkles", fallbackTop: Color(hex: "#B17CFF"), fallbackBottom: Color(hex: "#7A56E8")),
        .init(id: "crown-court", name: "Crown Court", assetName: "avatar_crown_court", fallbackSymbol: "crown.fill", fallbackTop: Color(hex: "#FFD166"), fallbackBottom: Color(hex: "#F59E0B")),
        .init(id: "hero-duo", name: "Hero Duo", assetName: "avatar_hero_duo", fallbackSymbol: "person.2.crop.square.stack.fill", fallbackTop: Color(hex: "#5EEAD4"), fallbackBottom: Color(hex: "#22C55E")),
        .init(id: "power-dink", name: "Power Dink", assetName: "avatar_power_dink", fallbackSymbol: "bolt.fill", fallbackTop: Color(hex: "#C084FC"), fallbackBottom: Color(hex: "#7C3AED"))
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)

            if let image = UIImage(named: preset.assetName) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: variant == .club ? .fill : .fit)
                    .scaleEffect(variant == .club ? 1.08 : 1.0)
                    .padding(variant == .club ? 0 : 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: preset.fallbackSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Brand.slateBlue)
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Brand.slateBlue.opacity(0.14), lineWidth: 1)
        )
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
