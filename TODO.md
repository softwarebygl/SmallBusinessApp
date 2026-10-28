# TODO — Release checklist (version 1.0, build 5)

Resubmit under the SAME version **1.0** (v1 was declined, not approved) as a new build (currently
build 5). The rejection is fixed in code; the rest is owner-only (App Store Connect / dashboards).

## Owner to-dos (added 2026-10-03)
- [ ] **Close the test Stripe account `acct_1UMamxJ7EcYdpteu`.** Claude's QA probe created it by mistake
      on 2026-10-03 (no onboarding, no bank, no money). https://dashboard.stripe.com/connect/accounts →
      open `acct_1UMamxJ7EcYdpteu` → … → Close account.

## Apple rejection (Submission d31fa574) — code fixes DONE
- **3.1.1 (promo codes unlock paid functionality).** Custom GL access-code system removed entirely
  (`AccessCodes`/`AccessManager`/`RedeemCodeView`/`GLCodeField` deleted). Access is gated solely on
  an active StoreKit subscription; comps use **Apple offer codes** (paywall + Settings show **Redeem
  Code**).
- **3.1.2(c) (subscription info in-app).** Paywall shows title / length / price + Terms of Use and
  Privacy Policy links; Settings has the same plus Manage / Restore / Redeem.

## Owner actions — App Store Connect / dashboards (can't be done from code)
- [ ] **Deploy the CloudKit schema to PRODUCTION** (CloudKit Dashboard → Deploy Schema Changes).
      ⚠️ Most important. Order matters: first run the **latest** build once on a device/sim signed
      into iCloud so the Development schema includes everything added this session, THEN deploy.
      New since the original schema: `ChangeOrder` + `ChangeOrderLineItem` record types; new fields on
      `BusinessProfile` (license document, COI-holder placement, and the editable subject/intro/closing
      message fields for estimate/invoice/receipt/change-order/package) and `Customer` (`middleName`,
      `officePhone`, and the per-customer COI: `coiData` + `coiName`). **Employees feature (Phase A):**
      new `Employee`, `TimeEntry`, `Paycheck` record types, plus a new `timeEntries` relationship field
      on `Customer` (the job tag's inverse). **Subcontractors feature (Phase A):** new `Subcontractor`,
      `SubPayment` record types, plus a new `subPayments` relationship field on `Customer`. **Subcontractor
      W-9/TIN capture:** new `tinKey`, `w9TINTypeRaw`, `w9Data` (externalStorage), `w9Name` fields on
      `Subcontractor` (the TIN *value* lives in the Keychain, not CloudKit — only these descriptors sync).
      **Subcontractor owed/paid ledger:** new `hourlyRate` on `Subcontractor`, and `hours` + `paidDate`
      (optional) on `SubPayment` (paidDate nil = owed/unpaid).
      **Calendar feature:** new `ScheduledJob` record type, plus `scheduledJobs` relationship fields on
      `Estimate` and `Invoice`. **Profile photos:** new `profileImageData` (externalStorage, optional) on
      `Employee` and `Subcontractor`. All additive/optional (still schema V1), but they MUST be in production
      or sync drops them for real users. (The workdays / one-job-at-a-time settings are device-local `@AppStorage`
      — not CloudKit, no deploy.)
      **NEW (updates-to-version-one branch)** — additive/optional fields that must be deployed to Production
      too or they silently won't sync: `discountType` + `discountValue` on BOTH `EstimateLineItem` and
      `InvoiceLineItem` (per-line discounts); `websiteURL` + `reviewsURL` on `BusinessProfile` (website +
      the customer-review link); and `includeReviewLinkOnReceipts` (Bool) on `BusinessProfile` — the
      opt-in that decides whether receipts carry the review link (added 2026-07-18; a set link is
      grandfathered ON for existing users by `ReviewLinkBackfill`). Everything else this session
      (phone/TIN formatting, the unsaved-changes guard, payment methods, units, receipt photo/job) added
      NO new CloudKit fields.
- [ ] **2.1(b): Submit the In-App Purchase products for review** — submit the two subscriptions
      (monthly / annual) in App Store Connect and attach the App Review screenshot. The binary
      references them but they were never submitted.
- [ ] **3.1.2(c) metadata:** add the **Privacy Policy URL** and the **Terms of Use (EULA)** link in
      App Store Connect (App Description or the custom EULA field).
- [ ] **Upload screenshots.** Fresh set in `~/Desktop/GL_AppStore_Screenshots/` — 6.9" iPhone
      (iphone-1…6) + 13" iPad (ipad-1). Default GL branding; iphone-6 is the "make it yours"
      customization shot (custom logo). Add captions/frames if desired.
- [ ] **Reply to App Review** with a screen recording of the subscription flow + policy links, noting
      the promo-code mechanism was removed (App Review Information → Notes).
- [ ] **Archive a Release build (1.0, build 5)** and submit. Bump the build number for any re-upload.
- [ ] On your own device: **delete + reinstall once** (new data models), then clear the stray
      no-customer invoice via **Menu → All Invoices** if still present.
- [ ] Verify https://softwarebygl.com/my-business/privacy and /my-business/terms are live and reachable.

## Backlog — not scheduled

- [ ] **Migrate off CloudKit to a custom backend with real user accounts** (decided 2026-07-09).
      Goal: users create app accounts that can be shared with other users' accounts — the same business
      data visible across people with different Apple IDs. Cross-Apple-ID CloudKit sharing (CKShare) was
      attempted and fully removed (blocked on iOS 26.5); a custom backend is the only viable path.
      Requires: auth + server datastore (Cloudflare Workers is the house pattern — see gl-stripe-connect),
      and a **safe migration** of all existing live users' CloudKit data with zero loss (export from
      CloudKit per-user on first launch of the new version, verify counts, then cut over). Big, breaking
      project — plan as its own version with its own spec before touching code.

