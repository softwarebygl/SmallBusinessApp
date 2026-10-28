# App Store listing — v3.0 (build 41)

**Status:** the v2.0 section below is HISTORY, kept for reference. It is factually
wrong for this release and must not be pasted: it promises "your own private iCloud"
and "no separate account to create," both of which the Gold Life backend cutover
ended. Everything above this line is the copy that ships.

**The one rule this rewrite follows:** the app now stores business records on Gold
Life servers when you are signed in, and nowhere but the phone when you are not. Every
sentence here has to survive a reader who signs in, a reader who never does, and App
Review reading it beside the privacy label.

---

## Name (≤ 30 chars)
**My Business - Evolved by GL**  *(28)*

## Subtitle (≤ 30 chars)
**Estimates, invoices & receipts**  *(30)*

## Promotional text (≤ 170 chars — editable anytime, no review)
Estimates, invoices, scheduling, payroll, and 1099s for the trades. Sign in to back
your work up to your Gold Life account and reach it from any device.  *(159)*

## What's New in This Version (release notes)
Your work is backed up now.

Sign in from the Gold Life ID card in the Menu and your customers, invoices, jobs, and
documents back up to your Gold Life account — and show up on every device you sign in
on. One account across every Gold Life app.

Signed out, the app still does everything it always did. There is just no backup, and
the app says so plainly instead of leaving you to guess.

Your tax paperwork gets its own handling. A subcontractor's W-9 is encrypted on this
iPhone before it is backed up, so the file cannot be read where it is stored. Tax IDs
(SSN/EIN) are never backed up at all — they stay in your iPhone's Keychain.

Delete what you mean to. Your Gold Life ID screen now lists every Gold Life app and
what each one is holding. Erase one app's backup on its own, or delete your whole Gold
Life ID once they are all empty. Both ask you to type your Gold Life ID first, and
neither has an undo.

Also in this update:
• Options Estimates — give your customer choices! Turn off 'Combine into one total' to present multiple priced options in a single PDF.
• One Contacts tab — customers, employees, and subs together, a tap apart. Your phone's
  address book is always called Phone Contacts, so the two never mix.
• The Jobs tab — every job in one list, with the calendar, your availability, and
  booking one tap away.
• Español, built in — switch the whole app in Settings → Language, instantly, no
  restart. Money and dates keep your region.
• A finer finish, and the built-in How To guides now open clean.

## Description (≤ 4000 chars)
My Business is a professional toolkit for running a small contracting or trades
business — built for the way you actually work: labor and materials together, job after
job.

CUSTOMERS
• Keep every customer's contact info, addresses, insurance, and full job history in one
  place.

ESTIMATES
• Build clean, grouped estimates with labor and material line items.
• Set tax (applied only to taxable items), discounts, and a required deposit.
• Add a separate job-site address, and convert an accepted estimate into an invoice in
  one tap.

INVOICES & PAYMENTS
• Branded invoices with deposit and milestone billing, and every payment logged.
• Get paid by card: connect your own Stripe account and add a "Pay this invoice" button
  — your customers pay by card and the money goes straight to your Stripe account
  (optional).
• Signature-ready change orders for mid-job scope changes. A paid invoice is settled —
  it cannot be quietly edited or deleted out from under your books.

SCHEDULING
• A calendar that knows your next open day and every gap, with recurring work that books
  itself.

CREW & PAYROLL
• Log hours against the job, watch pay accrue toward the next payday, and export a clean
  year-end CSV.

SUBCONTRACTORS & 1099
• Track owed-vs-paid, watch the $600 threshold automatically, and generate the real IRS
  Form 1099-NEC.

RECEIPTS
• Scan expense receipts with your camera — the vendor, date, and total file themselves
  against the job.

SEND & SHARE
• Generate polished, branded PDF estimates, invoices, and receipts, and send them by
  email or text.

BACKUP AND YOUR GOLD LIFE ID
• Signing in is optional. Skip it and the app works fully — your records simply stay on
  this iPhone with no backup.
• Sign in with Apple or Google from the Gold Life ID card in the Menu and your work
  backs up to your Gold Life account, then follows you to every device you sign in on.
  One account across every Gold Life app.
• Export everything you have, whenever you want, from that same screen.
• Delete on your terms: erase one app's data on its own, or delete your Gold Life ID
  once every app is empty. Deletion is immediate and permanent.

SECURITY
• Lock the app with Face ID (optional).
• Tax IDs (SSN/EIN) stay masked behind Face ID and are never backed up — they stay in
  your iPhone's Keychain.
• A subcontractor's W-9 is encrypted on your iPhone before it is backed up, so the
  stored file cannot be read.

