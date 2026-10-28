# Marketing screenshot regeneration

One command reshoots **every** screenshot the marketing website uses — iPhone + iPad, light + dark,
plain + white-label brand — so on a version bump nothing is ever left stale or overlooked.

```sh
Scripts/regenerate-screenshots.sh          # full matrix → copies into the website repo
Scripts/regenerate-screenshots.sh --no-copy  # stage + verify only; review before copying
Scripts/regenerate-screenshots.sh --smoke    # build + one 2-screen variant (sanity check)
```

Run it, review the diff in the website repo, commit. Do **not** merge the website to `main` until the
matching app version is approved (the site is parked on `site-v2`).

## What it does

1. `build-for-testing` once (Debug, iOS Simulator).
2. Runs the `MarketingShotsUITests.testCapture` harness across **8 variants** (below), each capturing
   only the screens that variant needs.
3. Extracts the screenshots from each `.xcresult` (`xcresulttool export attachments`) and renames them
   to the website's filename convention.
4. **Verifies** the produced set is exactly the set the website references (fails on any missing file,
   wrong dimension, or — informationally — orphan), then copies into `…/public/screenshots/`.

## The 8 variants (46 files)

| Device | Appearance | Brand | Screens captured |
|---|---|---|---|
| iPhone | light + dark | plain | stripe, company, receipts, customers, 1099, employees, stats, estimate, subcontractors, invoice, calendar |
| iPhone | light + dark | brand | company, customers, estimate, invoice, receipts |
| iPad   | light + dark | plain | calendar, customers, employees, estimate, invoice |
| iPad   | light + dark | brand | company, customers |

`stripe` is captured first in any list that contains it, so the idempotent demo seed turns on the
connected Stripe state before other screens render.

## Naming rule (output base)

`base = ("ipad-" if iPad) + ("brand-" if brand) + (screen, but "stripe" → "get-paid")`, then
`-light.png` / `-dark.png`. Examples: `stripe`(iPhone, plain, dark) → `get-paid-dark.png`;
`company`(iPad, brand, light) → `ipad-brand-company-light.png`.

## How it hangs together (the moving parts)

- **App launch flags** (DEBUG-only, in `DemoMode` / `GLSmallBusinessApp`): `-demoMode`, `-demoScreen <name>`,
  `-demoBrand` (white-label sample logo), `-demoDark` (forces dark appearance — the enabler that makes
  dark-mode capture automatic instead of a manual Simulator toggle).
- **Harness** (`GLSmallBusinessUITests/MarketingShotsUITests.swift`): reads `MB_SCREENS / MB_BRAND /
  MB_DARK / MB_LANDSCAPE` from its environment and captures accordingly. The driver passes these as
  `TEST_RUNNER_MB_*` (xcodebuild forwards `TEST_RUNNER_`-prefixed vars to the test runner, prefix stripped).
- **Fresh seed per variant**: the driver `simctl uninstall`s the app before each variant so the demo
  seed re-runs with that variant's flags (needed because the seed is idempotent and brand logo is set
  during seeding).
- **Simulators**: `iPhone 17 Pro Max` (native 1320×2868) and `iPad Pro 13-inch (M5)` (native landscape
  2752×2064) — the exact dimensions the website expects. If Apple ships new default sims, update the
  names at the top of the script; the dimension check will fail loudly if a sim's output size drifts.

## Adding a new screen to the site

1. Add the `-demoScreen` case in the app if it's a new destination.
2. Add the screen to the right variant list(s) in the script's `VARIANTS` table.
3. Re-run. The completeness check fails until every base the website references is produced — that's
   the guarantee that a newly-referenced screenshot can't be silently missed.

## Troubleshooting

- **Wrong size / orientation**: the per-variant dimension check aborts the run; usually means the iPad
  variant didn't rotate or a sim model changed. Confirm the sim names/dimensions at the top.
- **Blank / half-rendered screen**: bump the `sleep(6)` settle in the harness (PDF-heavy screens like
  `1099` need the most time).
- **`no shot-* attachments`**: the harness didn't see `MB_SCREENS` (env not forwarded) — confirm the
  driver sets `TEST_RUNNER_MB_*` and the test id is `…/MarketingShotsUITests/testCapture`.