## Gold Life ID — unified login

Goal: My Business users get the one-account login (Sign in with Apple → Gold Life ID),
so one account works across every GL app. Gold Life ID = a shared **Stytch** project
that all apps authenticate against. This is the **auth/identity half** of the
"Migrate off CloudKit to a custom backend" backlog item above — do this first (it's low-risk and does NOT
touch CloudKit data); the shared-data server backend is the separate, bigger second half.

Reference: `gl-money-api/REFERENCE.md`.

> **📄 CURRENT PLAN (rewritten 2026-07-29): `~/Desktop/MyBusiness-GoldLifeID-BuildPlan.md`** —
> state verified post-merge; execute from the plan, not from these bullets.

- [x] **App:** full app-side retrofit MERGED to `main` 2026-07-29 (Stytch SIWA + hidden Google,
      Keychain session, soft-gate card, Settings/About Account-ID sections, Delete Account,
      `/app-link` CloudKit-userRecordID linking, SIWA entitlement + SPM packages). Ships DARK in
      v3.0.0 behind `GoldLifeID.enabled = false` (`AccessControl/GoldLifeIDPrompt.swift`).
- [ ] **Apple (Adrian):** group App ID `com.evolvedbygl.GLSmallBusiness` under the primary Gold Life ID App ID
      (same Apple `sub` — without it every user forks into two IDs).
      No new key/Service ID needed.
- [ ] **Stytch (Adrian):** authorize `com.evolvedbygl.GLSmallBusiness` in the Gold Life ID LIVE
      project's Apple OAuth config.
- [ ] **Server:** gl-money-api `/app-link` + migration 0016 deployed.
- [ ] **Flip-on release:** set `GoldLifeID.enabled = true`, run the E2E checklist in the plan
      (the fork check: same Apple ID → SAME Gold Life ID across apps), ship as its own 3.x.
- [ ] **Sign in with Google** (queued 2026-07-17, cross-platform prep): when the Gold Life ID gate lands
      here, offer Google alongside Apple. **Native only** — Google's official Sign-In SDK on-device +
      a Stytch **Trusted Auth Token** exchange server-side. NEVER Stytch's web OAuth flow: it shows an
      Apple sheet naming "stytch.com", which Adrian rejected outright (2026-07-17) — no
      third-party name in the sign-in flow. The Google Cloud project ("Gold Life ID") + Stytch Google
      provider are already configured. Apple guideline 4.8 stays satisfied — Sign in with Apple first.
