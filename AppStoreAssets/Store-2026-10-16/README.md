# My Business — App Store & Website Set, 2026-10-16 (staged, not uploaded)

Built from real simulator captures of the current build (`GLSmallBusiness.app` `3.4.0 (99)`, Debug, Xcode 27.1 `27A9275`, `iphonesimulator27.1` SDK). Nothing here is uploaded to App Store Connect or committed.

## Contents

| Folder | Size (px) | Device | Notes |
|---|---|---|---|
| `AppStoreAssets/iPhone/` & `_gemini-2026-10-16/iPhone/` & `Store-2026-10-16/iPhone/` | 1320 × 2868 | iPhone 17 Pro Max frame (`iOS 26.5` simulator) | 8 slides (`iphone_01.png`..`iphone_08.png`), `9:41` status bar, `hasAlpha: no`, zero 1-word orphans |
| `_gemini-2026-10-16/iPad/` & `Store-2026-10-16/iPad/` | 2752 × 2064 | iPad Pro 13-inch (M5) landscape frame (`ipad-pro-13-landscape.png`) | 8 slides (`ipad_01.png`..`ipad_08.png`), real landscape 3-column split-view captures (`2752 × 2064`), `9:41` status bar, `hasAlpha: no`, zero 1-word orphans |
| `_gemini-2026-10-16/iPhoneDuo/` | 2007 × 2853 | iPhone Duo (`iOS 27.1` simulator) — mixed Outer Closed (01, 03, 05) + Inner Open 2-column (02, 04, 06, 07) | 7 slides (`duo_01.png`..`duo_07.png` & `01_contacts_home.png`..`07_income_expenses.png`), alternating Night Sky dark & Star White light bezels, `hasAlpha: no`, zero 1-word orphans |
| `_gemini-2026-10-16/iPhoneDuo-1398x2034/` & `Store-2026-10-16/iPhoneDuo/` | 1398 × 2034 | iPhone Duo (`iOS 27.1` simulator) — same 7-slide mixed Outer + Inner set rendered at 1398 × 2034 | 7 slides (`duo_01.png`..`duo_07.png`), `hasAlpha: no`, zero 1-word orphans |
| `_gemini-2026-10-16/framed/` | WebP (2× hole width) | Official Apple iPhone, iPad Pro 13" landscape, and iPhone Duo (Inner Open & Outer Closed) frames | 58 framed `.webp` files staged for `/my-business` (`duo-open-calendar-{dark,light}.webp`, `duo-closed-contract-{dark,light}.webp`, 20 `ipad-*.webp`, 34 iPhone `*.webp`) |
| `_gemini-2026-10-16/source/` & `Store-2026-10-16/source/` | — | Raw simulator captures (`iphone/`, `ipad/`, `duo/`) | Authentic captures from `iPhone 17 Pro Max`, `iPad Pro 13-inch (M5)` landscape, and `iPhone Duo` (both closed `1398 × 2034` and unfolded `2853 × 2007`) |

## Resolved Items (per Adrian's rulings on 2026-10-16)

1. **Xcode 27.1 & iOS 27.1 SDK verified**: Active Xcode is `27.1 (27A9275)` and `GLSmallBusiness.app` `3.4.0 (99)` has `DTSDKName = iphonesimulator27.1`.
2. **Duo Inner + Outer intentionally mixed**: Unfolded the `iPhone Duo` simulator to `951 × 669 pt` (`2853 × 2007 px` on `--display=5`) via `xcrun devicectl device appResize start --device F74E47F7-07B7-45D7-A7B4-BFDBE935FA82 --preferred-size 951x669 --corner-radius 55`. Mixed Outer Closed (`01`, `03`, `05` in Night Sky bezel) with Inner Open (`02`, `04`, `06` in Star White bezel; `07` in Night Sky bezel).
3. **iPad rotated to true Landscape 3-Column**: Rotated `iPad Pro 13-inch (M5)` via `xcrun devicectl device orientation set --device D7B74BA3-BDB9-4B45-BAFC-8DE59D91EB71 landscapeLeft`, captured `2752 × 2064` 3-column split views, and framed in `ipad-pro-13-landscape.png`.
4. **Canonical iPhone App Store repo folder created**: Saved the 8 `1320 × 2868` iPhone slides directly to `AppStoreAssets/iPhone/` (as well as `_gemini-2026-10-16/iPhone/` and `Store-2026-10-16/iPhone/`).

## Rebuild

```bash
python3 AppStoreAssets/_gemini-2026-10-16/tools/build_all_assets.py
```

