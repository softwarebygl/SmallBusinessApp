# TODO — Release checklist (version 1.0, build 5)

Resubmit under the SAME version **1.0** (v1 was declined, not approved) as a new build (currently
build 5). The rejection is fixed in code; the rest is owner-only (App Store Connect / dashboards).

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
      on `Customer` (the job tag's inverse). All additive/optional (still schema V1), but they MUST be in
      production or sync drops them for real users.
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
- [ ] Verify https://evolvedbygl.github.io/privacy/ and /terms/ are live and reachable.
