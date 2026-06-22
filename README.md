# GL Business — Developer & Handoff Guide

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

- **App Store display name:** "GL Business" (`CFBundleDisplayName`)
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
  `GLSchemaV1` and `GLMigrationPlan`. The container is built with
  `ModelContainer(for: schema, migrationPlan: GLMigrationPlan.self, …)`.
- ⚠️ **`GLSchemaV1` currently references the LIVE `@Model` types, not frozen copies.** That is fine while
  V1 is the only version (pre-launch we keep folding additive changes into V1 — see rule 3 / §11). But it is
  a **trap for the first post-launch migration:** if you add `GLSchemaV2` while V1 still points at the live
  types, V1 and V2 resolve to the *same current shape* → identical checksums → the app crashes at launch with
  **"Duplicate version checksums detected."** (Seen for real when a premature V2 was added.) Before introducing
  V2, you MUST **freeze V1** — copy the launch-shape model definitions into a V1-only namespace so `GLSchemaV1`
  describes the *old* shape and `GLSchemaV2` the *new* one.
- **Why dev crashes/wipes happen (dev-only):** changing a model in place without bumping the version
  leaves the on-disk store's shape mismatched → crash; the dev fix is "delete the app" (throwaway data).
  Also, **CloudKit requires every stored property to have a default or be optional** — a property with no
  default (`var foo: String`) makes the CloudKit store fail to init → crash on launch.
- **The rules (also documented in GLSchema.swift) — follow them every release after launch:**
  1. **ONLY ADD.** Add new properties (with a default or optional) or whole new `@Model` types. **Never**
     rename, remove, retype, or make-required an existing stored property in place. To "rename": add the
     new field, copy data in code, keep the old one (drop it only in a far-future cleanup).
  2. New relationships must be **optional** (incl. to-many: `[Thing]?`, never `[Thing] = []`), with inverses.
  3. For a model change in a release **after** launch: first **freeze the current `GLSchemaV1`** (replace its
     live-type references with copied snapshot definitions of the launch shape — see the ⚠️ above), then
     snapshot the new shape as `GLSchemaV2` (then V3…), add it to `GLMigrationPlan.schemas`, add a
     `.lightweight(fromVersion:toVersion:)` stage, and point the `GLCurrentSchema` typealias at the newest
     version. Lightweight = automatic, zero data loss, **no reinstall for users.**
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
- **Sheet dismissal controls (pick by intent, not habit):** **(a)** *Presentational* sheets — you only viewed /
  generated / shared, nothing to commit — use an **X close** in `.topBarLeading` via the iOS-26 role:
  `Button(role: .close) { dismiss() }` (e.g. Menu, Generate a W-9, Year-End Tax Report). **(b)** *Editing* sheets —
  you entered/changed data — use **Cancel** (`.cancellationAction`) + **Save** (`.confirmationAction`) (e.g. the
  Company/Customer/Estimate/Invoice/Receipt forms, Signature editor, Record Payment, Set Amount Due). **(c)**
  **Edit↔Done** toggle stays the list edit-mode pattern (Customers/Estimates/Invoices/Receipts). Avoid a bare
  "Done" to dismiss a presentational sheet — "Done" implies you finished an action; if there's nothing to
  finish, it's a close.

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

- **Done — NOT yet committed (built + verified on iPhone & iPad simulators):** **Calendar tab.** The 4th
  top-level tab: scheduling for the business. A **"Next available date"** banner + **"View gaps"** (open
  workday stretches before booked work, looking 90 days ahead), a **month grid** with booked days marked,
  and an **Upcoming** agenda. You schedule **only from an accepted estimate or an invoice** (never free-form
  — the GL way: book from the accepted estimate if you schedule on acceptance, or from the invoice if you
  wait on a deposit). A **Schedule** action sits on accepted-estimate + invoice detail menus, and a + on the
  calendar picks a source → `ScheduleJobSheet` (start date + workday length). **Settings → Scheduling**: a
  **customizable workdays** chip selector (default Mon–Fri) + a **"Book one job at a time"** toggle (on by
  default; an overlapping booking just asks, never blocks). The next-available / gaps math runs over the
  chosen workdays. New `ScheduledJob` model (+ `scheduledJobs` inverse on `Estimate` and `Invoice`; additive,
  still **V1** — deploy to CloudKit Production, see TODO). New files: `Models/ScheduledJob.swift` (model +
  `SchedulingEngine`), `Screens/CalendarScreen.swift`, `Screens/ScheduleJobSheet.swift`. DEBUG: demo seeds 2
  bookings with a gap; `-demoScreen calendar` deep-links the tab. Tests: `SchedulingTests` cover workdays /
  occupied-days / next-available / gaps (engine 100% of reachable lines). 236 tests pass. *iPad shows the
  calendar in the content column (functional; a wider iPad layout is a possible later polish).*
