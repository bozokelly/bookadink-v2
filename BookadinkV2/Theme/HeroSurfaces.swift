import SwiftUI

// MARK: - Premium hero / background surface system
//
// A curated family of atmospheric backgrounds for hero areas, featured
// cards, onboarding, paywall surfaces, achievements, empty states and
// spotlight content. Composes (back→front):
//
//   1. Deep tonal LinearGradient (palette-driven)
//   2. Optional ambient lighting (palette-tinted radial highlight)
//   3. Subtle pattern overlay (diagonal / mesh / contour / court /
//      bubbles / flow / coral — or none for pure ambient surfaces)
//   4. Optional bottom vignette for text legibility
//
// All overlays render at low contrast (white at ~0.035–0.05 opacity) at
// roughly the visual weight of the legacy diagonal stripe. Patterns are
// "felt rather than seen" — the same surface can sit unchanged behind
// titles, body text, status pills and avatars.
//
// This file is purely additive — the existing inline gradient + Canvas
// constructions in UnifiedGameCard, BookingCompactCard, ClubHeroView,
// GameDetailView etc. continue to work and can opt into HeroSurface
// gradually without changing layout, sizing, or component logic.

// MARK: - HeroPalette

/// Premium tonal families. Order is preserved for the first six entries
/// so deterministic seeding overlaps the legacy 6-palette mapping where
/// possible. Two new families (`plumNoir`, `deepTeal`) expand the set.
enum HeroPalette: String, CaseIterable, Sendable {
    case midnightNavy
    case graphiteCharcoal
    case emeraldForest
    case premiumTan
    case roseBurgundy
    case slateAtmosphere
    case plumNoir
    case deepTeal

    var base: Color {
        switch self {
        case .midnightNavy:     return Brand.tonalNavyBase
        case .graphiteCharcoal: return Brand.tonalCharcoalBase
        case .emeraldForest:    return Brand.tonalForestBase
        case .premiumTan:       return Brand.tonalTanBase
        case .roseBurgundy:     return Brand.tonalRoseBase
        case .slateAtmosphere:  return Brand.tonalSlateBase
        case .plumNoir:         return Brand.tonalPlumBase
        case .deepTeal:         return Brand.tonalTealBase
        }
    }

    var deep: Color {
        switch self {
        case .midnightNavy:     return Brand.tonalNavyDeep
        case .graphiteCharcoal: return Brand.tonalCharcoalDeep
        case .emeraldForest:    return Brand.tonalForestDeep
        case .premiumTan:       return Brand.tonalTanDeep
        case .roseBurgundy:     return Brand.tonalRoseDeep
        case .slateAtmosphere:  return Brand.tonalSlateDeep
        case .plumNoir:         return Brand.tonalPlumDeep
        case .deepTeal:         return Brand.tonalTealDeep
        }
    }

    /// Brighter palette-tinted highlight used by the ambient lighting layer.
    /// Kept restrained — never a saturated neon, never a "rainbow" pop.
    var accent: Color {
        switch self {
        case .midnightNavy:     return Color(hex: "4A6BA0")
        case .graphiteCharcoal: return Color(hex: "5C6166")
        case .emeraldForest:    return Color(hex: "2F7A52")
        case .premiumTan:       return Color(hex: "D6BFA3")
        case .roseBurgundy:     return Color(hex: "C99099")
        case .slateAtmosphere:  return Color(hex: "6E8093")
        case .plumNoir:         return Color(hex: "8B5C90")
        case .deepTeal:         return Color(hex: "3F8389")
        }
    }

    func gradient(direction: HeroGradientDirection = .diagonal) -> LinearGradient {
        LinearGradient(
            colors: [base, deep],
            startPoint: direction.start,
            endPoint: direction.end
        )
    }
}

// MARK: - HeroGradientDirection

enum HeroGradientDirection: Sendable {
    /// top → bottom — used by date blocks and tall narrow surfaces.
    case vertical
    /// topLeading → bottomTrailing — used by hero areas and featured cards.
    case diagonal
    /// leading → trailing — used by wide banners.
    case horizontal

    var start: UnitPoint {
        switch self {
        case .vertical:   return .top
        case .diagonal:   return .topLeading
        case .horizontal: return .leading
        }
    }
    var end: UnitPoint {
        switch self {
        case .vertical:   return .bottom
        case .diagonal:   return .bottomTrailing
        case .horizontal: return .trailing
        }
    }
}

