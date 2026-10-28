#!/usr/bin/env bash
#
# regenerate-screenshots.sh — one command that reshoots EVERY marketing website screenshot.
#
# Run this on every version bump. It captures the full matrix (iPhone + iPad, light + dark, plain +
# white-label brand) from the current build via the MarketingShotsUITests harness, renames each shot
# to the website's filename convention, copies them into the website repo, then VERIFIES that the set
# it produced exactly matches the set the website actually references — failing loudly if any file is
# missing, the wrong size, or orphaned. That closes the loop so nothing is ever silently overlooked.
#
# Usage:
#   Scripts/regenerate-screenshots.sh            # full matrix → website public/screenshots
#   Scripts/regenerate-screenshots.sh --smoke    # one tiny variant (build + extract sanity check)
#   Scripts/regenerate-screenshots.sh --no-copy  # produce into staging, don't touch the website repo
#
# Requires: Xcode (not just CLT). Uses DEVELOPER_DIR so it works on this machine (see the repo memory).
#
set -euo pipefail

# ---- Config ---------------------------------------------------------------------------------------
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_REPO="${WEB_REPO:-$(dirname "$APP_REPO")/softwarebygl-website}"
WEB_SHOTS="$WEB_REPO/public/screenshots"
PROJECT="$APP_REPO/GLSmallBusiness.xcodeproj"
SCHEME="GLSmallBusiness"
BUNDLE_ID="com.evolvedbygl.GLSmallBusiness"
IPHONE_NAME="iPhone 17 Pro Max"      # native screenshot = 1320 x 2868 (website iPhone target)
IPAD_NAME="iPad Pro 13-inch (M5)"    # native landscape  = 2752 x 2064 (website iPad target)
IPHONE_DIM="1320x2868"
IPAD_DIM="2752x2064"

WORK="$(mktemp -d /tmp/mb-shots.XXXXXX)"
DERIVED="${DERIVED:-/tmp/mb-shots-derived}"
STAGE="$WORK/stage"; mkdir -p "$STAGE"
SMOKE=0; COPY=1; IPADONLY=0
for a in "$@"; do case "$a" in --smoke) SMOKE=1 ;; --no-copy) COPY=0 ;; --ipad-only) IPADONLY=1 ;; esac; done

