# Handoff — 2026-06-24

Everything committed to `main` and pushed. 378 tests pass. Pick up tomorrow at **"Your next action"** below.

---

## 🔭 Active feature: CloudKit Sharing (use the app on a 2nd phone with a different Apple ID)

**Goal:** your work phone (Apple ID A) is "home base"; connect your personal phone (Apple ID B) and see/edit the same data live.

**Decisions locked in:**
- **v1 scope:** just your own 2nd phone, **full read-write**. Inviting other people (read-only, hiding SSN/banking, whether they pay) is a later round.
- Apple-side setup is being walked through **one step at a time**.
- Assumed the app is **still in development** (not on the App Store) → migration risk is low. **Confirm this is true** — if it's live with real users, we switch to the full backup-and-verify migration.

**Why it's non-trivial:** SwiftData has **no CKShare support**, so the sync engine has to move from SwiftData's `cloudKitDatabase: .automatic` to an `NSPersistentCloudKitContainer` (Core Data) driving CloudKit, while SwiftData keeps serving the UI on the **same store file** ("route R1").

### ✅ Done & proven (this is the hard part, and it's green)
- **Research + phased plan** (5 gated phases; the live-data migration is its own reversible phase).
- **Route R1 proven by 3 spike tests** — `GLSmallBusinessTests/CloudKitEngineSpikeTests.swift`:
  1. the SwiftData→Core Data bridge model covers all 24 entities,
  2. the Core Data engine **adopts** SwiftData's existing store (no duplication),
  3. both engines run on one store **concurrently** and see each other's writes.
- **The engine itself** — `GLSmallBusiness/AccessControl/CloudKitSyncEngine.swift`, wired into `GLSmallBusinessApp.swift` behind a **DEBUG flag, default OFF**. With the flag on, the real app launches + renders + reads data in the simulator (no crash, no fallback). **Your current live behavior is 100% unchanged** (flag off).
- Commits: `2e6d233` (adoption spike), `619e866` (coexistence spike), `080d13e` (engine swap).

### 🔑 The constraint
Claude **cannot sign into an iCloud account** (entering account passwords is off-limits), so the on-device CloudKit testing is **yours to run** — Claude builds it and gives exact steps + reads the results.

### 👉 Your next action (resume here)
1. **Make a free throwaway Apple ID** (in progress): appleid.apple.com → Create Your Apple ID → spare email + your phone for the code. Don't sign it into your everyday phone.
2. Tell Claude **"done"** — it'll then walk you through:
   - signing the throwaway ID into a **test device** (or the simulator),
   - running the app with the engine flag on (Xcode scheme → Arguments → add `-useCloudKitSharingEngine YES`, or `xcrun simctl launch … -useCloudKitSharingEngine YES`),
   - confirming data **syncs** to that account and that switching engines **adopts** cloud data instead of duplicating it.

### 🧭 Remaining phases (after the on-device validation)
- **Phase 2** — ship the sync-engine swap as its own release (still private-only, no sharing UI) to de-risk sync parity. Add a resumable `migrationState` flag.
- **Phase 3** — accept-invite plumbing: `windowScene(_:userDidAcceptCloudKitShareWith:)` + cold-launch `cloudKitShareMetadata`; `CKSharingSupported=true` in `Info.plist`; production `aps-environment`; a **participant path past the AppGate paywall** (a 2nd-Apple-ID device has no subscription — see `AccessControl/AppGate.swift`).
- **Phase 4** — sharing UI: a "Connect a device or person" row in `MenuScreen`, `UICloudSharingController` (wrapped) to mint/manage the share, a participants list.
- **Phase 5** — the **gated, reversible production migration** on your real store: backup sqlite + `-wal`/`-shm` → re-import → count-verify across a relaunch → then the single irreversible `container.share()`.

### ⚠️ Migration guardrails (for Phase 5)
- Never mutate the live cloud zone in place; re-import down from it (rollback = restore sidecars + revert to `.automatic`).
- Backup-first, idempotent/resumable state flag, count-verify all 24 models before the irreversible `share()`, feature-flag `share()`.
- Keep the DEBUG `wipeSwiftDataStore` strictly DEBUG and away from the migrated store.

### 🛠 Apple-side prerequisites (Claude will guide each)
Throwaway Apple ID (+ a burner for the participant side later) · `CKSharingSupported` in Info.plist · Push Notifications capability (production APS) · deploy the schema to the **Production** CloudKit environment · (optional) a `.staging` CloudKit container.

> Full durable summary also lives in Claude's memory: `reference_cloudkit_sync_model.md`.

---

## 📦 Also shipped this session (done — no follow-up needed)
- **Test coverage** raised to ~80%; new-code files 70–100% (`f274ee6` era + earlier).
- **Calendar** — All Jobs moved above the grid; an "AVAILABILITY" header bar with View gaps; the Next-available / Next-clear rows are tappable and push a pre-filled new job (`0dc49a4`, `f274ee6`).
- **Sheets → pushes (app-wide)** — every data-entry form and detail-content screen now pushes instead of opening a cramped iPad sheet; only quick/system sheets remain (`bd15d36`…`a8f3f67`).
- **Info tips (ⓘ)** — now a fit-to-text sheet instead of a popover, fixing the clipping + tight padding on iPhone and iPad (`d5305aa`).
- **Jobs: photos, documents, receipts** — proof-of-work photo gallery, document uploads (insurance-doc flow), and receipts attachable to a job (new `JobAttachment` model) (`75994a4`).
- **Edit menus** — shortened "Edit subcontractor/job/invoice/…" to just **"Edit"**, and added a direct **Edit** to the Customer/Employee/Subcontractor/Company/Personal landing menus (no more "More Info first") (`8cb1736`).

## 🧪 How to run tests
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SmallBusinessApp
sim=$(xcrun simctl list devices available | grep -oE "iPhone 1[5-7]( Pro)?" | head -1)
xcodebuild test -project GLSmallBusiness.xcodeproj -scheme GLSmallBusiness \
  -destination "platform=iOS Simulator,name=$sim" -only-testing:GLSmallBusinessTests
```
(Do **not** pass `CODE_SIGNING_ALLOWED=NO` — it breaks the keychain tests.)

## ⚠️ Uncommitted WIP (left untouched, not mine)
`SubscriptionManager.swift`, `AddressSearch.swift`, `AddressSearchTests.swift`, `GLSmallBusiness.storekit`, `project.pbxproj`, `Localizable.xcstrings` — your pre-existing changes; I never staged these.