// MARK: - HeroPattern

/// Subtle texture overlays. All canvases stroke/fill at white opacity
/// ~0.035–0.05 to match the visual weight of the legacy diagonal lines.
enum HeroPattern: String, CaseIterable, Sendable {
    /// Legacy diagonal stripe DNA — preserved exactly (14pt, white 0.045).
    case diagonal
    /// Soft sport-net mesh — vertical + horizontal grid at half weight.
    case mesh
    /// Premium contour-line waves — five stacked low-amplitude sine curves.
    case contour
    /// Understated court-line schematic — center vertical + two kitchen lines.
    case court
    /// Ultra-soft bubble field — tiny offset circles in a hex grid.
    case bubbles
    /// Soft geometric flow lines — three sweeping quadratic arcs.
    case flow
    /// Coral / Truchet — a winding maze of quarter-circle arcs that
    /// visually reads as organic continuous lines (replaces the legacy
    /// 1px-dot `grain` pattern, which was indistinguishable from `none`
    /// at the canonical 0.04–0.05 overlay opacity).
    case coral
    /// No texture — relies entirely on palette + lighting (use with `.center` lighting).
    case none

    @ViewBuilder
    var view: some View {
        switch self {
        case .diagonal: PatternDiagonal()
        case .mesh:     PatternMesh()
        case .contour:  PatternContour()
        case .court:    PatternCourt()
        case .bubbles:  PatternBubbles()
        case .flow:     PatternFlow()
        case .coral:    PatternCoral()
        case .none:     EmptyView()
        }
    }
}

// MARK: - HeroLighting

/// Optional palette-tinted radial highlight that gives the surface its
/// "directional lighting" feel. Set to `.none` for flat tonal surfaces.
enum HeroLighting: Sendable {
    case none
    case topRight
    case topLeft
    case bottomLeft
    case center

    fileprivate func anchor() -> UnitPoint? {
        switch self {
        case .none:       return nil
        case .topRight:   return UnitPoint(x: 0.85, y: 0.05)
        case .topLeft:    return UnitPoint(x: 0.15, y: 0.05)
        case .bottomLeft: return UnitPoint(x: 0.10, y: 0.95)
        case .center:    return UnitPoint(x: 0.50, y: 0.40)
        }
    }
}

// MARK: - HeroVignette

/// Optional bottom-fade overlay that hardens the surface for white text.
enum HeroVignette: Sendable {
    case none
    /// Subtle bottom darken (≈30% black at the bottom edge). Default for
    /// hero strips with body copy below.
    case bottom
    /// Heavier bottom darken for surfaces that hold large white headlines.
    case bottomStrong