FREE TO START — SUBSCRIBE FOR UNLIMITED
Free to download and use, including up to 10 customers, 2 employees, 2 subcontractors,
and 15 each of estimates, invoices, jobs, and receipts. Subscribe to My Business Pro for
unlimited everything — anything you have already created always stays viewable — read-only —
even without a subscription.

SUBSCRIPTION DETAILS
• My Business Pro — $12.99/month or $89.99/year, charged to your Apple ID at purchase.
• Subscriptions renew automatically unless turned off at least 24 hours before the
  period ends.
• Manage or cancel anytime in your App Store account settings.
• Terms of Use: https://softwarebygl.com/my-business/terms

## Keywords (≤ 100 chars, comma-separated)
contractor,billing,quote,1099,w9,payroll,scheduling,card payments,small business,trades,job site

*(96 chars.* **The v2 line below was 102 — over Apple's 100-char limit, so it was never
stored whole.** *It also spent characters on `estimate`, `invoice` and `receipt`, which
already appear in the subtitle and are indexed from there; Apple's guidance is not to
repeat them. Dropping those three bought room for `w9`, `trades` and `job site`.)*

## Support / Marketing / Privacy URLs
- Support: https://softwarebygl.com/my-business
- Marketing: https://softwarebygl.com/my-business
- Privacy Policy: https://softwarebygl.com/my-business/privacy  (Terms: /my-business/terms)

---

## App Store Connect — what must change for THIS release

### ⚠️ App Privacy label — the release gate (checklist 0.1)
It currently reads **Data Not Collected**. That was true when records lived only in the
user's own iCloud. It is now false: signing in stores business records on Gold Life
servers, keyed to a Gold Life ID. The label must be updated BEFORE this build goes live,
and it is the single most likely thing to draw an App Review question.

Collected and **linked to the user's identity**, all with Purpose = App Functionality and
Used for Tracking = **No**:
- **Contact Info** — name, email, phone, addresses (the user's own business profile, and
  the customers/employees/subcontractors they enter).
- **Financial Info** — estimate, invoice, payment and payroll amounts.
- **User Content** — job notes, documents, receipt photos, signatures.
- **Identifiers** — the Gold Life ID (a user ID).

Notes worth keeping straight while filling it in:
- Tax IDs (SSN/EIN) are NOT collected — they never leave the Keychain on the device.
- A W-9 is encrypted on-device before upload. It is still collected; encryption is a
  safeguard, not an exemption, and the questionnaire has no "but it's encrypted" answer.
- Card numbers are still never received by the app — those are entered on Stripe's own
  page, and Stripe's disclosure covers them.

### ⚠️ Export compliance — RE-ANSWER, do not carry v2's answer forward
`ITSAppUsesNonExemptEncryption = NO` was set when the app did nothing but talk HTTPS.
This release adds encryption of user documents (AES-GCM) before upload. That may still
qualify for an exemption, but it is a legal question about YOUR obligations, not a
judgment call to make from a changelog. Confirm the answer with someone qualified before
submitting; do not let the old value ride through on default.

### App Review notes (paste)
"Business records are stored on our own backend (Cloudflare) under the user's Gold Life
ID. Signing in is optional — the app is fully functional signed out, in which case
nothing leaves the device. Account deletion is available in-app on the Gold Life ID
screen and is immediate and permanent, per Guideline 5.1.1(v): the user can erase a
single app's data, or delete the Gold Life ID itself once every app is empty. A full
data export is offered on the same screen.

