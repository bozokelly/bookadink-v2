# Book A Dink — Design System v1

**Status:** Canonical. All future UI work on iOS, web, and Android must conform.  
**Owner:** Product / Engineering  
**Last updated:** 2026-04-28

---

## 0. Philosophy

Book A Dink is a premium sports-booking product. The visual language must communicate trust, speed, and quality — not decoration. Every design decision should make the product feel faster or clearer, not richer or louder.

**Five governing rules:**

1. **Restraint before richness.** Add elements to solve problems, not to fill space.
2. **Hierarchy over decoration.** Type weight and size do the heavy lifting. Colour is a signal, not a theme.
3. **Neon is a reward.** `#80FF00` / `#C8FF3D` appears in at most one place per screen — never as background fill, never on text larger than 14pt.
4. **One component per job.** If two surfaces need a game card, they share one. No local re-implementations.
5. **Admin and player are the same product.** Admin surfaces use identical card patterns, typography, and spacing — differentiated by data, not visual language.

---

## 1. Colour System

### 1.1 Foundation Tokens

| Token | Hex | Usage |
|-------|-----|-------|
| `appBackground` | `#F7F7F4` | Page background only |
| `cardBackground` | `#FFFFFF` | All card surfaces |
| `secondarySurface` | `#F1F1EC` | Hover states, pressed states, secondary card tints |
| `primaryText` | `#111111` | Headings, body, primary CTA background |
| `secondaryText` | `#6B7280` | Metadata, supporting labels |
| `tertiaryText` | `#9CA3AF` | Placeholder, disabled, detail micro-labels |
| `dividerColor` | `#E7E5E4` | Horizontal separators |
| `softOutline` | `#D6D3D1` | Card strokes, input borders, inactive tabs |
| `darkOutline` | `#111111` | Strong borders where needed |

### 1.2 Accent Tokens

| Token | Hex | Usage |
|-------|-----|-------|
| `neonLime` | `#C8FF3D` | Single hero highlight per screen (underline, dot, streak) |
| `neonLimeSource` | `#80FF00` | Raw asset reference — prefer `neonLime` in UI |
| `emeraldAction` | `#2ECC71` | Confirmed/success states, "You're in" pills |
| `errorRed` | `#E85C5C` | Destructive actions, error banners |
| `warningOrange` | `#FFA500` | Waitlist, expiring holds, scheduled-game banners |
| `sunnyYellow` | `#FFDE96` | "Spots left" urgency pill (text: `#7A4A00`) |
| `starGold` | `#FFB800` | Review stars only |
| `pineTeal` | See Brand.swift | Membership active states, progress fill, edit icons |
| `slateBlue` | See Brand.swift | Credits, DUPR labels |
| `spicyOrange` | See Brand.swift | Notification accent (game-related) |

### 1.3 Tonal Hero Palette

Used for all hero gradients. Assigned deterministically via `abs(id.hashValue) % 6`. Never user-selectable.

| Index | Name | Base | Deep |
|-------|------|------|------|
| 0 | Navy | `#2A3A52` | `#16213A` |
| 1 | Charcoal | `#3A3D40` | `#1F2123` |
| 2 | Forest | `#1F3D2C` | `#0E2418` |
| 3 | Tan | `#B79F86` | `#7A6451` |
| 4 | Rose | `#9A6E73` | `#5E3F44` |
| 5 | Slate | `#4A5560` | `#2A323B` |

### 1.4 Prohibited Colour Usage

- **Never** use `neonLime` / `#80FF00` as a card background, button fill, or on text larger than 14pt.
- **Never** use pure `#000000` for backgrounds — use `primaryText` (`#111111`).
- **Never** use arbitrary hex colours in view files. Reference Brand tokens only.
- **Never** invent a seventh tonal hero pair. Extend the palette via a Brand token change, not inline.
- **Never** use `systemBackground` / `systemGray*` for semantic UI colour — use Brand tokens for cross-platform parity.

---

## 2. Typography

### 2.1 Scale