    @ViewBuilder
    fileprivate var view: some View {
        switch self {
        case .none:
            EmptyView()
        case .bottom:
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.28), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
        case .bottomStrong:
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.05), location: 0.0),
                    .init(color: .clear, location: 0.30),
                    .init(color: .black.opacity(0.45), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

// MARK: - HeroSurface

/// Composed premium background surface. Use as a `.background(...)`,
/// inside a `ZStack`, or directly with a `.frame(...)` for fixed hero
/// strips. Never overlays content on its own — callers position content
/// on top with their existing layouts.
struct HeroSurface: View {
    var palette: HeroPalette
    var pattern: HeroPattern = .diagonal
    var lighting: HeroLighting = .topRight
    var vignette: HeroVignette = .none
    var direction: HeroGradientDirection = .diagonal

    var body: some View {
        ZStack {
            palette.gradient(direction: direction)

            if let anchor = lighting.anchor() {
                RadialGradient(
                    colors: [palette.accent.opacity(0.38), .clear],
                    center: anchor,
                    startRadius: 12,
                    endRadius: 320
                )
                .allowsHitTesting(false)
            }

            pattern.view
                .allowsHitTesting(false)

            vignette.view
                .allowsHitTesting(false)
        }
    }
}

extension HeroSurface {
    /// Deterministic surface for a stable seed (e.g. `club.id`, `game.id`).
    /// Palette and pattern are mixed independently so identical seeds keep
    /// their identity across launches but every surface in a list still
    /// feels distinct rather than uniform.
    static func deterministic(
        seed: some Hashable,
        pattern overridePattern: HeroPattern? = nil,
        lighting: HeroLighting = .topRight,
        vignette: HeroVignette = .none,
        direction: HeroGradientDirection = .diagonal
    ) -> HeroSurface {
        let raw = UInt(bitPattern: seed.hashValue)
        let palette = HeroPalette.allCases[
            Int(raw % UInt(HeroPalette.allCases.count))
        ]
        let chosen: HeroPattern
        if let overridePattern {
            chosen = overridePattern
        } else {
            // Mix the seed before reusing it for pattern selection so
            // palette and pattern do not co-vary in lockstep.
            let mixed = (raw ^ (raw >> 13)) &* 2654435761
            // Auto rotation is restricted to the curated premium texture set:
            // `.none` is opt-in only, and `.court` is permanently excluded
            // (no sports-template visual language in automatic surfaces).
            let textured = HeroPattern.allCases.filter { $0 != .none && $0 != .court }
            chosen = textured[Int(mixed % UInt(textured.count))]
        }
        return HeroSurface(
            palette: palette,
            pattern: chosen,
            lighting: lighting,
            vignette: vignette,
            direction: direction
        )
    }

    /// Composes a `HeroSurface` for a club. Reads the club's pinned palette
    /// and pattern selections; falls back to deterministic auto-rotation
    /// (seeded from `club.id`) on either axis the owner hasn't pinned. Both
    /// nil ⇒ fully automatic. The `.court` pattern is never produced from
    /// auto rotation — it is excluded from the curated premium set.
    static func forClub(
        _ club: Club,
        lighting: HeroLighting = .topRight,
        vignette: HeroVignette = .none,
        direction: HeroGradientDirection = .diagonal
    ) -> HeroSurface {
        let auto = HeroSurface.deterministic(
            seed: club.id,
            lighting: lighting,
            vignette: vignette,
            direction: direction
        )
        let palette = club.appearancePaletteKey.flatMap(HeroPalette.init(rawValue:))
            ?? auto.palette
        let pinnedPattern = club.appearancePatternKey
            .flatMap(HeroPattern.init(rawValue:))
        let pattern: HeroPattern
        if let pinnedPattern, pinnedPattern != .court {
            pattern = pinnedPattern
        } else {
            pattern = auto.pattern
        }
        return HeroSurface(
            palette: palette,
            pattern: pattern,
            lighting: lighting,
            vignette: vignette,
            direction: direction
        )
    }

    /// Composes a `HeroSurface` for a game. Reads the game's pinned
    /// palette and pattern selections; falls back to deterministic auto
    /// rotation (seeded from `game.id`) on either axis the admin hasn't
    /// pinned. Per-game seeding (rather than per-club) means:
    ///   1. Recurring games inherit the same pinned values from their
    ///      template at creation time, so every "Wednesday Night" instance
    ///      shares the chosen palette + pattern (visual familiarity).
    ///   2. One-off games still get a stable, distinct surface — the same
    ///      game always renders the same way across sessions.
    /// `.court` is never produced from auto rotation.
    static func forGame(
        _ game: Game,
        lighting: HeroLighting = .topRight,
        vignette: HeroVignette = .none,
        direction: HeroGradientDirection = .diagonal
    ) -> HeroSurface {
        let auto = HeroSurface.deterministic(
            seed: game.id,
            lighting: lighting,
            vignette: vignette,
            direction: direction
        )
        let palette = game.appearancePaletteKey.flatMap(HeroPalette.init(rawValue:))
            ?? auto.palette
        let pinnedPattern = game.appearancePatternKey
            .flatMap(HeroPattern.init(rawValue:))
        let pattern: HeroPattern
        if let pinnedPattern, pinnedPattern != .court {
            pattern = pinnedPattern
        } else {
            pattern = auto.pattern
        }
        return HeroSurface(
            palette: palette,
            pattern: pattern,
            lighting: lighting,
            vignette: vignette,
            direction: direction
        )
    }
}

// MARK: - Curated picker metadata

/// Friendly display labels and curated ordering for the appearance picker.
/// The order is editorial — the first item in each list is the safest /
/// most premium-feeling default.
enum HeroSurfaceCatalog {
    /// Palette families exposed to club owners, in display order.
    /// All eight `HeroPalette` cases are surfaced; `premiumTan` (Sandstone)
    /// is included so warm clubs have a non-cool option.
    static let palettes: [(palette: HeroPalette, label: String)] = [
        (.midnightNavy,     "Midnight"),
        (.graphiteCharcoal, "Graphite"),
        (.slateAtmosphere,  "Slate"),
        (.emeraldForest,    "Emerald"),
        (.deepTeal,         "Teal"),
        (.plumNoir,         "Plum"),
        (.roseBurgundy,     "Burgundy"),
        (.premiumTan,       "Sandstone"),
    ]

    /// Texture options exposed to club owners, in display order. The
    /// `.court` pattern is permanently excluded from selection.
    static let patterns: [(pattern: HeroPattern, label: String)] = [
        (.diagonal, "Diagonal"),
        (.flow,     "Flow"),
        (.contour,  "Contour"),
        (.mesh,     "Mesh"),
        (.bubbles,  "Bubbles"),
        (.coral,    "Coral"),
        (.none,     "Minimal"),
    ]
}

// MARK: - View modifier convenience

extension View {
    /// Place a premium hero surface behind any content. Equivalent to
    /// `.background(HeroSurface(palette: ..., pattern: ..., ...))`.
    func heroSurfaceBackground(
        palette: HeroPalette,
        pattern: HeroPattern = .diagonal,
        lighting: HeroLighting = .topRight,
        vignette: HeroVignette = .none,
        direction: HeroGradientDirection = .diagonal
    ) -> some View {
        background(
            HeroSurface(
                palette: palette,
                pattern: pattern,
                lighting: lighting,
                vignette: vignette,
                direction: direction
            )
        )
    }
}

// MARK: - Pattern primitives
//
// Each pattern is a private View so the public `HeroPattern` enum stays a
// thin selector. Canvases are drawn inside a GeometryReader-free Canvas
// so they redraw cleanly under view resizing.

private struct PatternDiagonal: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.045))
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                ctx.stroke(path, with: stroke, lineWidth: 1)
                x += 14
            }
        }
    }
}

