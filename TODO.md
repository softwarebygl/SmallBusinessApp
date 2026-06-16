# TODO

## App Review rejection (Submission d31fa574) — code fixes done
The 1.0 (4) rejection was addressed in code:
- **3.1.1 (promo codes unlock paid functionality).** The custom GL access-code system is removed
  entirely (`AccessCodes`, `AccessManager`, `RedeemCodeView`, `GLCodeField` deleted). Access is now
  gated solely on an active StoreKit subscription. Comp/discount is handled the compliant way via
  **Apple offer codes** — the paywall and Settings show Apple's **Redeem Code** button.
- **3.1.2(c) (subscription info in-app).** The paywall shows title / length / price and links to the
  Terms of Use and Privacy Policy; Settings also has Terms of Use + Privacy Policy links plus
  Manage / Restore / Redeem.

Resubmit under the SAME version (1.0) as a new build (currently build 5).

## Remaining — owner actions only (App Store Connect / dashboards — can't be done from code)
- [ ] **2.1(b): Submit the In-App Purchase products for review.** In App Store Connect, submit the
      two subscriptions (monthly / annual) for review and attach the required App Review screenshot.
      The binary references them but they were never submitted.
- [ ] **3.1.2(c) metadata:** add the **Privacy Policy URL** in the Privacy Policy field, and the
      **Terms of Use (EULA)** link in the App Description (or the custom EULA field) in App Store Connect.
- [ ] **Reply to App Review** with a screen recording showing the subscription flow + policy links,
      and note that the promo-code mechanism was removed (put this in the App Review Information notes).
- [ ] **Archive a Release build and submit** (build 5; bump for each later submission).
- [ ] **Deploy the CloudKit schema to Production** (CloudKit Dashboard → Deploy Schema Changes —
      includes the new `ChangeOrder` record types), or sync breaks for real users.
- [ ] On your own device: **delete + reinstall** once (new data models), then clear the stray
      no-customer invoice via **Menu → All Invoices**.
- [ ] Verify https://evolvedbygl.github.io/privacy/ and /terms/ are live and reachable.