- **Done — NOT yet committed (built + render-verified on simulator):** **Real 1099-NEC generator
  (tax-document layer, part 2 — completes it).** Generates the official **IRS Form 1099-NEC (Rev. December
  2026), Copy B "For Recipient"** for a subcontractor: stamps the payer (this business), the recipient (the
  sub), both TINs, the calendar year, and **Box 1a Nonemployee compensation** onto the bundled official
  template at the form's real field coordinates, then flattens — the exact technique as `W9FormFiller`.
  Render-verified field-by-field on the sim (every value lands in its cell, no label overlap). A **Generate
  1099-NEC** button on the sub's W-9 card opens a preview + Share sheet (`Form1099NECSheet`) that routes you
  to add any missing payer/recipient TIN first. We furnish **Copy B** (the recipient's legitimate copy);
  filing **Copy A** with the IRS stays an e-file / scannable-form step the accountant CSV covers. New files:
  `UIComponents/Form1099NECFiller.swift`, `Resources/Form1099NEC.pdf` (official IRS form, public domain —
  Copy B page, form widgets stripped). DEBUG: `-demoScreen 1099` renders a filled sample (the demo business
  now carries an EIN). Tests: render + preview + missing-data + long-text/untyped-TIN edge cases
  (`Form1099NECFiller` 100% covered). 224 tests pass. **This completes the subcontractor tax-document layer.**
- **Done — NOT yet committed (built + verified on iPhone & iPad simulators):** **Subcontractor W-9 / TIN
  capture (the tax-document layer, part 1 of 2).** Each subcontractor can now hold their W-9 details: a
  **TIN secured in the Keychain** (generalized `SecureTINStore` — it was single-item for the business; now
  keyed per record via a stable `tinKey`), a **TIN type** (SSN/EIN), and their **uploaded W-9 PDF**
  (reuses the shared `DocumentDetailScreen` view/upload/replace/remove, like the customer COI). The
  Subcontractor form gained a "Tax details (for their 1099-NEC)" section; the detail screen shows a
  **W-9 & Tax ID** card (TIN masked to last 4); deleting a sub clears its Keychain TIN. The accountant
  **1099-summary CSV now includes the TIN + TIN type**. New `Subcontractor` fields `tinKey` /
  `w9TINTypeRaw` / `w9Data` / `w9Name` (additive, still **V1**; the TIN value is Keychain-only — deploy
  the descriptor fields to CloudKit Production, see TODO). **Part 2 (next):** generate the **real IRS
  1099-NEC** — the official **Rev. December 2026** form (which restructured Box 1 into **1a Nonemployee
  compensation / 1b Cash tips / 1c TTOC / 1d Overtime compensation**) is analyzed and every Copy B field
  is coordinate-mapped; the filler will stamp it like `W9FormFiller` and be render-verified. New file:
  `Models/Subcontractor.swift` (extended) + the W-9 wrapper in `SubcontractorDetailScreen.swift`.
- **Done — NOT yet committed (built + verified on iPhone & iPad simulators):** **Subcontractors tab — Phase A
  (core).** A new top-level **Subcontractors** tab (iPhone) / sidebar section (iPad, "hammer" icon) for 1099
  trades you pay per job. A sub has name/business/contact/address + active toggle; you **record payments**
  (amount / date / method / what-for + optional customer/job tag). The tab shows a **1099 summary header**
  (total paid this year + how many subs cross **$600**), each row's YTD total + a **1099-NEC badge**, and a
  **Year-End Report** (toolbar → share) bundling a 1099-summary CSV + payment-ledger CSV for the accountant.
  New models `Subcontractor` / `SubPayment` (added to `GLSchemaV1.models`) + a `subPayments` inverse on
  `Customer` — additive, still **V1**; **deploy the new CloudKit record types/field to Production before
  release** (see TODO). New files: `Models/Subcontractor.swift`, `Screens/SubcontractorsScreen.swift`,
  `Screens/SubcontractorDetailScreen.swift`, `Screens/SubcontractorFormScreen.swift`,
  `UIComponents/SubPayExport.swift`. **Next round (the tax-document layer):** each sub's W-9 + TIN (Keychain,
  generalizing `SecureTINStore` per-sub), an uploaded W-9 PDF, and generating the **real IRS 1099-NEC**
  (Copy B for the sub, Copy C for records) like the W-9 — the CSV already covers the actual filing, since
  IRS Copy A must be e-filed/scannable. (W-2s stay accountant-handoff-only: a real W-2 needs withholding the
  app doesn't track; a 1099-NEC doesn't, so it can be generated.) DEBUG: demo seeds 2 subs;
  `-demoScreen subcontractors` deep-links the tab. Tests: `SubcontractorTests`, `SubPayExportTests`.