| Role | Size | Weight | Tracking | Usage |
|------|------|--------|----------|-------|
| Display | 42pt | `.bold` | -1.5 | Page hero headlines (Home only) |
| PageTitle | 32pt | `.bold` | 0 | Screen titles (Bookings, Notifications, Profile) |
| HeroTitle | 28pt | `.bold` | -0.6 | Game/Club hero overlay title |
| SectionTitle | 20pt | `.bold` | 0 | Card-level titles |
| CardTitle | 16–19pt | `.bold` | -0.4 | Game card titles, news headlines |
| Eyebrow | 11pt | `.semibold` | 1.2–1.6 | Section labels (uppercase, `secondaryText`) |
| Body | 14–15pt | `.regular` | 0 | General body copy |
| BodyStrong | 14–15pt | `.semibold` | 0 | Emphasized body |
| Label | 12–13pt | `.medium` | 0 | Metadata, time, location |
| LabelStrong | 12–13pt | `.semibold` | 0 | Stat values, status text |
| Caption | 10–11pt | `.medium` | 0.4–0.8 | Micro-labels, chip text, map pins |
| CaptionBold | 10–11pt | `.bold` | 0.5 | Date blocks (weekday, month) |

### 2.2 Design System Font (`design: .rounded`)

Use `.rounded` design variant for:
- Player-facing display numbers (PageTitle, stats)
- Avatar initials
- DUPR chart labels
- Badge titles

Do **not** use `.rounded` for prose body text, hero titles, or admin data tables.

### 2.3 Hero Overlay Text

All text rendered over tonal hero gradients:
- Primary (title, price): `white` at full opacity
- Secondary (club chip, time): `white.opacity(0.80)`
- Tertiary (detail micro-labels): `white.opacity(0.65)` or `tertiaryText` on light surfaces below the hero

### 2.4 Prohibited Typography Patterns

- **Never** use more than two font sizes on a single card component.
- **Never** vary font weight without varying size — use both together to establish hierarchy.
- **Never** use `.italic` style — not part of this design language.
- **Never** use `font(.largeTitle)` or larger without also applying negative tracking.

---

## 3. Spacing System

The grid is **4pt base**. Use multiples of 4; use 2pt only for tight refinements.

| Token | Value | Usage |
|-------|-------|-------|
| `space1` | 4pt | Icon-to-label gaps, dot indicators |
| `space2` | 8pt | Chip internal padding (vertical), tag rows |
| `space3` | 12pt | Card internal padding (tight), divider insets |
| `space4` | 14pt | Standard card internal padding (horizontal + vertical) |
| `space5` | 16pt | Section padding, standard screen edge insets |
| `space6` | 20pt | Section gaps |
| `space7` | 24pt | Large section separation |
| `space8` | 28–32pt | Hero section internal padding |

### 3.1 Screen Edge Insets

- **iOS scroll content:** `.padding(.horizontal, 16)`
- **Section headers:** `.padding(.horizontal, 16)`, `.padding(.top, 20)`
- **Bottom safe area buffer:** 96pt minimum when sticky footer present

### 3.2 Card Internal Padding

| Card Type | Padding |
|-----------|---------|
| Compact card (booking, notification row) | `14h × 14v` |
| Standard card | `16h × 16v` |
| Hero card (game detail, home) | Hero: no padding; detail area: `16h × 14–16v` |
| Stat/KPI card | `14h × 12v` |
| Chip / pill | `9–12h × 4–8v` |

---

## 4. Corner Radius

All corner radii use `.continuous` (squircle) style unless specified.

| Context | Radius |
|---------|--------|
| Chip / micro-pill | 6–10pt |
| Compact card | 12–14pt |
| Standard card | 16–18pt |
| Large card / sheet | 20–24pt |
| Map panel (top corners only) | 20pt |
| Bottom sheet presented card | 24pt |
| Full-bleed sheet drag indicator (Capsule) | pill |
| Inline avatar (not circular) | 18pt |
| Circular avatar | `.infinity` |
| Input field | 20pt |
| CTA button (primary/secondary) | 16pt |
| Show-all / tertiary button | 10–12pt |

---

## 5. Elevation & Shadow

| Level | Black Opacity | Radius | Y Offset | Usage |
|-------|--------------|--------|----------|-------|
| Flat | 0 | 0 | 0 | Chips, tags, inline rows |
| Card | 0.06 | 8pt | 2pt | Standard cards |
| Elevated card | 0.07–0.08 | 10–12pt | 3–4pt | Home hero cards, profile cards |
| Sheet | 0.10 | 16pt | -4pt | Bottom panels, map sheet |
| Map pin | 0.18–0.35 | 3–6pt | 1.5pt | Location pins |