private struct PatternMesh: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.035))
            let gap: CGFloat = 18
            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: stroke, lineWidth: 1)
                x += gap
            }
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: stroke, lineWidth: 1)
                y += gap
            }
        }
    }
}

private struct PatternContour: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.045))
            let lineCount = 5
            let period: CGFloat = 130
            let amplitude: CGFloat = 6
            for i in 0..<lineCount {
                let baseY = size.height * CGFloat(i + 1) / CGFloat(lineCount + 1)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: baseY))
                var x: CGFloat = 0
                while x < size.width {
                    let y = baseY + sin(x / period * .pi * 2) * amplitude
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 4
                }
                ctx.stroke(path, with: stroke, lineWidth: 1)
            }
        }
    }
}

private struct PatternCourt: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.04))
            let mid = size.width / 2
            // Vertical center line
            var v = Path()
            v.move(to: CGPoint(x: mid, y: 0))
            v.addLine(to: CGPoint(x: mid, y: size.height))
            ctx.stroke(v, with: stroke, lineWidth: 1)
            // Two horizontal "kitchen" lines at 32% / 68%
            let topY = size.height * 0.32
            let botY = size.height * 0.68
            var h1 = Path()
            h1.move(to: CGPoint(x: 0, y: topY))
            h1.addLine(to: CGPoint(x: size.width, y: topY))
            ctx.stroke(h1, with: stroke, lineWidth: 1)
            var h2 = Path()
            h2.move(to: CGPoint(x: 0, y: botY))
            h2.addLine(to: CGPoint(x: size.width, y: botY))
            ctx.stroke(h2, with: stroke, lineWidth: 1)
        }
    }
}

private struct PatternBubbles: View {
    var body: some View {
        Canvas { ctx, size in
            let fill = GraphicsContext.Shading.color(.white.opacity(0.05))
            let cell: CGFloat = 24
            let r: CGFloat = 1.6
            var row = 0
            var y: CGFloat = 0
            while y < size.height + cell {
                let xOffset: CGFloat = (row % 2 == 0) ? 0 : cell / 2
                var x: CGFloat = -cell + xOffset
                while x < size.width + cell {
                    let circle = Path(ellipseIn: CGRect(
                        x: x - r, y: y - r, width: r * 2, height: r * 2
                    ))
                    ctx.fill(circle, with: fill)
                    x += cell
                }
                y += cell * 0.866 // hex row spacing
                row += 1
            }
        }
    }
}