log()  { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

udid_for() { xcrun simctl list devices available | grep -F "$1 (" | grep -oE '[0-9A-F-]{36}' | head -1; }
IPHONE_UDID="$(udid_for "$IPHONE_NAME")"; [ -n "$IPHONE_UDID" ] || die "No available simulator: $IPHONE_NAME"
IPAD_UDID="$(udid_for "$IPAD_NAME")";     [ -n "$IPAD_UDID" ]   || die "No available simulator: $IPAD_NAME"

# ---- Variant table: device|dark|brand|screens ----------------------------------------------------
# The screen list per variant; output base is derived (ipad-/brand- prefix, stripe→get-paid).
# stripe MUST be first in any list that contains it (seeds the connected Stripe state).
IPHONE_PLAIN="stripe,company,receipts,customers,1099,employees,stats,estimate,subcontractors,invoice,calendar"
IPHONE_BRAND="company,customers,estimate,invoice,receipts"
IPAD_PLAIN="stripe,calendar,customers,employees,estimate,invoice"
IPAD_BRAND="company,customers"

if [ "$SMOKE" = 1 ]; then
  VARIANTS=("iphone|0|0|stripe,calendar")
elif [ "$IPADONLY" = 1 ]; then
  # Re-shoot only the iPad half (e.g. after an orientation-handling fix). Completeness check is skipped.
  VARIANTS=(
    "ipad|0|0|$IPAD_PLAIN"      "ipad|1|0|$IPAD_PLAIN"
    "ipad|0|1|$IPAD_BRAND"      "ipad|1|1|$IPAD_BRAND"
  )
else
  VARIANTS=(
    "iphone|0|0|$IPHONE_PLAIN"  "iphone|1|0|$IPHONE_PLAIN"
    "iphone|0|1|$IPHONE_BRAND"  "iphone|1|1|$IPHONE_BRAND"
    "ipad|0|0|$IPAD_PLAIN"      "ipad|1|0|$IPAD_PLAIN"
    "ipad|0|1|$IPAD_BRAND"      "ipad|1|1|$IPAD_BRAND"
  )
fi

# ---- Build once -----------------------------------------------------------------------------------
log "Building for testing (Debug, iOS Simulator)…"
xcodebuild build-for-testing \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED" -quiet \
  || die "build-for-testing failed"
ok "Built."

# ---- Capture each variant -------------------------------------------------------------------------
out_base() { # screen device brand -> base name (no -light/-dark, no .png)
  local screen="$1" device="$2" brand="$3" prefix="" sb="$1"
  [ "$device" = ipad ]  && prefix="ipad-"
  [ "$brand"  = 1 ]     && prefix="${prefix}brand-"
  [ "$screen" = stripe ] && sb="get-paid"
  printf '%s%s' "$prefix" "$sb"
}

run_variant() {
  local device="$1" dark="$2" brand="$3" screens="$4"
  local udid name dim landscape suffix
  if [ "$device" = ipad ]; then udid="$IPAD_UDID"; name="$IPAD_NAME"; dim="$IPAD_DIM"; landscape=1
  else                          udid="$IPHONE_UDID"; name="$IPHONE_NAME"; dim="$IPHONE_DIM"; landscape=0; fi
  [ "$dark" = 1 ] && suffix="dark" || suffix="light"

  log "Variant: $device $suffix $([ "$brand" = 1 ] && echo brand || echo plain) → [$screens]"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true   # force a fresh demo seed with this variant's flags

  local rb="$WORK/result-$device-$suffix-$brand.xcresult"; rm -rf "$rb"
  
  local tr=$(ls "$DERIVED"/Build/Products/*.xctestrun | head -n 1)
  cp "$tr" "$DERIVED/Build/Products/run.xctestrun"
  local mtr="$DERIVED/Build/Products/run.xctestrun"
  
  # Inject variables into GLSmallBusinessUITests target (index 1)
  for var in MB_MARKETING:1 MB_SCREENS:"$screens" MB_BRAND:"$brand" MB_DARK:"$dark" MB_LANDSCAPE:"$landscape"; do
    key="${var%%:*}"
    val="${var#*:}"
    plutil -insert "TestConfigurations.0.TestTargets.1.TestingEnvironmentVariables.$key" -string "$val" "$mtr" || \
    plutil -replace "TestConfigurations.0.TestTargets.1.TestingEnvironmentVariables.$key" -string "$val" "$mtr"
  done

  # Ensure MarketingShotsUITests isn't skipped by the test plan's SkipTestIdentifiers
  python3 -c "
import plistlib, sys
p = '$mtr'
with open(p, 'rb') as f:
    d = plistlib.load(f)
for cfg in d.get('TestConfigurations', []):
    for tgt in cfg.get('TestTargets', []):
        if 'SkipTestIdentifiers' in tgt:
            tgt.pop('SkipTestIdentifiers', None)
with open(p, 'wb') as f:
    plistlib.dump(d, f)
"

  xcodebuild test-without-building \
    -xctestrun "$mtr" \
    -destination "id=$udid" \
    -only-testing:GLSmallBusinessUITests/MarketingShotsUITests/testCapture \
    -derivedDataPath "$DERIVED" -resultBundlePath "$rb" -quiet \
    || die "test run failed for $device/$suffix/brand=$brand"

  # Extract attachments + manifest, then rename each shot-<screen> to the website filename.
  local adir="$WORK/att-$device-$suffix-$brand"; rm -rf "$adir"
  xcrun xcresulttool export attachments --path "$rb" --output-path "$adir" >/dev/null
  [ -f "$adir/manifest.json" ] || die "no manifest.json in $adir"

  python3 - "$adir" "$STAGE" "$device" "$brand" "$suffix" <<'PY'
import json, os, re, sys
from PIL import Image, ImageOps
adir, stage, device, brand, suffix = sys.argv[1:6]
manifest = json.load(open(os.path.join(adir, "manifest.json")))
def base(screen):
    p = ("ipad-" if device == "ipad" else "") + ("brand-" if brand == "1" else "")
    return p + ("get-paid" if screen == "stripe" else screen)
# xcresulttool rewrites the attachment name "shot-<screen>" to "shot-<screen>_<idx>_<UUID>.png";
# recover <screen> by stripping the "shot-" prefix and the trailing "_<idx>_<UUID>.png".
# iPad landscape shots arrive as a portrait framebuffer + an EXIF orientation tag; bake the tag into
# pixels with exif_transpose (and strip it) so the PNG renders upright in EVERY browser — a raw tag is
# ignored by browsers that don't honor PNG EXIF orientation and would render the shot sideways.
n = 0
for test in manifest:
    for att in test.get("attachments", []):
        nm = att.get("suggestedHumanReadableName", "")
        fn = att.get("exportedFileName")
        if not (nm.startswith("shot-") and fn):
            continue
        screen = re.sub(r'_\d+_[0-9A-Fa-f-]{36}\.png$', '', nm[len("shot-"):])
        out = f"{base(screen)}-{suffix}.png"
        img = ImageOps.exif_transpose(Image.open(os.path.join(adir, fn))).convert("RGB")
        img.save(os.path.join(stage, out))
        print("  ", out); n += 1
if n == 0:
    sys.exit("no shot-* attachments found in manifest.json")
PY

  # Verify ONLY the files this variant produced (orientation is already baked upright in the Python
  # step above, so iPad shots come out 2752x2064 landscape with no orientation tag).
  local s b f d
  IFS=',' read -ra _scr <<<"$screens"
  for s in "${_scr[@]}"; do
    b="$(out_base "$s" "$device" "$brand")"
    f="$STAGE/${b}-${suffix}.png"
    [ -f "$f" ] || die "variant $device/$suffix/brand=$brand did not produce $(basename "$f")"
    d="$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
    [ "$d" = "$dim" ] || die "WRONG SIZE $(basename "$f"): got $d, expected $dim (orientation/device mismatch?)"
  done
}

for v in "${VARIANTS[@]}"; do IFS='|' read -r d dk br sc <<<"$v"; run_variant "$d" "$dk" "$br" "$sc"; done
ok "Captured $(ls "$STAGE" | wc -l | tr -d ' ') files into staging."

if [ "$SMOKE" = 1 ]; then ok "Smoke test OK — staging at $STAGE"; ls -1 "$STAGE"; exit 0; fi

if [ "$IPADONLY" = 1 ]; then
  # Only the iPad half was shot — copy just those, skip the full referenced-set check.
  if [ "$COPY" = 1 ]; then
    log "Copying iPad shots into $WEB_SHOTS …"
    for f in "$STAGE"/ipad-*.png; do cp "$f" "$WEB_SHOTS/$(basename "$f")"; done
    ok "iPad screenshots updated ($(ls "$STAGE"/ipad-*.png | wc -l | tr -d ' ') files)."
  else
    ok "Staged only (--no-copy). iPad files in: $STAGE"
  fi
  echo "Work dir: $WORK"; exit 0
fi

# ---- Completeness check vs the website's ACTUAL references ----------------------------------------
log "Verifying produced set == website-referenced set…"
REF="$WORK/referenced.txt"
# Scoped to app/my-business: the site also hosts other Gold Life app pages whose screenshots come
# from their own pipelines — scanning the whole app/ made their shots false "missing".
# `|| true` on each: with pipefail, a pattern with ZERO matches (raw /screenshots/
# paths no longer appear under my-business) would silently kill the whole script.
{ grep -rhoE '(heroShot|shot|base)"?[[:space:]]*:[[:space:]]*"[^"]+"' "$WEB_REPO/app/my-business" | sed -E 's/.*"([^"]+)"$/\1/' || true
  grep -rhoE '/screenshots/[a-z0-9-]+' "$WEB_REPO/app/my-business" | sed -E 's#/screenshots/##; s/-(light|dark)$//' || true
} | grep -vE '^(true|false)$' | sort -u > "$REF"

missing=0
while read -r b; do
  for s in light dark; do
    [ -f "$STAGE/$b-$s.png" ] || { printf '  MISSING: %s-%s.png\n' "$b" "$s"; missing=1; }
  done
done < "$REF"
[ "$missing" = 0 ] || die "The build didn't produce every referenced screenshot — update the VARIANTS table."

# Orphans the run produced that the site never uses (informational, not fatal).
comm -23 <(ls "$STAGE" | sed -E 's/-(light|dark)\.png$//' | sort -u) "$REF" | sed 's/^/  orphan (not referenced): /' || true
ok "All $(($(wc -l < "$REF") * 2)) referenced files produced at correct dimensions."

# ---- Copy into the website repo -------------------------------------------------------------------
if [ "$COPY" = 1 ]; then
  log "Copying into $WEB_SHOTS …"
  while read -r b; do for s in light dark; do cp "$STAGE/$b-$s.png" "$WEB_SHOTS/$b-$s.png"; done; done < "$REF"
  ok "Website screenshots updated. Review the diff in $WEB_REPO, then commit (do NOT merge to main until launch)."
else
  ok "Staged only (--no-copy). Files in: $STAGE"
fi
echo "Work dir: $WORK"