**Rule:** Never apply shadow to a component that is itself a child of a card. Only the outermost container receives shadow.

---

## 6. Hero Section System

All hero sections are **deterministic**, **data-driven**, and **non-customisable by users**. There is one canonical hero pattern.

### 6.1 Hero Anatomy

```
┌─────────────────────────────────────────┐
│  Tonal gradient (Base → Deep, diagonal) │  ← Layer 1: Background
│  ┄┄┄ diagonal stripe overlay ┄┄┄┄┄┄┄  │  ← Layer 2: Texture
│  ░░░ vignette (top light → dark bot) ░░ │  ← Layer 3: Depth
│  [back btn]            [action btn]      │  ← Layer 4: Controls
│                                          │
│  [Club chip]           [Status pill]     │  ← Layer 5: Meta
│  Title text                              │
│  Time · Venue · Price                    │
└─────────────────────────────────────────┘
```

### 6.2 Hero Measurements

| Surface | Min Height | Aspect |
|---------|-----------|--------|
| Game Detail hero | 260pt | ~16:9 on most screens |
| Club Detail hero | Width ÷ 1.5 (max 380pt) | 1.5:1 |
| Home "Next Game" card | 186pt | Fixed |
| Home "Nearby" carousel card | 132pt | Fixed (248pt wide) |
| Booking date block | Full card height | 62pt wide |

### 6.3 Stripe Overlay

```swift
Canvas { ctx, size in
    var x: CGFloat = -size.height
    while x < size.width + size.height {
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
        ctx.stroke(path, with: .color(.white.opacity(0.045)), lineWidth: 1)
        x += 14
    }
}
```

Opacity `0.045` is canonical. Do not vary per surface.

### 6.4 Vignette Overlay

```swift
LinearGradient(
    colors: [.white.opacity(0.06), .clear, .black.opacity(0.22–0.32)],
    startPoint: .top,
    endPoint: .bottom
)
```

Bottom opacity: 0.22 (card heroes), 0.32 (full-screen game/club detail).

### 6.5 Control Overlays

- **Back / dismiss button:** 36×36 circle, `black.opacity(0.28)` fill, SF Symbol `chevron.left`, white icon, `shadow(radius:3)`
- **Overflow / action menu:** same treatment
- **Club chip / context chip:** `black.opacity(0.38)` fill, `white.opacity(0.18)` stroke, `cornerRadius(Capsule)`, 10–10.5pt semibold tracking 0.8, white text
- **Status pill:** Capsule shape — colours per §9 Status System

### 6.6 Prohibited Hero Patterns

- **Never** use a user-uploaded photo as a hero background without prior approval of the content moderation pipeline.
- **Never** overlay a solid colour block on a hero (use the vignette layer instead).
- **Never** vary the stripe opacity per card — it must be uniform across the system.
- **Never** apply the hero treatment to flat list rows or compact chips.

---

## 7. Card Hierarchy

There are exactly **four card tiers**. Never invent a fifth.

### Tier 1 — Hero Card

Full-width, tonal gradient hero with stripe and vignette. Used for the primary action item on a screen (next game, featured news, club detail).

**Rules:**
- One per screen.
- Always tappable as a unit — the entire card navigates.
- CTA button inside the detail area: 46pt height, `cornerRadius(12)`, `primaryText` background, white text.

### Tier 2 — Standard Card

White background (`cardBackground`), `softOutline` stroke (1pt), `cornerRadius(18–20)`, elevation-card shadow.

Used for: game rows in lists, club rows, notifications, profile sections, admin panels.

**Standard Card anatomy:**
```
┌──────────────────────────────────────┐
│  [Optional 3:1 or 1:1 image/icon]   │
│  ─────────────────────────────────  │
│  Eyebrow label          [Badge/Tag] │
│  Card Title                          │
│  Supporting label · metadata         │
│  ─────────────────────────────────  │
│  [Left detail]      [Right action]  │
└──────────────────────────────────────┘
```

### Tier 3 — Compact Card

No image. Fixed-height (~72–80pt). Used for booking rows, notification rows, list items that scroll in a feed.