- **Done — NOT yet committed (built + verified on iPhone & iPad simulators):** **Employees tab — Phase A
  (core).** A new top-level **Employees** tab (iPhone) / sidebar section (iPad). An employee has a pay type
  (hourly or salary) + rate, a pay frequency (weekly / every-2-weeks / twice-a-month / monthly) and a payday
  anchor; the app rolls these into **next payday + amount accrued**. Features: **daily hours log** with an
  **optional customer/job tag** (+ a rate snapshot per entry, so per-job labor cost is captured from day one
  for a Phase-B rollup); **straight-time** pay (no overtime multiplier); a **payday-summary header** (soonest
  payday + total due across the crew); **record paychecks** (paid history, prefilled from what's accrued);
  **YTD gross/hours**; an informational **over-40-hours/week flag**; and a **Year-End Report** (toolbar →
  share) that bundles a wage summary + paycheck-ledger CSV for the accountant — *the app does NOT generate or
  file W-2s* (it tracks gross, not withholding; W-2 filing is the accountant's/payroll's job, by owner's
  choice). New models `Employee` / `TimeEntry` / `Paycheck` (added to `GLSchemaV1.models`) + a `timeEntries`
  inverse on `Customer` — all additive, still **V1**; **deploy the new CloudKit record types/field to
  Production before shipping** (see TODO). New files: `Models/Employee.swift`, `Screens/EmployeesScreen.swift`,
  `Screens/EmployeeDetailScreen.swift`, `Screens/EmployeeFormScreen.swift`, `UIComponents/EmployeePayExport.swift`.
  **Phase B (next):** onboarding pack — real **W-4 / I-9** form-fill (like the W-9), SSN (Keychain), and the
  per-job labor-cost rollup. DEBUG demo seeds 3 employees; `-demoScreen employees` deep-links the tab.
- **Done — NOT yet committed (built + launched on simulator; single-tab bar confirmed):** **Navigation
  reorg — Phase 1 of the tab restructure.** Removed the **Receipts** tab and the **Stats** tab; the iPhone
  tab bar is now just **Customers** (the Employees / Subcontractors / Calendar tabs land in later rounds).
  Receipts stay fully accessible (scan + add) via **Menu → Job Records → All Receipts**. Renamed the Menu's
  **Records** section to **Job Records**. Moved Stats onto the Business screen as a pushed **Statistics** row
  under *Generate a W-9* (`MyCompanyDetailScreen` → `StatsScreen`, now NavigationStack-wrapper-free with no
  Menu button), and **removed the duplicate Year-End Tax Report export** from the Stats screen — the Business
  *Year-End Tax Report* row is the single source now. iPad: dropped the Receipts + Stats sidebar sections (the
  single split shows Customers). `ScreenTab` / `AppSection` reduced to `.customers`; `ScreenTab.demoInitial`
  removed. **iPad sidebar relabeled:** title **Gold Life → My Business**, and the bottom account button (was
  the configured business name) is now a plain **Menu** button (dropped the now-unused `businessName` /
  `businessProfiles`). **Unreferenced but kept on disk** for a one-step revert of the iPad Stats split if the
  pushed-Statistics layout doesn't feel right on device (delete once settled): `Screens/StatsSplitColumns.swift`
  (the iPad Stats split) and `Screens/ReceiptsTabScreen.swift`. ⏳ On-device test of Menu → Business →
  Statistics pending (owner).
- **Done (V1 development), all tested on-device and committed to `main`:** Service Address on estimates +
  invoices; customer photo crop **and company-logo crop** (shared `ImageCropView` — configurable guide
  shape + safe-area-correct top bar; reads the key window's top inset since `fullScreenCover` doesn't pass
  the safe area down); logo light↔dark fallback fix + company-logo screen background + Settings "Use company
  logo" toggle; `job` added to the unit selector; estimate wording "Deposit due" → "Required Deposit";
  per-line-item **Remove** buttons; keyboard dismiss on scroll/tap-outside (+ Picker-tap conflict fixed);
  app display name **"GL Business"**; "Developer Feedback" mailto button (→ support@evolvedbygl.com).
- **Done (V1 development), built + verified on the simulator — ⚠️ NOT yet tested on-device or committed:**
  **Documents hub** — a new Menu destination (`DocumentsScreen`, peer to My Company) that is the single
  home for generating/sending business documents. **Architecture rule going forward:** *My Company holds
  the reusable data (identity, tax details, signature, soon insurance); Documents holds the actions
  (generate + send).* Don't add more document generators to My Company. Today it has **Year-End Tax
  Report** (the accountant export — receipts CSV + tax summary — behind an inline year picker defaulted to
  the **last completed year**) and **Generate a W-9** that fills the **actual official IRS Form W-9 (Rev.
  3-2024)**.
  The blank government PDF page 1 is bundled at `Resources/W9Template.pdf`; `W9PDF.render` stamps the
  company's details onto it at the form's **real AcroForm field coordinates** (read from the template's
  fields — name, the 7 classification checkboxes, LLC letter, address, and the comb SSN 3‑2‑4 / EIN 2‑7
  boxes) via `CGContext` + Core Text, then flattens to a single shareable page. Looks pixel-identical to the
  IRS form. (Earlier app-drawn approximation `W9PDFDocument.swift` was replaced by `W9FormFiller.swift`.)
  **My Company → "Signature"** row (Face-ID-gated): create a saved signature by **draw** (PencilKit),
  **type** (Italianno script), or **import** (photo, near-white knocked out). The W-9 has an **"Export with
  Signature and Date"** toggle (default on) that, after a Face ID unlock, draws the saved signature image
  onto the form's signing line and fills the date.
  Stats **"Export for Accountant" → "Year-End Tax Report"** (both iPhone + iPad). New **additive**
  `BusinessProfile` fields (still **V1**, no migration): `w9Name`, `w9TaxClassificationRaw`,
  `w9LLCClassification`, `w9OtherClassification`, `w9TINTypeRaw`, `w9TIN`, `w9ExemptPayeeCode`,
  `w9FATCACode`, and `signatureData` (`@Attribute(.externalStorage)`, CloudKit-synced). Added
  `NSFaceIDUsageDescription` to Info.plist. New files: `UIComponents/W9FormFiller.swift`,
  `UIComponents/SignatureKit.swift`, `Screens/CompanyDocuments.swift`, `Screens/SignatureEditorSheet.swift`,
  and the bundled `Resources/W9Template.pdf` (official IRS form, public domain).
- **Done — committed to `main` (e9e2bab):** the W-9 / signature / Documents-hub work above.
- **Done — NOT yet committed (built + verified on simulator):** **Insurance & WC Exemption.** The owner
  *uploads* the certificate PDFs manually (no generation — superseding the earlier "fill a blank COI" idea):
  a **Proof of Insurance** (COI) and a **Workers' Comp Exemption**, managed in **My Company → Insurance & WC
  Exemption** (`ComplianceDocsManagerSheet`: upload / replace / remove via `.fileImporter` `[.pdf]`, stored on
  `BusinessProfile` as `proofOfInsuranceData` / `wcExemptionData` + name fields, additive → still **V1**,
  CloudKit-synced). A new **Documents → "Insurance & WC Exemption"** row (`InsuranceDocumentsSheet`) previews
  the uploaded cert(s) and shares them (navbar `ShareLink`); if none uploaded it routes to the uploader
  (same pattern as the W-9 "Add tax details"). Extracted the shared in-sheet `DocActionRow`. New file:
  `Screens/InsuranceDocuments.swift`.
- **Done — NOT yet committed (built + verified on simulator):** **My Company restructure + personal info.**
  The My Company screen condensed to a hub: logo, business name, a **Contact** card (now incl. the owner's
  **Name**), then rows — **Details**, Receipts, Signature, Insurance. New read-only **Details** screen
  (`CompanyDetails.swift`) shows *everything* from the edit form categorized (Contact, License, Address,
  Estimate/Invoice messages, W-9 tax details — **TIN masked to last 4**). New **`UserProfile` @Model**
  (firstName/lastName/email/phone) for the account owner — **added to `GLSchemaV1.models`, so CloudKit gets a
  new `CD_UserProfile` record type to deploy** (still V1, additive). New Menu row **My Personal Info**
  (`PersonalInfo.swift`); the **My Company** Menu row + screen renamed **My Business Details**.
  Later refinements (also uncommitted): business **owner name** (`ownerFirstName`/`ownerLastName` on
  `BusinessProfile`, separate parts) drives the Contact card; "Details" row → **"More Info"**; the duplicate
  **Receipts** row removed (single source = the Receipts tab; deleted the orphaned `BusinessReceiptsScreen`);
  "Insurance & WC Exemption" → **"Insurance & Exemptions"** everywhere; the uploader cards are now fully
  tappable rows (tap to upload, or a Replace/Remove dialog when filled). **The saved signature moved off
  `BusinessProfile` onto `UserProfile`** (`signatureData` — it's the person's, and the W-9 reads it from
  there), so the **signature now syncs as part of `CD_UserProfile`, not `CD_BusinessProfile`**; the Signature
  row moved from My Business Details to **My Personal Info**.
- **Planned next (owner-requested):** **Send Compliance Packet** — bundle W-9 + Proof of Insurance + WC
  Exemption into one email with a fixed header/body/sign-off (brand voice per evolvedbygl.com: clean, honest,
  no shortcuts), owner just picks the outgoing account and sends (MFMailComposeViewController, device-only).
  Lives in the **Documents** hub.
- **CloudKit:** V1 (10 record types) deployed to Production. A one-time **completeness seed** (since removed)
  populated every field including the image/asset ones; `serviceAddress` + the dark-logo asset were deployed.
  ⏳ **Final deploy to confirm:** the `CD_Receipt` `scanData` + `customer` fields the seed surfaced — deploy
  via the Console (§7); then Production = the full model.
- **Ready:** fresh **Release archive** at `/tmp/GLSmallBusiness.xcarchive` (v1.0 (1), iPhone/iPad only,
  "GL Business" — re-archived with all changes, ready to upload). **App Store listing + privacy policy
  drafted** (`AppStore-Listing-DRAFT.md`, `PrivacyPolicy-DRAFT.md`).
- **Pending before launch (needs the owner):**
  - **TODO — deploy the new `CD_BusinessProfile` fields to CloudKit Production (§7).** The Generate-a-Document
    work added the W-9 fields + `signatureData` to `BusinessProfile`. Run the app so SwiftData mirrors the new
    fields into the **Development** schema, then **Deploy Schema Changes → Production** (all additive). Skipping
    this = sync silently breaks for users.
  - **TODO — bump the build number** for the next submission (and re-archive Release) once this feature is
    tested on-device and committed.
  - Confirm the final **CloudKit `CD_Receipt` deploy** (above).
  - **Host the privacy policy** at a public URL; finalize listing decisions (price, audience, keywords).
  - **App Store Connect:** create the app record, upload the archive (needs an ASC API key, or Xcode
    Organizer), add screenshots (iPhone 6.9" + iPad 13") + metadata, and submit for review.
- **Done — NOT yet committed (built + verified on simulator):** **Owner reference COI (optional).** Added an
  optional, owner-only **Certificate of Insurance** slot to the **Insurance & Licensing** sheet
  (`ComplianceDocsManagerSheet`) so the owner can upload a spare/blank COI for their own records. It is
  deliberately **not** a `ComplianceKind`, so it's excluded from the sheet's "share all" `ShareLink` and the
  Contractor Package — it never reaches a customer. The per-customer COI (`Customer.coiData`) is unchanged.
  New `BusinessProfile` fields `ownerReferenceCOIData` (`@Attribute(.externalStorage)`) + `ownerReferenceCOIName`
  (additive → still **V1**, CloudKit-synced; deploy the new field to the CloudKit Development schema →
  Production like the others). Reuses the existing `.fileImporter` `[.pdf, .image]` + `DocumentDetailScreen`
  patterns.

## 12. Working conventions / preferences

- **Git:** commit & push **directly to `main`**. Do **not** open PRs unless explicitly asked. End commit
  messages with a `Co-Authored-By:` trailer.
- **Code style:** prefer **Apple-recommended, idiomatic first-class SwiftUI APIs** over hacks; **verify
  changes empirically** (build, and run on a real device for UI/gesture/keyboard/CloudKit behavior).
- **Scope discipline:** do exactly the change requested — don't "improve" surrounding presentation/behavior
  unless asked (e.g. when swapping which image shows, keep the existing display treatment identical).
- **Guidance:** drive decisions with a clear recommended default; proactively flag industry/business norms.
  The owner is a capable non-CS small-business owner — explain technical trade-offs plainly when asked.

## 13. Design requirements

The design bar is Gold Life's **Gold Standard — review it before any UX/visual/copy decision:**
**🔗 https://evolvedbygl.com** → *"One standard. Many ventures."* · *"The work I do for you is the work I'd
do for my own. With restraint. With care. Without shortcuts."* Clean, honest, intentional. Every screen and
every line of customer-facing copy must clear that bar.

- **Brand & voice:** GL gold is the single accent (`Color("AccentColor")` / `GLColor.gold`, resolved
  appearance-aware via `.render(in:)`). Titles use the calligraphic **Italianno** script; body uses **Inter**.
  Copy is plain and honest, no fluff — in-app *and* in customer-facing documents/emails.
- **Visual language (iOS 26 "Liquid Glass"):** card-based layouts (`glCardBackground()` / `GLCard`),
  `glassEffect` where it fits, the GL monogram backdrop (`PrimaryBackground`). Full **light + dark** support —
  never hard-code colors; resolve through `GLColor`. The company logo may replace the monogram (Settings
  toggle) — honor `BusinessProfile.logo(for:)` fallbacks.
- **Information architecture — grouped by owner.** The Menu is a single **My Info** section with two rows,
  **Business** (`MyCompanyDetailScreen`) and **Personal** (`MyPersonalInfoScreen`). Each is a hub: identity up
  top (logo/photo, name, a Contact card), a **More Info** row → read-only categorized details (with the
  **Edit** there), and that owner's actions as rows. The **Business** screen carries the business-document
  actions — **Insurance & Exemptions**, **Year-End Tax Report**, **Generate a W-9** — plus **Statistics**
  (the business charts + KPIs, pushed). (There is no separate "Documents" hub anymore — it was consolidated
  onto the Business screen. The owner prefers one category over a peer hub; group by owner, not by
  data-vs-actions.) The Menu's records section is **Job Records** (All Estimates / Invoices / Change Orders /
  Receipts).
- **Sheet dismissal (see §8):** **X close** (`Button(role: .close)`, `.topBarLeading`) for presentational
  sheets; **Cancel + Save** for editing; **Edit↔Done** for list edit mode. Never a bare "Done" just to close.
- **Cross-device — iPhone *and* iPad:** ships on iPhone (`RootTabView`, compact width) and iPad / large-iPhone
  landscape (single three-column `NavigationSplitView`, regular width). Shared components — the **Menu sheet**
  (My Company, Documents, Settings), forms, and document sheets — must render correctly on both. **Every change
  must preserve the iPad split-view flow;** verify it (launch an iPad sim with `-demoMode` to bypass the gate,
  then screenshot — see §5).
- **Generated documents look genuine:** official forms (W-9 today; COI / WC next) **fill the real official
  PDF** so output is indistinguishable from the genuine document — never an app-drawn approximation.
- **Interaction principles:** drive with a clear recommended default; prefer **Apple-recommended, idiomatic
  first-class SwiftUI APIs** over hacks; **verify empirically** (build → run → screenshot; don't assume
  layout). Icon-only buttons get an `accessibilityLabel`.
