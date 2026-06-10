# Business by GL — Developer & Handoff Guide

> **🔄 KEEP THIS FILE CURRENT — this is the single source of truth for handoff.**
> Whenever any of the following changes, update the relevant section **in the same change**:
> the data model, the build/run/ship process, project conventions, accounts/identifiers, or
> project status. If you're an AI assistant (any model/session) picking this up: read this whole
> file first, and append to the **Status & Changelog** section as you complete work. Don't let it
> go stale — a smooth handoff depends on it.

---

## 1. What this is

A native iOS app for **Gold Life LLC**, a tile & flooring subcontracting business. It manages
**customers, estimates, invoices, receipts, and stats** for a one-person/small contracting shop.
Jobs typically mix **labor + materials** on the same estimate/invoice, which shapes the line-item
and tax model.

- **App Store display name:** "Business by GL" (`CFBundleDisplayName`)
- **Public developer name:** "Evolved by GL" (Gold Life LLC's DBA; matches evolvedbygl.com)
- **Internal product/bundle name:** `GLSmallBusiness` (never shown to users)

## 2. Tech stack & targets

- **SwiftUI** + **SwiftData** (+ **CloudKit** private database for sync). No Combine, no `NavigationView`.
- **iOS 26** ("Liquid Glass" era). Minimum deployment **iOS 26.5**. Ships to **iPhone + iPad only**
  (Mac and visionOS were intentionally removed from supported destinations).
- **Swift 6.2 / Xcode 26**, with **default actor isolation = MainActor** (approachable concurrency).
- Bundle ID: `com.evolvedbygl.GLSmallBusiness`

## 3. Apple accounts & identifiers

- **Apple Developer Program:** organization account, **Gold Life LLC**, **Team ID `T77JR9H9SB`**.
  Account Holder: **evolvedbygl@icloud.com**. (The individual→organization migration is **complete**.)
- App Store Connect, the CloudKit Console, and the developer portal all live under this account.
- The Mac used for development is signed into iCloud as **evolvedbygl@icloud.com** (good for CloudKit).
- **Secrets** (CloudKit management token, App Store Connect API key + `.p8`) live in **`secrets/`**,
  which is **git-ignored** — never commit them. See §9.

## 4. Repository layout

```
GLSmallBusiness.xcodeproj      # uses PBXFileSystemSynchronizedRootGroup — new .swift files in the
GLSmallBusiness/               #   folder are auto-included; NO project.pbxproj edits needed to add files
  Models/                      # SwiftData @Model types + GLSchema.swift (versioning) — see §6
  Screens/                     # one file per screen (Customer/Estimate/Invoice/Receipt forms+details, Settings, Menu…)
  UIComponents/                # shared views (PrimaryBackground, MenuButtonLabel, PDFs, ImageCropView, GLFormBackground…)
  Tokens/                      # design tokens (GLColor, fonts)
  Resources/Fonts/             # Italianno (titles), Inter
  Assets.xcassets/             # AppIcon (light/dark/tinted), glLogo (GL monogram SVG)
  Info.plist                   # merged with generated keys (GENERATE_INFOPLIST_FILE = YES)
secrets/                       # git-ignored — tokens/keys (see §9)
README.md                      # this file
TODO.md                        # legacy pre-ship checklist (superseded by §10 here)
```

## 5. Build, run, install (from the CLI)

**Critical:** `xcode-select` points at CommandLineTools, so `xcodebuild` fails by default. Full Xcode
is at `/Applications/Xcode.app`. **Prefix every build command with:**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

- **Scheme:** `GLSmallBusiness` · **Configs:** Debug / Release
- **List destinations / devices:** `xcodebuild -showdestinations -scheme GLSmallBusiness -project GLSmallBusiness.xcodeproj`
  · `xcrun devicectl list devices` · `xcrun simctl list devices | grep Booted`
- **Build for a physical device:**
  ```bash
  xcodebuild -project GLSmallBusiness.xcodeproj -scheme GLSmallBusiness -configuration Debug \
    -destination 'platform=iOS,id=<DEVICE_UDID>' -derivedDataPath /tmp/gl-devbuild -allowProvisioningUpdates build
  ```
- **Install + launch on device:**
  ```bash
  xcrun devicectl device install app --device <UDID> /tmp/gl-devbuild/Build/Products/Debug-iphoneos/GLSmallBusiness.app
  xcrun devicectl device process launch --device <UDID> com.evolvedbygl.GLSmallBusiness
  ```
  - The **device must be unlocked** to install/launch. A `--console` launch is killed (signal 9) when
    the phone locks; launch **detached** (no `--console`) so the app survives, and keep the phone awake.
- Paired devices seen this project: AG-iPhone `00008140-000078E0229B001C`, iPhone `00008140-0005053E3E0A801C`,
  iPad `00008132-0018182A1445001C`. (Re-query — these can change.)
- **Simulator:** the same `Debug-iphonesimulator/*.app` runs on iPhone **and** iPad sims.
  ⚠️ Plain `simctl install` over an already-installed app does **not** reliably replace the binary —
  always `terminate` + `uninstall` before `install`, or you'll screenshot a **stale** build and think a
  change "did nothing." Screenshot via `xcrun simctl io <UDID> screenshot /tmp/x.png`.
- **CloudKit environment is tied to signing:** Debug/dev-signed builds use CloudKit **Development**;
  Release/archive builds use **Production**.

## 6. ⚠️ SwiftData model versioning & migrations (READ BEFORE CHANGING ANY `@Model`)

This is the most important section. The goal: **users never lose data or have to reinstall on an update.**

- The app uses a **versioned schema + migration plan** in `Models/GLSchema.swift`:
  `GLSchemaV1` (a frozen snapshot of the model shape) and `GLMigrationPlan`. The container is built with
  `ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, …)`.
- **Why dev crashes/wipes happen (dev-only):** changing a model in place without bumping the version
  leaves the on-disk store's shape mismatched → crash; the dev fix is "delete the app" (throwaway data).
  Also, **CloudKit requires every stored property to have a default or be optional** — a property with no
  default (`var foo: String`) makes the CloudKit store fail to init → crash on launch.
- **The rules (also documented in GLSchema.swift) — follow them every release after launch:**
  1. **ONLY ADD.** Add new properties (with a default or optional) or whole new `@Model` types. **Never**
     rename, remove, retype, or make-required an existing stored property in place. To "rename": add the
     new field, copy data in code, keep the old one (drop it only in a far-future cleanup).
  2. New relationships must be **optional** (incl. to-many: `[Thing]?`, never `[Thing] = []`), with inverses.
  3. For a model change in a release **after** launch: snapshot the new shape as `GLSchemaV2` (then V3…),
     add it to `GLMigrationPlan.schemas`, add a `.lightweight(fromVersion:toVersion:)` stage, and point the
     `GLCurrentSchema` typealias at the newest version. Lightweight = automatic, zero data loss.
  4. CloudKit only supports **lightweight/additive** migrations (no custom-migration hook), so the
     additive discipline above is mandatory, not optional.
- `Codable` value types stored as `@Model` properties (e.g. `Address`) must be marked **`nonisolated`**
  (MainActor isolation default otherwise trips the `@Model` macro).
- **After ANY model change, before shipping:** re-generate the CloudKit **Development** schema (run the app
  and save a record of each changed type so the new fields mirror up), **then deploy to Production** (§7).
  Skipping this = sync silently breaks for real users.

## 7. CloudKit schema deploy

- **Container:** `iCloud.com.evolvedbygl.GLSmallBusiness`. Capabilities: iCloud→CloudKit, a container, and
  Background Modes → Remote notifications (set in Xcode Signing & Capabilities; provisions on the portal).
- **V1 record types (deployed to Production):** `CD_BusinessProfile`, `CD_Customer`, `CD_Estimate`,
  `CD_EstimateGroup`, `CD_EstimateLineItem`, `CD_Invoice`, `CD_InvoiceGroup`, `CD_InvoiceLineItem`,
  `CD_InvoicePayment`, `CD_Receipt`. (SwiftData prefixes its mirrored types `CD_`.)
- **Deploy via Console** (icloud.developer.apple.com): CloudKit Database → select the container → set
  environment to **Development** → in the left sidebar (near the bottom) **"Deploy Schema Changes…"** →
  review the diff (all changes should be additive "Create"; "Modify _world/_icloud/_creator role" is the
  normal default role update, not a deletion) → **Deploy to Production**. Production schema is permanent &
  additive-only — deploy only when the model is final for that release.
- **Deploy via terminal (`cktool`)** is possible but needs a **CloudKit *Management* Token** (Console →
  Tokens & Keys → *CloudKit Management Tokens*). ⚠️ An "API Token"/"Server-to-Server Key" is the WRONG type
  and fails with "Session has expired or is invalid." With the right token: `xcrun cktool export-schema …`
  to verify, `import-schema … --environment production` to deploy.
- **Safety net:** because data syncs to each user's private iCloud, it survives reinstalls (re-downloads).

## 8. Architecture & iOS-26 conventions

- **Backgrounds:** screens use `.containerBackground(for: .navigation) { PrimaryBackground() }`; forms/sheets
  use `.glFormBackground()`. Do **not** wrap a root `NavigationStack` in `ZStack { background; NavigationStack }`
  — in iOS 26 that breaks the nav title/toolbar and hides the background.
- **Company-logo theming:** `PrimaryBackground` and `MenuButtonLabel` show the uploaded company logo when one
  exists (else the GL monogram), gated by a Settings toggle (`AppBranding.useCompanyLogoKey`, default on).
  `BusinessProfile.logo(for:)` falls back light↔dark either way. PDFs/emails always use the logo regardless.
- **Estimates/Invoices** snapshot the customer's details at creation and are immutable to later Customer edits
  (deliberate). Money math lives in one place: the `EstimateTotals` value type (shared by model + live form
  preview). Each estimate/invoice has a **Service Address** (job site) separate from the customer's billing
  address; it carries over when an estimate is converted to an invoice.
- **PDFs:** `EstimatePDFDocument` / `InvoicePDFDocument` rendered via `ImageRenderer` → `CGContext` (single
  fit-to-content page). Sharing uses **`ShareLink`** (NOT `UIActivityViewController` — presents blank here).
  Email/Text use `MFMail/MFMessageComposeViewController`, which only work on a **real device** (sim returns
  `canSendMail()/canSendText()` false), so those menu items are hidden on the simulator.
- **Forms:** `.glFormBackground()` also installs keyboard dismissal (scroll-to-dismiss + tap-outside). Tap-to-
  dismiss is a **non-cancelling window gesture** (`KeyboardDismissInstaller`), NOT a SwiftUI
  `simultaneousGesture(TapGesture())` — the latter steals taps from menu Pickers (they'd need a long-press).
- **Photo crop:** customer profile photos go through `ImageCropView` (pinch/drag in a circle) before saving.

## 9. Secrets

- `secrets/tokens.env` (git-ignored via `secrets/` + `*.p8` in `.gitignore`) holds local credentials.
  Paste values after the `=`, never into chat, never commit. Currently holds a CloudKit management token
  (one was created mid-session that was the wrong type — see §7) and reserved slots for the App Store Connect
  API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, and the downloaded `AuthKey_XXXX.p8` in the same folder).

## 10. Shipping checklist (to the App Store)

1. **Re-deploy the CloudKit schema to Production** if any `@Model` changed since the last deploy (§7).
2. **Archive** (Release): `xcodebuild archive -scheme GLSmallBusiness -configuration Release
   -destination 'generic/platform=iOS' -archivePath /tmp/GLSmallBusiness.xcarchive -allowProvisioningUpdates`.
   The archive is dev-signed; export/distribution re-signs it with the Apple Distribution cert.
3. **Create the app record** in App Store Connect (bundle ID `com.evolvedbygl.GLSmallBusiness`).
4. **Upload the build** — Xcode Organizer (Distribute → App Store Connect → Upload), or `xcrun altool` /
   `xcodebuild -exportArchive` with an **App Store Connect API key** (Users and Access → Integrations).
5. **Listing:** screenshots (iPhone 6.9" + iPad 13" required), description, keywords, support URL
   (evolvedbygl.com), privacy-policy URL, age rating, the App Privacy questionnaire, export compliance
   (standard encryption → likely exempt; consider `ITSAppUsesNonExemptEncryption = NO` in Info.plist).
6. **Submit for review.**

## 11. Status & changelog

**Stage:** pre-launch, finalizing **V1** (nothing shipped yet, so all model changes so far are part of V1 —
no migration needed until the first post-launch change).

- **Done (this development push):** Service Address on estimates + invoices; customer photo crop; logo
  light↔dark fallback fix + company-logo screen background + Settings "Use company logo" toggle; `job` added
  to the unit selector; estimate wording "Deposit due" → "Required Deposit"; per-line-item **Remove** buttons;
  keyboard dismiss on scroll/tap-outside (+ Picker-tap conflict fixed); app display name set to "Business by
  GL"; "Developer Feedback" mailto button in the menu (→ support@evolvedbygl.com). CloudKit V1 (10 types) was
  deployed to Production.
- **Done toward launch:** fresh **Release archive** built at `/tmp/GLSmallBusiness.xcarchive` (v1.0 (1),
  iPhoneOS only, "Business by GL" — ready to upload). Latest Debug build **installed on AG-iPhone** for
  testing. **App Store listing + privacy policy drafted** (`AppStore-Listing-DRAFT.md`,
  `PrivacyPolicy-DRAFT.md`).
- **Pending before launch (needs the owner):**
  - **Test** the batch on the device (the keyboard/Picker fix especially).
  - **Re-deploy CloudKit** — `serviceAddress` was added to `Estimate`/`Invoice` after the last deploy, so
    `CD_Estimate`/`CD_Invoice` need the new field mirrored to Dev (run app + save an estimate with a service
    address) then deployed to Production (§7).
  - **Commit the feature batch** (docs are committed; the feature code is not yet).
  - **Host the privacy policy** at a public URL; finalize listing decisions (price, audience, keywords).
  - **App Store Connect:** create the app record, upload the archive (needs an ASC API key, or Xcode
    Organizer), add screenshots (iPhone 6.9" + iPad 13") + metadata, and submit for review.

## 12. Working conventions / preferences

- **Git:** commit & push **directly to `main`**. Do **not** open PRs unless explicitly asked. End commit
  messages with a `Co-Authored-By:` trailer.
- **Code style:** prefer **Apple-recommended, idiomatic first-class SwiftUI APIs** over hacks; **verify
  changes empirically** (build, and run on a real device for UI/gesture/keyboard/CloudKit behavior).
- **Scope discipline:** do exactly the change requested — don't "improve" surrounding presentation/behavior
  unless asked (e.g. when swapping which image shows, keep the existing display treatment identical).
- **Guidance:** drive decisions with a clear recommended default; proactively flag industry/business norms.
  The owner is a capable non-CS small-business owner — explain technical trade-offs plainly when asked.
</content>