**Compact Card anatomy (booking variant):**
```
┌──────┬────────────────────────────────┐
│ Date │  Title                 [Badge] │
│ Block│  Time · Venue                  │
│ 62pt │  [Status dot] Status text      │
└──────┴────────────────────────────────┘
```

Date block uses tonal gradient + stripe. Same 6-palette system as heroes.

### Tier 4 — Stat / KPI Card

Used for analytics, DUPR history, badge counts. Always has a header row (label + optional "See all" pill), a primary metric, and an optional chart or grid.

**Rules:**
- Never display more than 3 KPIs in one row.
- Progress bars: 6pt height, `cornerRadius(4)`, `pineTeal` fill, `systemGray5` track.
- Delta indicators: size 9 bold SF Symbol arrows.

### 7.1 Prohibited Card Patterns

- **Never** create a card with more than two levels of nested `VStack` padding.
- **Never** apply `listRowBackground` to achieve card appearance — use explicit `RoundedRectangle`.
- **Never** use `List` with `.insetGrouped` for premium card layouts — it produces system-styled cells that cannot match the design tokens.
- **Never** build a local card variant for a single screen. Propose a system extension first.

---

## 8. Game Card — Canonical Definition

**`UnifiedGameCard`** is the single game card component. All surfaces that show a game use this or a named subset (`HomeNextGameCard`, `HomeNearbyGameCard`). No other game card implementations are permitted.

### 8.1 UnifiedGameCard (Standard, Tier 2)

- White card, `softOutline` stroke, `cornerRadius(18–20)`, elevation-card shadow
- Left column: date/time block or club avatar
- Center column: game title (16–19pt bold), club name (13pt medium), time range (13pt regular, `secondaryText`), skill/format tags
- Right column: price (14pt bold), spots badge, avatar stack
- Avatar stack: 24pt circles, -14pt overlap, max 4 shown + overflow count
- Skill tag: 11pt medium, 9h×4v padding, `cornerRadius(6)`, `secondarySurface` fill

### 8.2 HomeNextGameCard (Hero, Tier 1)

Used exclusively in the "Your next game" Home section.

- Tonal hero (full §6 treatment), min height 186pt
- Club chip top-left, status pill top-right
- Game title 22–24pt bold white, time 13pt medium white/0.8
- Bottom area: avatar stack + "N players" label + CTA button
- CTA button: 46pt, `cornerRadius(12)`, full width minus 28pt horizontal padding

### 8.3 HomeNearbyGameCard (Compact Hero, Carousel)

Used exclusively in the "Games near you" horizontal carousel.

- Width: 248pt fixed. Hero: 132pt. Detail area: ~96pt.
- Same stripe + vignette hero pattern, scaled proportionally
- Price top-right (14pt bold white), skill/format chips bottom of hero
- Title 16pt bold, time 12pt medium, distance 11pt caption

### 8.4 Game Status Pills

All status pills are `Capsule`-shaped with 9–10h × 5–6v padding, 11pt semibold.

| Status | Background | Text |
|--------|-----------|------|
| Confirmed / "You're in" | `emeraldAction` | white |
| Pending payment / hold | `warningOrange.opacity(0.15)` | `warningOrange` dark |
| Waitlisted + position | `primaryText.opacity(0.08)` | `primaryText` |
| Spots left (2–5) | `sunnyYellow` | `#7A4A00` |
| 1 spot left | `errorRed.opacity(0.12)` | `errorRed` |
| Full | `systemGray4` | `systemGray` |
| Cancelled | `errorRed.opacity(0.12)` | `errorRed` |

---

## 9. Status System

A single status vocabulary used across all booking states. No ad-hoc colour assignments.

| State | Dot Colour | Label Style |
|-------|-----------|-------------|
| `confirmed` | `emeraldAction` | 12pt semibold, `emeraldAction` |
| `pending_payment` | `warningOrange` | 12pt semibold, `warningOrange` |
| `waitlisted` | `secondaryText` | 12pt semibold, `secondaryText` |
| `cancelled` | `errorRed` | 12pt semibold, `errorRed` |
| Scheduled (not yet live) | `warningOrange` | orange banner, see §16 |

Status dot: 7–8pt circle, filled solid.

---

## 10. Club Card — Canonical Definition