Card payments use Stripe Connect (the merchant's own Stripe account, direct charges) for
real-world services billed outside the app — not digital content — consistent with
Guideline 3.1.3(e). The app's own subscription remains In-App Purchase (3.1.1). The pay
link appears only on invoices the merchant sends; there is no card form inside the app."

### Unchanged
- **Category:** Business · Productivity.
- **Price:** Free download + My Business Pro subscription. Do NOT set the app to "Paid."

### Screenshots
Reshoot ALL of them via the script before submitting (screenshot↔build parity rule) —
several screens in this release changed, and the Gold Life ID screen is new.

---

# App Store listing — v2.0

Copy to paste into App Store Connect for the **2.0 (build 15)** update, plus the decisions only
you can make (**⟶ DECIDE**). v2 adds Stripe card payments and the Face ID security features.

---

## Name (≤ 30 chars)
**My Business - Evolved by GL**

## Subtitle (≤ 30 chars)
**Estimates, invoices & receipts**

## What's New in This Version (release notes)
Get paid faster. You can now connect your own Stripe account and add a “Pay this invoice” button to
the invoices you send — your customers pay by card, and the money goes straight to your Stripe
account.

Also in this update:
• Optional Face ID app lock, plus Face ID protection on your Tax IDs and your W-9 / 1099 forms and
  year-end export.
• Reliability and polish fixes throughout.

## Promotional text (≤ 170 chars — editable anytime without review)
Run your contracting business from your phone — estimates, invoices, scheduling, payroll, 1099s, and
now card payments, synced privately through your own iCloud. Free to start.

## Description (≤ 4000 chars)
My Business is a professional toolkit for running a small contracting or trades business — built for
the way you actually work: labor and materials together, job after job. Everything syncs privately
through your own iCloud.

CUSTOMERS
• Keep every customer's contact info, addresses, insurance, and full job history in one place.

ESTIMATES
• Build clean, grouped estimates with labor and material line items.
• Set tax (applied only to taxable items), discounts, and a required deposit.
• Add a separate job-site address, and convert an accepted estimate into an invoice in one tap.

INVOICES & PAYMENTS
• Branded invoices with deposit and milestone billing, and every payment logged.
• Get paid by card: connect your own Stripe account and add a “Pay this invoice” button — your
  customers pay by card and the money goes straight to your Stripe account (optional).
• Signature-ready change orders for mid-job scope changes.

SCHEDULING
• A calendar that knows your next open day and every gap, with recurring work that books itself.

CREW & PAYROLL
• Log hours against the job, watch pay accrue toward the next payday, and export a clean year-end CSV.

SUBCONTRACTORS & 1099
• Track owed-vs-paid, watch the $600 threshold automatically, and generate the real IRS Form 1099-NEC.

RECEIPTS
• Scan expense receipts with your camera — the vendor, date, and total file themselves against the job.

SEND & SHARE
• Generate polished, branded PDF estimates, invoices, and receipts, and send them by email or text.

SECURITY
• Lock the app with Face ID (optional). Tax IDs (SSN/EIN) stay masked behind Face ID — required to
  reveal them, generate a W-9 or 1099, or export.

YOUR DATA, YOUR iCLOUD
• Your business data stays in your own private iCloud — no separate account to create. The one
  exception is the optional card-payments feature, which sends an invoice's amount and a short
  description to create your Stripe pay link.

FREE TO START — SUBSCRIBE FOR UNLIMITED
Free to download and use, including up to 10 customers, 2 employees, 2 subcontractors, and 15 each of
estimates, invoices, jobs, and receipts. Subscribe to My Business Pro for unlimited everything —
anything you've already created always stays viewable — read-only — even without a subscription.

SUBSCRIPTION DETAILS
• My Business Pro — $12.99/month or $89.99/year, charged to your Apple ID at purchase.
• Subscriptions renew automatically unless turned off at least 24 hours before the period ends.
• Manage or cancel anytime in your App Store account settings.
• Terms of Use: https://softwarebygl.com/my-business/terms

## Keywords (≤ 100 chars, comma-separated)
estimate,invoice,contractor,receipt,billing,quote,1099,payroll,scheduling,card payments,small business

## Support URL
https://softwarebygl.com/my-business  ⟶ DECIDE (or a dedicated support/contact page)

## Marketing URL (optional)
https://softwarebygl.com/my-business

## Privacy Policy URL  ✅
**https://softwarebygl.com/my-business/privacy**  (Terms: /my-business/terms)

---

## App Store Connect — settings & decisions for this update

- **Category:** Business · Productivity (unchanged).
- **Price:** Free download + My Business Pro subscription (unchanged). Do NOT set the app to "Paid."
- **Screenshots:** upload the new Stripe ad — iPhone 6.9" (`AD-iphone-stripe.png`) and iPad 13"
  (`AD-ipad-stripe.png`), on the Desktop. (Keeping the existing V1 shots is fine; add the Stripe one.)
- **⚠️ App Privacy (Nutrition Label) — must change from "Data Not Collected."** v2 sends payment data
  to the Gold Life payment backend + Stripe when a user turns on card payments. See the go-live
  handoff on the Desktop for the exact questionnaire answers. Short version:
    - Data Collected: **Yes**.
    - **Financial Info → Other Financial Info** (invoice amount/currency sent to create the pay link):
      Purpose = App Functionality · Linked to identity = No · Used for tracking = No.
    - **User Content → Other User Content** (the invoice description on the link): same three answers.
    - Card numbers are entered on Stripe's own page and are never received by the app — Stripe's own
      privacy disclosure covers those.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = NO` already set — nothing to answer.
- **App Review notes (worth adding):** "Card payments use Stripe Connect (the merchant's own Stripe
  account, direct charges) for real-world services billed outside the app — not digital content —
  consistent with Guideline 3.1.3(e). The app's own subscription remains In-App Purchase (3.1.1).
  The pay link appears only on invoices the merchant sends; there is no card form inside the app."
