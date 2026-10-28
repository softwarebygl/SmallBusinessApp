# Stripe Invoice Payments — Spec & Go-Live

Let customers pay an invoice by card (and later ACH) from a **Pay this invoice** button embedded in the emailed/texted invoice. Built 2026-06-30.

## Architecture (as built)

- **Stripe Connect · direct charges · Standard accounts.** Each business connects its *own* Stripe account; payments land in *their* balance; *they* own refunds, disputes, payouts, and are the merchant of record. The platform (Gold Life) takes **$0 fees** and never touches the money. No application fee at launch.
- **Onboarding = Connect Onboarding (Account Links)**, not OAuth (Stripe deprecated OAuth for new platforms). Opened in-app via `ASWebAuthenticationSession`; returns through the `glsmallbusiness://connect-return` scheme.
- **Per-invoice Payment Link**, minted at **send time** (so a never carries a stale amount), locked to `Invoice.currentAmountDue` via inline `price_data` (the customer can't edit it), `restrictions.completed_sessions.limit = 1`. Deactivated by the webhook once paid.
- **Backend = a separate Cloudflare Worker** (`../gl-stripe-connect`), free tier, D1 storage. Holds the Stripe **platform secret key** (never in the app). Stores only: hashed install-token → `acct_…` ownership, a paid/open status row per invoice, and processed webhook ids. **No invoice or customer data** — the app's data stays 100% in the user's private CloudKit.
- **Apple:** allowed under **App Store Review Guidelines §3.1.3(e)** (real-world services consumed outside the app must use non-IAP). Kept separate from the app's own StoreKit subscription (§3.1.1) — the Pay button appears **only** in outgoing customer messages, never on an app screen.

## Flow

1. **Settings → Get paid by card (Stripe)** → connect (or finish) the account; pick inclusion mode: **All / Choose per invoice / Off**.
2. **Send** an invoice: if it should carry a link, the app re-checks the account can charge, mints/reuses the link, injects the gold **Pay this invoice** button into the email/SMS body, then opens the composer. **Fails open** — any backend problem just sends the invoice without the button.
3. **Paid:** the webhook records paid + deactivates the link. The app **polls** on invoice-open / foreground and, on first paid, prompts *"Stripe reports this invoice was paid ($X). Record it?"* → writes through the existing `InvoicePayment` flow (the money source of truth; guards against ACH reversals/double-counting).

## Key files

- App: `Models/PayLinkInclusion.swift`, Stripe fields on `Models/BusinessProfile.swift` + `Models/Invoice.swift` (additive → fold into `GLSchemaV1`), `Networking/StripeBackendClient.swift` + `StripeInstallTokenStore.swift`, `Screens/StripeConnectScreen.swift`, edits to `Screens/SettingsScreen.swift` · `Screens/InvoiceDetailScreen.swift` · `UIComponents/InvoiceMessage.swift` · `Info.plist`.
- Backend: `../gl-stripe-connect/` (see its README for deploy).
- Tests: `GLSmallBusinessTests/StripePaymentsTests.swift`.

---

## GO-LIVE CHECKLIST (only Adrian can do these — gates all testing)

> Do everything in Stripe **test mode** first, then repeat for live.

1. **Stripe:** create a Stripe account → enable **Connect** (Standard, direct charges). Copy the **platform secret key**.
2. **Cloudflare / backend:** follow `../gl-stripe-connect/README.md` — `wrangler login`, create the D1 DB, apply `schema.sql`, set secrets (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `APP_SHARED_SECRET`), `wrangler deploy`. Note the printed Worker URL.
3. **Stripe webhook:** add a **Connect** endpoint → `https://<worker-url>/stripe/webhook`, event `checkout.session.completed`; copy its `whsec_` into `STRIPE_WEBHOOK_SECRET`.
4. **iOS config:** in `Networking/StripeBackendClient.swift`, set `StripeConfig.baseURL` (the Worker URL) and `StripeConfig.appSecret` (same `APP_SHARED_SECRET`). Until these are filled, the app fails closed (no Stripe calls) — it won't crash.
5. **CloudKit production schema (REQUIRED before this update ships):** the new fields are additive and fold into `GLSchemaV1` via lightweight inference, but because the app is LIVE, deploy the updated schema in **CloudKit Dashboard → Deploy Schema Changes** before submitting the build, or sync breaks for updaters.
6. **Submit with the App Review notes below.**

## App Review notes (paste into App Store Connect → Notes)

> This app lets a contractor collect payment from **their own customers** for real-world services performed **outside the app** (e.g. construction/remodeling). Per **App Store Review Guideline 3.1.3(e)**, these payments use a card processor (Stripe), not in-app purchase. The "Pay this invoice" link appears only inside the invoice the contractor emails/texts to their customer — never as an in-app purchase surface.
>
> The app's own optional subscription is a **separate StoreKit in-app purchase** and is unrelated to this feature.
>
> Connecting Stripe requires real onboarding a reviewer can't complete, so: [attach a test-mode connected account / a screen recording of connect → send → pay → record]. During connect, iOS shows a system "…wants to use stripe.com to sign in" prompt — that's expected.

## Deferred (not at launch)

Application/platform fee · ACH (`us_bank_account` — needs the `checkout.session.async_payment_succeeded/failed` webhooks + an `InvoicePayment` reversal path) · silent-push paid alerts (polling on open/foreground instead) · custom domain for the Worker (ship on `*.workers.dev`, move before scaling).

## Hardening (done in QA pass — 2026-06-30)

- ✅ Resume now requires a **signed HMAC ownership claim** (issued at onboarding, stored on `BusinessProfile.stripeAccountClaim`, verified on resume) — knowing an `acct_…` id alone can't bind it to another install.
- ✅ `POST /connect/onboard` account creation is **rate-limited per IP** (D1 `rate_limit` table, 8/hour).
- ✅ Payment Links are **card-only** (`payment_method_types: ['card']`) — closes the ACH-async reconciliation gap; enabling ACH later needs the `checkout.session.async_payment_*` webhook events.
- ✅ Idempotency key carries a per-mint nonce (`Invoice.stripePayLinkMintCount`) so a milestone amount round-trip can't replay a deactivated link; recorded card payments carry `InvoicePayment.stripePaymentLinkId` so the poll never loses or double-counts a payment.