Club cards use Tier 2 (Standard Card) pattern with one modification: the left side shows a **44×44pt club avatar badge** (using the `ClubArtworkPresets` gradient + icon or a `custom_banner_url` thumbnail), never a hero gradient.

**Club Row anatomy:**
```
┌─────────────────────────────────────────┐
│ [44pt avatar]  Club Name      [Pin btn] │
│                Location · Members       │
│                [Category chip]          │
└─────────────────────────────────────────┘
```

### 10.1 Favourite Slot Cards

Used in "Your Clubs" / favourites section.

- Hero gradient from `AvatarGradients` palette (deterministic by `clubID`)
- Diagonal stripe overlay (§6.3)
- Club name: 15pt bold white
- Sub-label: 12pt medium white/0.75
- "Book" button: 36pt, `cornerRadius(10)`, `black.opacity(0.35)` fill, white text
- Full card tappable (hero, club info, book button all trigger navigation)
- Empty slot: dashed `softOutline` border, "Add club" label in `secondaryText`

### 10.2 Club Avatar Badge

- Size: 44pt (list row), 60pt (detail header), 34pt (notification icon)
- Gradient from `ClubArtworkPresets` — not user-customisable except via approved `custom_banner_url` upload
- Stroke: `white.opacity(0.18)`, 1pt, `cornerRadius(18)` continuous

---

## 11. Avatar System

All avatars use gradient backgrounds with text initials. No silhouette icons or grey placeholders.

### 11.1 Player Avatar

| Size | Radius | Font | Usage |
|------|--------|------|-------|
| 60pt | circle | 20pt bold rounded | Profile dashboard |
| 42pt | circle | 16pt bold rounded | Notification icon, review |
| 34pt | circle | 13pt bold rounded | Comment, small list |
| 24pt | circle | 9pt bold rounded | Game card avatar stack |

- Gradient assigned deterministically by `userID.hashValue % palette.count`
- Stroke: `white.opacity(0.18)`, 1–1.5pt
- Initials: first letter of first name + first letter of last name (e.g. "BK")
- Avatar stack overlap: -14pt (24pt size), -12pt (34pt size)

### 11.2 Prohibited Avatar Patterns

- **Never** show a grey circle for a user with a known name — initials are always available.
- **Never** use `AsyncImage` for player avatars unless an explicit profile photo upload pipeline is implemented (not currently in scope).
- **Never** vary the gradient palette per screen — gradients are identity markers.

---

## 12. Button Hierarchy

Exactly three button tiers. Use in descending order of priority per screen.

### Primary CTA

- Height: 46–50pt (standalone), 44pt (card-embedded)
- Background: `primaryText` (black) at full opacity; 0.82 when pressed
- Text: white, 15–17pt semibold
- `cornerRadius(16)` continuous
- Scale: 0.98 on press, `.easeOut(0.12s)`
- **One per screen.** The most important action only.

### Secondary / Frosted

- Height: 44pt
- Background: `cardBackground` fill, `softOutline` stroke 1pt
- Text: `primaryText`, 15pt semibold
- `cornerRadius(16)` continuous
- Opacity: 0.70 on press

### Tertiary / Text

- Height: 34pt (or inline)
- Background: clear or `secondarySurface` (tinted variant)
- Text: `secondaryText` or `pineTeal` (action), 13–14pt semibold
- `cornerRadius(10)` continuous
- Used for: "See all", "Show more", "Clear", tab-local secondary actions

### Destructive

- Follow Primary or Tertiary size depending on context
- Background (Primary variant): `errorRed`
- Background (Tertiary variant): clear, `errorRed` text
- **Always confirm before executing** (`.confirmationDialog` or sheet)

### Prohibited Button Patterns

- **Never** use more than one Primary CTA per screen.
- **Never** style a navigation link as a Primary CTA — navigation links use Tertiary or are embedded in Tier 1 cards.
- **Never** create a custom button shape outside this hierarchy. Corner radius must be from §4.
- **Never** disable a button visually with reduced opacity without also setting `.disabled(true)` on the SwiftUI view.

---

## 13. Chip / Tag System