private struct PatternFlow: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.04))
            let arcs: [(CGFloat, CGFloat, CGFloat)] = [
                // (startY ratio, endY ratio, control offset)
                (0.18, 0.62, -0.15),
                (0.42, 0.86, -0.12),
                (0.65, 1.10, -0.18),
            ]
            for (startY, endY, ctrlOffset) in arcs {
                var path = Path()
                path.move(to: CGPoint(x: -size.width * 0.05, y: size.height * startY))
                path.addQuadCurve(
                    to: CGPoint(x: size.width * 1.05, y: size.height * endY),
                    control: CGPoint(
                        x: size.width * 0.5,
                        y: size.height * (startY + ctrlOffset)
                    )
                )
                ctx.stroke(path, with: stroke, lineWidth: 1)
            }
        }
    }
}

private struct PatternCoral: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(.white.opacity(0.05))
            let c: CGFloat = 12 // tile size
            let r = c / 2       // arc radius — quarter circles touch tile midpoints
            // Linear congruential generator — deterministic per-launch.
            var seed: UInt64 = 0xC0_2A_15_BA_BE_F0_0D
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    // One bit chooses the Truchet tile orientation.
                    // Adjacent tiles' arcs join at midpoints to form long
                    // winding curves — coral / fingerprint feel.
                    if (seed >> 33) & 1 == 0 {
                        // Tile A: top-left + bottom-right quarter arcs
                        var p1 = Path()
                        p1.addArc(
                            center: CGPoint(x: x, y: y),
                            radius: r,
                            startAngle: .degrees(0),
                            endAngle: .degrees(90),
                            clockwise: false
                        )
                        ctx.stroke(p1, with: stroke, lineWidth: 1)

                        var p2 = Path()
                        p2.addArc(
                            center: CGPoint(x: x + c, y: y + c),
                            radius: r,
                            startAngle: .degrees(180),
                            endAngle: .degrees(270),
                            clockwise: false
                        )
                        ctx.stroke(p2, with: stroke, lineWidth: 1)
                    } else {
                        // Tile B: top-right + bottom-left quarter arcs
                        var p1 = Path()
                        p1.addArc(
                            center: CGPoint(x: x + c, y: y),
                            radius: r,
                            startAngle: .degrees(90),
                            endAngle: .degrees(180),
                            clockwise: false
                        )
                        ctx.stroke(p1, with: stroke, lineWidth: 1)

                        var p2 = Path()
                        p2.addArc(
                            center: CGPoint(x: x, y: y + c),
                            radius: r,
                            startAngle: .degrees(270),
                            endAngle: .degrees(360),
                            clockwise: false
                        )
                        ctx.stroke(p2, with: stroke, lineWidth: 1)
                    }
                    x += c
                }
                y += c
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Hero palette family — diagonal DNA") {
    ScrollView {
        VStack(spacing: 14) {
            ForEach(HeroPalette.allCases, id: \.self) { palette in
                HeroSurface(palette: palette, pattern: .diagonal, lighting: .topRight)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text(palette.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(12)
                    }
            }
        }
        .padding(16)
    }
    .background(Brand.appBackground)
}

#Preview("Hero pattern set — midnight navy") {
    ScrollView {
        VStack(spacing: 14) {
            ForEach(HeroPattern.allCases, id: \.self) { pattern in
                HeroSurface(
                    palette: .midnightNavy,
                    pattern: pattern,
                    lighting: pattern == .none ? .center : .topRight,
                    vignette: .bottom
                )
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(pattern.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(12)
                }
            }
        }
        .padding(16)
    }
    .background(Brand.appBackground)
}

#Preview("Deterministic variation") {
    let seeds = (0..<8).map { UUID().hashValue ^ ($0 * 9176) }
    return ScrollView {
        VStack(spacing: 14) {
            ForEach(seeds, id: \.self) { seed in
                HeroSurface.deterministic(seed: seed, lighting: .topRight, vignette: .bottom)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
    }
    .background(Brand.appBackground)
}
#endif
