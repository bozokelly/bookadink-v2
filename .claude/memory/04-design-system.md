# Design System — Book A Dink

## Brand Color Tokens (`Brand` enum in `Theme/Brand.swift`)

### Core Palette
```swift
Brand.appBackground    = #F7F7F4   // warm off-white screen background
Brand.cardBackground   = .white    // card surface
Brand.secondarySurface = #F1F1EC   // secondary / hover surface
Brand.primaryText      = #111111   // near-black heading + body
Brand.secondaryText    = #6B7280   // muted grey metadata
Brand.tertiaryText     = #9CA3AF   // lighter muted labels
Brand.dividerColor     = #E7E5E4   // dividers
Brand.darkOutline      = #111111   // strong black outline
Brand.softOutline      = #D6D3D1   // subtle neutral outline
Brand.accentGreen      = #C3FF45   // neon-lime — 5–10% usage only (dots, micro-accents)
```

### Semantic / Action Colors
```swift
Brand.emeraldAction    = #2ECC71   // form / destructive CTA buttons (green)
Brand.softOrangeAccent = #FFA500   // spicyOrange alias
Brand.errorRed         = #E85C5C   // errors, destructive actions
```

### Legacy Token Aliases (kept for compile compatibility)
```swift
brandPrimary / brandPrimaryDark / brandPrimaryDarker → primaryText
brandPrimaryLight → secondaryText
powderBlue → softOutline
lightCyan → appBackground
slateBlue / slateBlueDark → primaryText
slateBlueLight → secondaryText
pineTeal → primaryText  (was teal, now dark neutral)
coralBlaze → errorRed
spicyOrange → softOrangeAccent
frostedSurface / frostedSurfaceStrong → cardBackground
frostedSurfaceSoft → secondarySurface
frostedBorder → softOutline
ink → primaryText
cream → appBackground
softCard → secondarySurface
mutedText → secondaryText
```

### Gradients
```swift
Brand.pageGradient  // flat off-white (no blue gradient)
Brand.accentGradient  // primaryText → secondaryText
```

## UI Component Modifiers (`Theme/Glass.swift`)

### `glassCard(cornerRadius:tint:)`
```swift
.background(RoundedRectangle(cornerRadius: 24).fill(Brand.cardBackground)
    .overlay(stroke Brand.softOutline lineWidth 1))
.shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
```
Default cornerRadius: 24. Call as `.glassCard()` on any View.

### `PrimaryCTAButtonStyle` (dark fill, white label)
Dark fill (`Brand.primaryText`), white label, cornerRadius 16, scale 0.98 on press.

### `SecondaryFrostedButtonStyle` (white surface, dark outline)
White card background, `Brand.softOutline` stroke, cornerRadius 16.

### `segmentPillStyle(active:cornerRadius:)`
Active: dark fill + white label. Inactive: outline only (`Brand.softOutline`).
Font: `.callout.weight(.semibold)`. Used for `ClubDetailTab` pills.

### `filterChipStyle(selected:cornerRadius:)`
Selected: `Brand.secondarySurface` fill. Unselected: outline only.
Font: `.caption.weight(.semibold)`.

### `actionBorder(cornerRadius:color:lineWidth:)`
Adds a colored `RoundedRectangle` stroke overlay.

### `appErrorCardStyle(cornerRadius:)`
`Brand.errorRed.opacity(0.08)` fill + `Brand.errorRed.opacity(0.22)` stroke.

## Typography Patterns
- Headings: `.title2.weight(.bold)` or `.title3.weight(.semibold)`
- Body: `.body` with `Brand.primaryText`
- Metadata/labels: `.caption` or `.footnote` with `Brand.secondaryText`
- Pill/chip labels: `.callout.weight(.semibold)` or `.caption.weight(.semibold)`

## Layout Conventions
- Screen background: `Brand.appBackground` (flat — no gradient)
- Card padding: typically 16–20pt horizontal, 12–16pt vertical
- Standard corner radius: 24pt (cards), 16pt (buttons), 12pt (chips)
- `String.normalizedAddress()`: trim, collapse whitespace, title-case, truncate at 40 chars — canonical address display

## Do NOT Reintroduce
- `.blendMode(.screen)` on the app logo — current asset has transparent background, does not need it
- "Win Rate" stat pill in `GamesPlayedCard` — no backing data
- `fullScreenCover(isPresented: .constant(appState.isAuthenticating))` in `AuthWelcomeView` — fires on token refresh and overlays `MainTabView`

## DUPR Chart (`DUPRHistoryCard`)
- Black line, black dots with white border
- Y-axis: DUPR values
- X-axis: DD/MM dates as `.annotation(position: .bottom)` on each PointMark (NOT `chartXAxis` renderer — avoids last label clipping)