| Type | Fill | Stroke | Font | Padding | Radius |
|------|------|--------|------|---------|--------|
| Filter chip (inactive) | clear | `softOutline` 1pt | 11pt semibold | 10h×8v | 12pt |
| Filter chip (active) | `secondarySurface` | `softOutline` 1pt | 11pt semibold | 10h×8v | 12pt |
| Segment pill (active) | `primaryText` | none | `callout` semibold | 12h×10v | 18pt |
| Segment pill (inactive) | clear | `softOutline` 1pt | `callout` semibold | 12h×10v | 18pt |
| Category / skill tag | `secondarySurface` | none | 11pt medium | 9h×4v | 6pt |
| Status badge | per §9 | none | 11pt semibold | 9h×5–6v | Capsule |
| Admin badge ("Comp", "Card") | see §17 | none | 11pt semibold | 8h×4v | Capsule |

**Rule:** Tags and chips never use `neonLime` as fill.

---

## 14. Section Headers

All section headers follow a strict two-row pattern:

```
EYEBROW LABEL                          [See all →]
Main Section Title
```

- Eyebrow: 11pt, `.semibold`, tracking 1.2, uppercase, `secondaryText`
- Title: 20–22pt, `.bold`, `primaryText` (or omitted when eyebrow alone is sufficient)
- "See all" link: Tertiary button style (§12), right-aligned
- Optional accent dot: 8pt circle, `emeraldAction`, placed left of eyebrow text for live/active sections
- Spacing above section header: 20pt; below: 8–12pt

---

## 15. Navigation & Tab System

### 15.1 Tab Bar (iOS)

- **5 tabs:** Home (house.fill), Clubs (building.2), Bookings (calendar), Notifications (bell), Profile (person.crop.circle)
- `tint: Brand.primaryText`
- Notification badge: system red, unread count
- `toolbarBackground(.visible)` — opaque

### 15.2 Navigation Stack

- Use `NavigationStack` for all linear flows
- Use `navigationDestination(item:)` for item-driven push navigation (preferred over `NavigationLink` with binding)
- Back button: system chevron; label hidden for pushed views (use `navigationBarBackButtonHidden(false)` with custom back label only when context requires it)

### 15.3 Bottom Sheet / Map Panel

- `UnevenRoundedRectangle` — top corners 20pt, bottom 0
- Shadow: `black.opacity(0.10)`, radius 16, y -4
- Drag handle: `Capsule` 36×4pt, `systemGray4`, centred at top
- States: collapsed (72pt) → partial (320pt) → expanded (82% screen height)
- Background: `cardBackground`

### 15.4 Modal Presentation

- Use `.sheet(item:)` for content sheets (game detail from notification, review prompt)
- Use `.sheet(isPresented:)` for standalone flows (create game, club settings)
- Use `NavigationStack` inside sheets that have their own push flow
- **Never** use `.fullScreenCover` on the main `TabView` level — it fires on token refresh

### 15.5 Prohibited Navigation Patterns

- **Never** `confirmationDialog("Club Actions", ...)` in `ClubDetailView` (production freeze)
- **Never** `containerRelativeFrame` in club navigation containers
- **Never** `fullScreenCover(isPresented: .constant(appState.isAuthenticating))` — overlays `MainTabView`

---

## 16. Empty States

All empty states use a Tier 2 card (`cornerRadius(22)`, `secondarySurface` tint) with:

```
[SF Symbol icon — 38pt, secondaryText]
Title (headline bold, primaryText)
Subtitle (subheadline, secondaryText)
[Optional CTA button — Tertiary style]
```

- Padding: 20pt all sides
- Icon never uses `neonLime`
- CTA only present when there is an immediately actionable path

---

## 17. Admin UI Rules

Admin surfaces are **the same product**. No special admin chrome, no grey "dashboard" aesthetic.

### 17.1 Admin-Only Badges (Payment Method)

Shown in attendee list, upcoming games — **admin/owner only**:

| Value | Label | Background | Text |
|-------|-------|-----------|------|
| `"stripe"` | Card | `slateBlue.opacity(0.12)` | `slateBlue` |
| `"admin"` | Comp | `systemGray5` | `systemGray` |
| `nil` (fee>0) | Unpaid | `warningOrange.opacity(0.12)` | `warningOrange` |

### 17.2 Admin Card Patterns

- Same Tier 2 / Tier 4 card patterns as player-facing
- Admin-specific content sections (join requests, member management, analytics) use a consistent header row: eyebrow label + action button (Tertiary CTA, right-aligned)
- No toolbar-level `Menu` items that also exist as in-page cards — one entry point per action

