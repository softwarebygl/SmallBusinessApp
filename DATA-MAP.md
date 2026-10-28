# Phase 0 Data Map — the CloudKit exit's inventory

Status: **complete, 2026-08-21.** Audited all 23 `@Model` classes against `GLSchemaV1.models`
(GLSchema.swift). This is the closed denominator for the platform migration
(`~/Documents/Github/claude/docs/GoldLife-Platform-Architecture.md`, Phase 0): every stored
property classified, every blob inventoried, every iCloud-promise string enumerated. Phase 4's
checkpoint is list 3 reaching zero.

**Denominators: 369 stored properties · 20 `Data` blobs · 11 in-app iCloud-promise strings.**
**⚠️ STALE since 2026-09-01:** that day added ~50 columns (eight `Address` flat-column sets,
certificate-expiry dates, `Subcontractor.coiData`, `UserProfile.useMyNameInEmails`,
`Estimate.combineTotals`) — the per-model rows below are patched as touched, but the census
denominators need a full re-count before the next audit leans on them.

## ⚠️ Decisions surfaced by this audit

1. **`Subcontractor.w9Data` (blob #18) — CLOSED 2026-08-21 (decision #12, architecture doc).**
   It is the sub's uploaded W-9 PDF, and line 4 of a W-9 *is* their SSN or EIN — so it must NOT
   land in R2 as an ordinary document, and device-only was rejected as a regression (CloudKit
   syncs it today). Ratified: **envelope encryption keyed to Gold Life ID** — client encrypts
   before upload, ciphertext in R2, per-business document key held by gl-id and released on
   authentication. Any device that signs in gets everything; no single-store breach yields a
   readable document. Applies to every future `pii_class='tax'` blob.
2. **`Subcontractor.tinKey` MUST migrate byte-for-byte.** It is the Keychain join key
   (`SecureTINStore.subcontractorAccount(_:)`), not a TIN. Dropped or regenerated, every
   subcontractor TIN in the Keychain is orphaned. There is no plaintext fallback for subs.
3. **`BusinessProfile.w9TIN` legacy plaintext — HANDLED 2026-08-21.** `LegacyTINDrain` (in
   `Models/SyncIdentity.swift`, runs at launch) moves any surviving plaintext TIN into the
   Keychain (or purges it when the Keychain already holds a newer value) so a plaintext SSN/EIN
   no longer rides through CloudKit. The field stays in the schema (additive rule) but should be
   empty everywhere; the server migration must still treat it as NEVER-SYNCS.

---

## 1. Sensitivity map — 369 stored properties across 23 models

Every model carries `syncID: UUID?` and `updatedAt: Date?` (Phase 0 sync-identity scaffolding);
both are NORMAL everywhere and counted in each model's total.

### BusinessProfile — 66 properties (`Models/BusinessProfile.swift`)

| Class | Properties |
|---|---|
| **NEVER-SYNCS** | `w9TIN` (drained at launch by `LegacyTINDrain`; keep out of the server) |
| **PII** | `businessName`, `ownerFirstName`, `ownerLastName`, `phone`, `email`, `address`, `w9Name`, `logoData`, `logoDataDark`, `proofOfInsuranceData`, `proofOfInsuranceName`, `wcInsuranceData`, `wcInsuranceName`, `wcExemptionData`, `wcExemptionName`, `licenseDocumentData`, `licenseDocumentName`, `ownerReferenceCOIData`, `ownerReferenceCOIName` |
| **NORMAL** | `syncID`, `updatedAt`, `websiteURL`, `reviewsURL`, `includeReviewLinkOnReceipts`, `licenseNumber`, `showLogoOnDocuments`, `showAddressOnDocuments`, `lastInvoiceNumber`, `lastEstimateNumber`, `estimateMessageSubject`, `messageIntro`, `messageClosing`, `invoiceMessageSubject`, `invoiceMessageIntro`, `invoiceMessageClosing`, `receiptMessageSubject`, `receiptMessageIntro`, `receiptMessageClosing`, `changeOrderMessageSubject`, `changeOrderMessageIntro`, `changeOrderMessageClosing`, `packageMessageSubject`, `packageMessageIntro`, `packageMessageClosing`, `completionMessageSubject`, `completionMessageIntro`, `completionMessageClosing`, `workScheduleData`, `warrantyText`, `w9TaxClassificationRaw`, `w9LLCClassification`, `w9OtherClassification`, `w9TINTypeRaw`, `w9ExemptPayeeCode`, `w9FATCACode`, `coiHolderOffsetX`, `coiHolderOffsetY`, `coiHolderBoxWidth`, `coiCoverExistingHolder`, `stripeConnectedAccountId`, `stripeChargesEnabled`, `stripeAccountClaim`, `payLinkInclusionRaw`, `payLinkDefaultOn`, `paymentProcessors` |

- `businessName` is PII in the sole-proprietor case (it is a person's legal name for most users).
- `w9TINTypeRaw` is SSN-vs-EIN metadata, not the identifier — NORMAL.
- The five compliance blobs embed the business's legal name and address.

### ChangeOrder — 12 (`Models/ChangeOrder.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `number`, `title`, `createdAt`, `note`, `statusRaw`, `taxRatePercent`, `appliedToInvoice`, `invoice`, `invoiceGroup`, `lineItems` |

### ChangeOrderLineItem — 10 (`Models/ChangeOrder.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `name`, `details`, `quantity`, `unit`, `unitPrice`, `isTaxable`, `sortIndex`, `changeOrder` |

### Customer — 24 (`Models/Customer.swift`)

| Class | Properties |
|---|---|
| **PII** | `firstName`, `middleName`, `lastName`, `email`, `phoneNumber`, `officePhone`, `businessName`, `address`, `profileImageData`, `coiData`, `coiName`, `wcCoiData`, `wcCoiName` |
| **NORMAL** | `syncID`, `updatedAt`, `createdAt`, `packageDocuments`, `estimates`, `invoices`, `receipts`, `timeEntries`, `subPayments`, `scheduledJobs`, `projects` |

- `address` is the Codable `Address` struct — one stored property, five PII sub-fields
  (`street1`, `street2`, `city`, `state`, `postalCode`).
- COI blobs name the customer as certificate holder (their name + address inside the file).

### CustomerDocument — 6 (`Models/CustomerDocument.swift`)

| Class | Properties |
|---|---|
| **PII** | `data`, `name` |
| **NORMAL** | `syncID`, `updatedAt`, `createdAt`, `customer` |

- Free-form GC-requested uploads (OSHA cards, signed vendor agreements, bonding letters) —
  unbounded contents, routinely carry names and signatures.

### Employee — 18 (`Models/Employee.swift`)

| Class | Properties |
|---|---|
| **PII** | `firstName`, `lastName`, `email`, `phone`, `profileImageData` |
| **NORMAL** | `syncID`, `updatedAt`, `payType`, `hourlyRate`, `annualSalary`, `payFrequency`, `anchorPayday`, `hireDate`, `isActive`, `notes`, `createdAt`, `timeEntries`, `paychecks` |

- Compensation fields are NORMAL by the three-bucket rule but should be restricted-access in
  the server model.
- **No SSN field exists today** (W-4/I-9/SSN deferred to Phase B). When it lands it goes
  straight to Keychain, never to a column.

### Estimate — 25 (`Models/Estimate.swift`)

| Class | Properties |
|---|---|
| **PII** | `customerFirstName`, `customerLastName`, `customerBusinessName`, `customerEmail`, `customerPhone`, `customerAddress`, `serviceAddress` |
| **NORMAL** | `syncID`, `updatedAt`, `number`, `jobTitle`, `createdAt`, `validUntil`, `status`, `customer`, `taxRatePercent`, `discountType`, `discountValue`, `depositType`, `depositValue`, `customerNotes`, `terms`, `groups`, `scheduledJobs`, `combineTotals` |

- The customer snapshot is frozen at creation and duplicates `Customer` PII. Deleting a
  `Customer` does **not** erase these copies — an erasure request must sweep every estimate and
  invoice snapshot too.

### EstimateGroup — 7 (`Models/Estimate.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `name`, `note`, `sortIndex`, `estimate`, `lineItems` |

### EstimateLineItem — 13 (`Models/Estimate.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `name`, `details`, `quantity`, `unit`, `unitPrice`, `kind`, `isTaxable`, `sortIndex`, `discountType`, `discountValue`, `group` |

### Invoice — 38 (`Models/Invoice.swift`)

| Class | Properties |
|---|---|
| **PII** | `customerFirstName`, `customerLastName`, `customerBusinessName`, `customerEmail`, `customerPhone`, `customerAddress`, `serviceAddress` |
| **NORMAL** | `syncID`, `updatedAt`, `number`, `jobTitle`, `createdAt`, `dueDate`, `paymentTerms`, `status`, `customer`, `sourceEstimateNumber`, `taxRatePercent`, `discountType`, `discountValue`, `customerNotes`, `terms`, `amountDueNow`, `amountDueDetail`, `stripeAppInvoiceId`, `includePayLink`, `stripePaymentLinkId`, `stripePaymentLinkURL`, `stripePaymentLinkAmountCents`, `stripePayLinkStatusRaw`, `stripePayLinkMintCount`, `stripePaymentLinkMintedAt`, `changeOrderNumberSeed`, `groups`, `payments`, `changeOrders`, `scheduledJobs`, `job` |

### InvoiceGroup — 8 (`Models/Invoice.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `name`, `note`, `sortIndex`, `invoice`, `changeOrder`, `lineItems` |

### InvoiceLineItem — 14 (`Models/Invoice.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `name`, `details`, `quantity`, `unit`, `unitPrice`, `kind`, `isTaxable`, `sortIndex`, `fromChangeOrder`, `discountType`, `discountValue`, `group` |

### InvoicePayment — 11 (`Models/Invoice.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `amount`, `date`, `method`, `note`, `processorName`, `processorFeePercentSnapshot`, `processorFlatFeeSnapshot`, `stripePaymentLinkId`, `invoice` |

- The three `processor*` fields are retired inputs still read by Statistics — migrate, don't drop.

### JobAttachment — 8 (`Models/JobAttachment.swift`)

| Class | Properties |
|---|---|
| **PII** | `data`, `caption`, `name` |
| **NORMAL** | `syncID`, `updatedAt`, `createdAt`, `kindRaw`, `job` |

- Proof-of-work photos are pictures of a customer's property; captions/names reference the site.

### Paycheck — 11 (`Models/Employee.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `payPeriodStart`, `payPeriodEnd`, `payDate`, `grossAmount`, `hoursPaid`, `method`, `note`, `employee`, `coveredEntries` |

### PaymentProcessor — 7 (`Models/PaymentProcessor.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `name`, `feePercent`, `flatFee`, `createdAt`, `businessProfile` |

- Retired/dormant model kept for schema compatibility. Still holds live user rows — migrate it.

### Project — 8 (`Models/Project.swift`)

| Class | Properties |
|---|---|
| **PII** | `masterAgreementData`, `masterAgreementName` |
| **NORMAL** | `syncID`, `updatedAt`, `name`, `createdAt`, `customer`, `jobs` |

- The master agreement is a **signed** contract — handwritten signatures, both parties' details.

### Receipt — 12 (`Models/Receipt.swift`)

| Class | Properties |
|---|---|
| **PII** | `scanData`, `recognizedText` |
| **NORMAL** | `syncID`, `updatedAt`, `vendor`, `date`, `total`, `category`, `notes`, `createdAt`, `customer`, `job` |

- `recognizedText` is raw OCR of the whole receipt: commonly captures card last-four, cardholder
  name, store address. Treat both as PII.

### ScheduledJob — 26 (`Models/ScheduledJob.swift`)

| Class | Properties |
|---|---|
| **PII** | `customerName`, `serviceAddress` |
| **NORMAL** | `syncID`, `updatedAt`, `title`, `startDate`, `durationDays`, `notes`, `createdAt`, `statusRaw`, `completedAt`, `agreedPrice`, `isAllDay`, `startTime`, `durationMinutes`, `recurrenceFrequencyRaw`, `recurrenceWeekdayMask`, `recurrenceEndDate`, `recurrenceCount`, `customer`, `estimate`, `invoice`, `project`, `billingInvoices`, `receipts`, `attachments` |

- `customerName` is a deliberate snapshot that survives customer deletion — erasure-sweep target.

### SubPayment — 10 (`Models/Subcontractor.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `amount`, `hours`, `date`, `paidDate`, `method`, `detail`, `subcontractor`, `customer` |

### Subcontractor — 18 (`Models/Subcontractor.swift`)

| Class | Properties |
|---|---|
| **PII** | `firstName`, `lastName`, `businessName`, `email`, `phone`, `address`, `profileImageData`, `w9Name`, `w9Data` |
| **NORMAL** | `syncID`, `updatedAt`, `hourlyRate`, `isActive`, `notes`, `createdAt`, `tinKey`, `w9TINTypeRaw`, `payments` |

- **`w9Data` residency: CLOSED — envelope encryption keyed to Gold Life ID** (decision #12; see
  the top of this file) — the blob contains the sub's SSN/EIN.
- **`tinKey` is the Keychain join key** and must migrate byte-for-byte or every sub's TIN in
  the Keychain is orphaned.

### TimeEntry — 10 (`Models/Employee.swift`)

| Class | Properties |
|---|---|
| **NORMAL** | `syncID`, `updatedAt`, `date`, `hours`, `note`, `rateSnapshot`, `amount`, `employee`, `customer`, `paycheck` |

### UserProfile — 8 (`Models/UserProfile.swift`)

| Class | Properties |
|---|---|
| **PII** | `firstName`, `lastName`, `email`, `phone`, `photoData`, `signatureData` |
| **NORMAL** | `syncID`, `updatedAt` |

- `signatureData` is the owner's handwritten signature — the highest-value PII item after the
  TINs; a leaked signature image is directly forgeable onto documents.

### Sensitivity totals

| Class | Count |
|---|---|
| NEVER-SYNCS | **1** (`BusinessProfile.w9TIN`, drained) |
| PII | **62** |
| NORMAL | **306** |
| **Total** | **369** |

Plus 2 Keychain-resident TIN stores that are not stored properties: the business TIN and one
item per subcontractor with a non-empty `tinKey`.

---

## 2. Blob inventory — 20 `Data`-typed stored properties

19 of 20 use `@Attribute(.externalStorage)`; the exception is noted.

| # | Model | Property | Holds | Size expectation |
|---|---|---|---|---|
| 1 | BusinessProfile | `logoData` | Light/default company logo | 50 KB – several MB (user-picked, never downscaled) |
| 2 | BusinessProfile | `logoDataDark` | Dark-appearance logo variant | same |
| 3 | BusinessProfile | `workScheduleData` | JSON-encoded `WorkSchedule` struct, not a file | < 5 KB |
| 4 | BusinessProfile | `proofOfInsuranceData` | Retired GL COI (PDF/image) | 100 KB – 5 MB |
| 5 | BusinessProfile | `wcInsuranceData` | Retired workers' comp COI | 100 KB – 5 MB |
| 6 | BusinessProfile | `wcExemptionData` | WC exemption certificate (PDF) | 100 KB – 5 MB |
| 7 | BusinessProfile | `licenseDocumentData` | Contractor/business license | 100 KB – 5 MB |
| 8 | BusinessProfile | `ownerReferenceCOIData` | Owner's blank reference COI | 100 KB – 5 MB |
| 9 | Customer | `profileImageData` | Customer avatar | 100 KB – several MB |
| 10 | Customer | `coiData` | Per-customer GL COI | 100 KB – 5 MB |
| 11 | Customer | `wcCoiData` | Per-customer WC COI | 100 KB – 5 MB |
| 12 | CustomerDocument | `data` | Arbitrary package extra | 100 KB – 10 MB+, unbounded |
| 13 | Employee | `profileImageData` | Employee avatar | 100 KB – several MB |
| 14 | JobAttachment | `data` | Proof-of-work photo or job document | **2–5 MB typical per photo; dominates total volume** |
| 15 | Project | `masterAgreementData` | Signed master agreement | 1–20 MB, largest single document |
| 16 | Receipt | `scanData` | VisionKit scan, compressed | 100–500 KB |
| 17 | Subcontractor | `profileImageData` | Subcontractor avatar | 100 KB – several MB |
| 18 | Subcontractor | `w9Data` | **Sub's W-9 PDF — contains their SSN/EIN** | 50 KB – 2 MB |
| 19 | UserProfile | `photoData` | Owner's profile photo | 100 KB – several MB |
| 20 | UserProfile | `signatureData` | Owner's signature PNG | < 100 KB |

R2 notes:
- **#14 dominates volume** — unbounded cardinality per job, full-resolution photos. Budget first.
- **#3 does NOT go to R2** — it is the one non-externalStorage blob, a serialized value object;
  it belongs in the row as structured data.
- **#4/#5 are retired but non-empty** — invisible in the UI, still hold real user files, must
  be carried across.
- **Companion `name` strings** (9 of them) must ride as metadata beside the content hash or
  users lose every document's label.

---

## 3. iCloud-promise strings — 11 in-app, Phase 4 target: zero

Each Swift string has a matching key in `Localizable.xcstrings` (both change together, each with
up to 6 translations that go stale).

| # | File | Line | String (abbreviated) |
|---|---|---|---|
| 1 | AccessControl/GoldLifeIDPrompt.swift | 189 | "…Your business data stays exactly where it is — on your iCloud…" |
| 2 | AccessControl/GoldLifeIDViews.swift | 30 | "…it stays on your iCloud." |
| 3 | AccessControl/GoldLifeIDViews.swift | 78 | "…doesn't move your data — it stays on your iCloud…" |
| 4 | AccessControl/GoldLifeIDViews.swift | 81 | "…Your business data stays on your iCloud…" |
| 5 | AccessControl/GoldLifeIDViews.swift | 93 | "…everything in your iCloud — is not affected…" |
| 6 | Screens/InsuranceDocuments.swift | 188 | "…Stored privately in your iCloud account." |
| 7 | Screens/SignatureEditorSheet.swift | 60 | "Stored privately in your iCloud account and protected by Face ID…" |
| 8 | Screens/IPadRootSplitView.swift | 47 | "Turn on iCloud to back up your work" |
| 9 | Screens/IPadRootSplitView.swift | 50 | "You're not signed in to iCloud, so your business info is saved on this device only…" |
| 10 | Screens/SettingsScreen.swift | 149 | "…Your data stays encrypted on your device either way." (no "iCloud" — easy to miss) |
| 11 | Localizable.xcstrings | 9866 | "Private sync through your own iCloud" — **orphan**, delete outright |

Catalog keys: lines 125, 104, 101, 140, 149, 13318, 11869, 12998, 13859, 10544, 9866.

Notes:
- **#8/#9 are the whole no-iCloud-account flow** (iPad root only, `hasShownNoICloudNotice`) —
  under server sync the premise disappears: delete the feature, not the copy.
- **Keychain promises that stay TRUE and must NOT be reworded:** MenuScreen.swift:728 and
  SubcontractorFormScreen.swift:191 ("…stored securely in your Keychain, not the synced
  database…") — they remain the user-facing statement of the TIN policy.
- **Not a promise, no change:** PhotoLoadAlert.swift:20 (user's Photos library).

Out-of-app, same Phase 4 sweep (12 statements, not counted above): `PrivacyPolicy-DRAFT.md`
(6, incl. "No other third parties receive your data" — false once R2/Cloudflare is in the
path), `AppStore-Listing-DRAFT.md` (4, incl. the "YOUR DATA, YOUR iCLOUD" section), `README.md`
(2).

**Phase 4 checkpoint:** `grep -rniE "icloud" --include="*.swift" --include="*.xcstrings"
GLSmallBusiness/` must leave only: the container id in CloudKitSchemaInit.swift, the iCloud-
*Keychain* comments in SecureTINStore/StripeInstallTokenStore, PhotoLoadAlert's Photos-library
line, and nothing else.
