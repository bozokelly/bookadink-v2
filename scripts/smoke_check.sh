#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/BookadinkV2"
ASSETS_DIR="$APP_DIR/Assets.xcassets"
PROJECT_PATH="$ROOT_DIR/BookadinkV2.xcodeproj"
SCHEME="BookadinkV2"

echo "[smoke] Running BookingAppV2 smoke checks..."

echo "[smoke] Checking legacy club-style references..."
if rg -n "bookadink-preset|Club Style|ClubArtworkPreset|isLegacyClubStyleURL" "$APP_DIR" >/dev/null; then
  echo "[smoke][FAIL] Legacy club-style references found."
  rg -n "bookadink-preset|Club Style|ClubArtworkPreset|isLegacyClubStyleURL" "$APP_DIR"
  exit 1
fi
echo "[smoke][PASS] No legacy club-style references."

echo "[smoke] Checking avatar image set count..."
avatar_count="$(find "$ASSETS_DIR" -maxdepth 1 -type d -name "avatar_*.imageset" | wc -l | tr -d ' ')"
if [[ "$avatar_count" != "9" ]]; then
  echo "[smoke][FAIL] Expected 9 avatar image sets, found $avatar_count."
  exit 1
fi
echo "[smoke][PASS] Found 9 avatar image sets."

echo "[smoke] Checking required club avatar assets..."
required_assets=(
  "avatar_cool_dink"
  "avatar_rally_runner"
  "avatar_court_pin"
  "avatar_pickle_wink"
  "avatar_crossed_paddles"
  "avatar_neon_rally"
  "avatar_crown_court"
  "avatar_hero_duo"
  "avatar_power_dink"
)

for asset in "${required_assets[@]}"; do
  asset_file="$ASSETS_DIR/${asset}.imageset/${asset}.png"
  if [[ ! -f "$asset_file" ]]; then
    echo "[smoke][FAIL] Missing asset file: $asset_file"
    exit 1
  fi
done
echo "[smoke][PASS] All required avatar assets exist."

echo "[smoke] Optional build check..."
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  if xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/BookadinkV2-DerivedData build >/tmp/bookadinkv2-smoke-build.log 2>&1; then
    echo "[smoke][PASS] xcodebuild completed."
  else
    echo "[smoke][FAIL] xcodebuild failed. See /tmp/bookadinkv2-smoke-build.log"
    exit 1
  fi
else
  echo "[smoke][SKIP] xcodebuild unavailable in current environment."
fi

echo "[smoke] All checks passed."