### 17.3 Admin Tools Menu Order

Fixed. Never reorder:
1. View / Edit Games
2. Create Game
3. `Divider`
4. Club Settings
5. `Divider`
6. Join Requests
7. Manage Members

### 17.4 Analytics / KPI Cards (Tier 4)

- Primary metric: 28–32pt, `.bold`, `.rounded` design, `primaryText`
- Delta: caption arrows (§2.1, delta row)
- Sparkline / chart: `pineTeal` line/fill; axis labels per `DUPRHistoryCard` pattern
- Max 3 KPIs per row; use 2-column grid for secondary stats

---

## 18. Banners and Warning States

| Type | Background | Stroke | Icon | Usage |
|------|-----------|--------|------|-------|
| Error | `errorRed.opacity(0.08)` | `errorRed.opacity(0.22)` 1pt | `xmark.circle` errorRed | Form errors, failed actions |
| Warning | `warningOrange.opacity(0.10)` | `warningOrange.opacity(0.22)` 1pt | `clock` orange | Hold expiry, scheduled games |
| Info | `slateBlue.opacity(0.07)` | `slateBlue.opacity(0.20)` 1pt | `info.circle` slateBlue | Credits, DUPR status, neutral info |
| Success | `emeraldAction.opacity(0.08)` | `emeraldAction.opacity(0.22)` 1pt | `checkmark.circle` green | Booking confirmed, save success |

- `cornerRadius(12–14)` continuous
- Padding: `12h × 9–10v`
- Font: 13pt body; label in semibold, sublabel in regular
- **Never** stack more than one banner per card section — use the highest-priority state only

### 18.1 Scheduled Game Banner

Displayed inside the games tab, admin-only, below the game header:

> ⚠ Not visible to the public · Goes live in Xd Yh Zm

- Warning banner style
- 55% opacity on the enclosing card
- Live countdown via `Timer.publish(every: 60)`

---

## 19. Auto-Save UI (Settings / Forms)

When a view uses debounced auto-save (club settings, profile settings):

- **AutoSavePill** component: Capsule, 11pt semibold, centred at screen bottom above tab bar
  - Saving: `secondarySurface` bg, `systemGray` text, `ProgressView` spinner 14pt
  - Saved: `emeraldAction.opacity(0.12)` bg, `emeraldAction` text, `checkmark` icon
  - Error: `errorRed.opacity(0.12)` bg, `errorRed` text, `xmark` icon
- No manual "Save" button when auto-save is active
- Debounce: 0.7–1.0s after last change before triggering save
- Suppress initial load: use `@State var isInitialLoad = true` pattern — do not trigger save on `onAppear`

---

## 20. Notification Row System

```
┌─────────────────────────────────────────┐
│ [42pt icon badge]  Title (2 lines)  [•] │
│                    Body (3 lines)        │
│                    Time label        [›] │
└─────────────────────────────────────────┘
```

- `cornerRadius(18)` continuous
- Unread: `accentColor.opacity(0.35)` stroke 1.5pt; read: `softOutline` 1pt
- Unread dot: 8pt, `pineTeal`, trailing edge
- Chevron indicator: only when `hasDestination == true`
- Icon badge: 42pt circle, `accentColor.opacity(0.15)` fill, 18pt semibold icon in `accentColor`
- Accent colour per notification type: see `accentForType()` in `NotificationsView`
- Padding: 14pt all sides

---

## 21. Map System

### 21.1 Pin Availability Colours

| Condition | Colour |
|-----------|--------|
| 6+ spots | `#34C759` (system green) |
| 2–5 spots or <3hrs | `#FF9500` (system orange) |
| 1 spot | `#FF3B30` (system red) |
| Full | `systemGray4` |

- Selected pin: larger, white background, `cornerRadius` scaled
- Pulsing ring on urgent pins (≤1hr, ≤2 spots): 1.3s opacity animation, scale 1.55

### 21.2 Map Colour Overlay

Never alter the map's tile colour. Only pins and the bottom panel are custom-styled.

---

## 22. Animation Standards

| Type | Values | Usage |
|------|--------|-------|
| Spring — snappy | response 0.3s, dampingFraction 0.75 | Button presses, chip toggles |
| Spring — smooth | response 0.5s, dampingFraction 0.82 | Card transitions, panel expansion |
| Spring — bouncy | response 0.6s, dampingFraction 0.7 | Progress bar fill, badge unlock |
| easeOut | 0.12s | Button scale press |
| easeOut | 0.20–0.25s | View appearance, opacity fade |
| Linear | 1.3s repeating | Map pin pulse, hold timer countdown |

**Rule:** Never use `withAnimation` without specifying the type. Never use default `.easeInOut` — it reads as system-default, not branded.

---

## 23. Review & Rating System

- Star rating: `#FFB800`, 14pt SF Symbol `star.fill` / `star`
- Reviewer avatar: 34pt circle (§11.1)
- Reviewer initials from `reviewerName`
- Game context label: 12pt medium, `secondaryText`
- Review text: `subheadline`, `primaryText.opacity(0.85)`
- Aggregate score: 28pt bold rounded + 14pt medium count label
- Section collapsed at 2 reviews; "Show X more" Tertiary CTA

---

## 24. DUPR Chart Rules

See `DUPRHistoryCard.swift` for canonical implementation.

- Line: `ink.opacity(0.55)`, lineWidth 2, `.round` cap and join
- Active point: `emeraldAction` fill, 11pt, white stroke 1.5pt
- Y-axis: whole-number anchors only; labels 10pt regular `mutedText.opacity(0.5)`
- X-axis: date labels as `.annotation(position: .bottom)` on each `PointMark` — **never** `chartXAxis` modifier (clips last label)
- Grid lines: `softOutline.opacity(0.10)`
- Chart padding: top 40, bottom 28, leading 4, trailing 24

---

## 25. Prohibited Patterns (Master List)

The following must never be reintroduced regardless of context:

### Visual
- `neonLime` as a card fill, button background, or text colour on elements larger than 14pt
- `.blendMode(.screen)` on the app logo (transparent SVG, not needed)
- Full-width coloured section backgrounds — use card components inside `appBackground`
- "Win Rate" stat pill in `GamesPlayedCard` — no data source exists
- Arbitrary hex colours inline in view files — Brand tokens only
- Sixth or seventh unique hero treatment — extend the 6-palette system, never bypass it

### Layout
- `confirmationDialog("Club Actions", ...)` in `ClubDetailView`
- `containerRelativeFrame` / forced clipping in club navigation containers
- `fullScreenCover(isPresented: .constant(appState.isAuthenticating))` at `TabView` level
- Settings-page-style layout (vertical form rows) for game detail views
- Unbounded Supabase text fields rendered directly into UI (length caps required)
- Banner-stacking (>1 banner per section)

### Components
- Local re-implementation of a game card for a single screen
- Duplicate search fields (one canonical search pattern per screen)
- `List` with `.insetGrouped` for premium card layouts
- Manual `Save` button alongside auto-save behaviour
- Navigation links styled as Primary CTAs

### Architecture
- Client-assigned booking status — server RPC only
- Client-set `hold_expires_at` — server-authoritative
- Splitting cancellation and credit issuance into two calls
- Calling `confirmPendingBooking` on a free game
- Removing Gate 0.5 from `create-payment-intent`

---

## 26. Checklist — New Screen Audit

Before shipping any new screen, verify:

- [ ] Uses `appBackground` as page background
- [ ] All cards are Tier 1–4 — no ad-hoc `RoundedRectangle` with custom tokens
- [ ] `neonLime` appears at most once, at ≤14pt or as a decorative underline/dot
- [ ] Section headers follow §14 eyebrow + title pattern
- [ ] Buttons are Primary / Secondary / Tertiary only — no custom shapes
- [ ] Status indicators use §9 vocabulary
- [ ] Empty state follows §16 pattern
- [ ] Shadows applied only to outermost containers
- [ ] All corner radii use `.continuous` and match §4 table
- [ ] Animations use named types (§22) — no bare `withAnimation {}`
- [ ] Admin and player views of the same data use the same card component
- [ ] No inline hex colours — Brand tokens only
- [ ] Hero sections use tonal gradient + stripe + vignette (§6)
- [ ] No manual Save button if auto-save is active
- [ ] New `.swift` files added to Xcode target membership before committing

---

*End of Book A Dink Design System v1*
