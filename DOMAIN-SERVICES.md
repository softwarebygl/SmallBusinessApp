# Services/Domain — the one write path

(This map lives at the repo root, not in `GLSmallBusiness/Services/Domain/`: that folder is a
synchronized group, so a file there would be copied into the app bundle.)

Every write in My Business goes through a service in this folder. The screens call them, and
the assistant's tools will call the same ones (law 58: "same code as the buttons"; Zero
Duplication). A tool never writes a model directly.

## What every service does

- **Gate:** `DomainGate.requireWritable(op)` for the write's own `MBWriteOperation` (lapsed or
  offline refuses; sample mode never does). Creates also run `DomainGate.requireCanCreate` with
  the `FreeTier` cap (`AccessGate.decide`).
- **Liveness:** `DomainGate.requireLive` refuses a record that was deleted under the caller.
- **Validation:** money, rates, hours and quantities are finite and ≥ 0; percentages are 0–100;
  required fields are present.
- **Origin (`WriteOrigin`, default `.tool`):** a screen passes `origin: .screen` where it has
  always been lenient with values that can only come from stored data — discount and deposit
  percentages over 100 (estimates, invoices, price items; the totals clamp them — a tax rate is
  never clamped, so every origin is refused past 100), an ordinary negative-price line on a job's
  first invoice (how the carry held a change-order credit before 2026-09-22; the carry now keeps
  `fromChangeOrder`), a negative job price or receipt total, a Stripe
  link id on a payment, and delete cascades over the Worker's 500-row cap. A tool gets every
  refusal.
- **Paid lock:** `Invoice.isMoneyLocked`, `Customer.hasPaidInvoice` and
  `ChangeOrder.isBilledToLockedInvoice` refuse with `.paidLocked`.
- **Minimal writes:** `setIfChanged` and `RowReconciler`. Rows are read through `liveRows`.
  Numbers are minted only through `nextNumber`.
- **Deletes:** only through `DeletionService`, which uses `deleteSynced`.
- **Save:** `context.saveChanges()` ends every successful write. It mints the `syncID` and
  persists the queued sync op.
- **Errors:** refusals throw `DomainError`. `code` is the stable name a tool returns, and
  `errorDescription` is the EN/ES text a person sees. Refusals are also logged to OSLog
  (`Logger.domain`), with the operation and code only. A screen shows an unexpected refusal
  with `DomainError.present` and `.domainErrorAlert`.

Screens keep their own `ReadOnlyGate.allows(_:into:)` check and their paid-lock pre-checks when
those drive an alert, then call the service. The service repeats the check, so a tool gets the
same refusal.

## Service map

Format: `method` → the UI call sites that use it (paths relative to `GLSmallBusiness/`).
"Tool only" means no screen calls it yet; it exists so a tool has the same rule.

### DeletionService — every delete
Kinds: `customer, estimate, invoice, change_order, job, receipt, price_item, employee,
subcontractor, project, time_entry, paycheck, sub_payment, attachment, document` (`payment` always
refuses: payments are append-only).

- `delete(_ targets: [Target], evenIfItemsUnmatched: Bool = true, origin: WriteOrigin = .tool, in:subscription:) throws -> Outcome`
  (every screen passes `.screen` and drops rows a sync already removed before calling)
  - Customers: CustomersScreen `deleteThroughService` (swipe + bulk); IPadRootSplitView customer column `delete`.
  - Invoices: InvoicesListScreen `deleteThroughService` (swipe + bulk); AllInvoicesScreen `delete`.
  - Estimates: EstimatesListScreen `deleteThroughService` (swipe + bulk); AllEstimatesScreen `delete`.
  - Jobs: JobDetailScreen (Delete job alert); JobsListScreen `delete`; AllJobsScreen `delete`.
  - Job and invoice photos and documents: JobDetailScreen `delete(_ attachment:)`; InvoiceDetailScreen `delete(_ attachment:)`.
  - Projects: ProjectScreens (the detail screen's Delete project, and the All Projects swipe).
  - Employees: EmployeesScreen `delete`; IPadRootSplitView employee column `delete`.
  - Subcontractors: SubcontractorsScreen `delete`; IPadRootSplitView subcontractor column `delete`. The Keychain TIN is cleared first.
  - Time entries and paychecks: EmployeeDetailScreen (the Log Hours, Log Bonus and paycheck sheets).
  - Subcontractor ledger entries: SubcontractorDetailScreen (the entry sheet's Delete).
  - Receipts: ReceiptsListScreen `deleteThroughService` (swipe + bulk).
  - Change orders: ChangeOrderScreens `deleteChangeOrder`; AllChangeOrdersScreen `delete`. Billed items come off the invoice first.
  - Price sheet items: PriceSheetScreen `delete`. Through `deleteSynced` like every record: the Price Sheet is a sync type (`price_sheet_item`) since 2026-10-03 (QA finding F3), so it is backed up and a sign-out wipe no longer loses it.
  - Documents that are their own record (package extras and attachments): `DocumentService.set(_, data: nil)`.
  - Checks, all before anything is written: the gate for each kind's own operation, liveness,
    the paid lock, and — for a tool — at most 500 cascade rows per root (`.tooMuchToDelete`, the
    server's cap).
    A batch is all-or-nothing. A record already inside another root's cascade is dropped, so
    nothing is deleted twice.
  - More than 25 roots is allowed but reported (`Report.tripsOtherDevicesBreaker`), because it
    pauses syncing on the owner's other devices.
- `plan(_ targets:, origin:in:subscription:) throws -> Plan` — tool only (the confirmation step). It runs
  the same checks and changes nothing. It returns `kinds`, `cascadeRows`,
  `tripsOtherDevicesBreaker`, a plain-English `summary` in the screens' own words ("Their
  estimates, invoices, and receipts are removed too. This can’t be undone."), and `effects` — the
  same sentences WITHOUT the closing "This can’t be undone.", for the assistant's alert, which
  says that line itself (law 8).
- `target(kind:id:in:) throws -> Target` — tool only. It finds a record by `syncID`. A `payment`
  refuses with `.paymentsCannotBeDeleted`, and an unknown id refuses with `.recordNotFound`.

### DocumentService — every document slot
Slots: `customerCertificate(customer, .generalLiability | .workersComp)`,
`subcontractorCOI(sub)`, `compliance(.wcExemption | .license)`, `referenceCOI`,
`packageExtra(doc)`, `masterAgreement(project)`, `attachment(jobOrInvoiceAttachment)`. The
subcontractor W-9 is not a slot on purpose (tax data is quarantined).

- `set(_ slot:, data: Data?, name:, profile:in:subscription:)` — upload or replace (`.saveDocument`;
  `.addJobAttachment` for an attachment),
  or remove with `data: nil` (`.deleteDocument`; a slot that is its own record is deleted through
  `DeletionService`).
  CustomerInsurance (GL and WC certificate screens); CustomerDetailScreen (certificate importer);
  ContractorPackage (COI and WC COI importer, and `CustomerDocumentDetailScreen`);
  SubcontractorDetailScreen (`SubcontractorCOIDetailScreen`); InsuranceDocuments (`ComplianceDocsManagerSheet` compliance and
  reference-COI importer, `ComplianceDocDetailScreen`, the reference-COI detail); ProjectScreens
  (master agreement importer); JobDetailScreen (`JobDocumentDetailScreen`, which invoice documents
  also open).
- `setExpiry(_ slot:, _ date: Date?, profile:in:subscription:)` — the "good through" date. Slots
  without an expiry refuse with `.noExpiry`.
  CustomerInsurance ×2; SubcontractorDetailScreen; InsuranceDocuments.
- `addPackageExtra(_:name:to:in:subscription:)` — ContractorPackage `importFile` (extra document).
- `attachDocument(_:name:to: .job | .invoice, in:subscription:)` — JobDetailScreen document importer;
  InvoiceDetailScreen document importer.
- `attachPhotos(_:to: .job | .invoice, in:subscription:)` — JobDetailScreen `addPickedPhotos`;
  InvoiceDetailScreen `addPickedPhotos`.

### CustomerService
- `create` — CustomerFormScreen (Save, new customer).
- `update` — CustomerFormScreen (Save, edit).
- `setPhoto` — CustomerDetailScreen (photo picker / remove).

### EmployeeService
- `create`, `update` — EmployeeFormScreen.
- `setPhoto` — EmployeeDetailScreen.
- `logTime` — EmployeeDetailScreen (Log Hours sheet).
- `logBonus` — EmployeeDetailScreen (Log Bonus sheet).
- `recordPaycheck`, `editPaycheck` — EmployeeDetailScreen (Pay Now / paycheck sheet).

### SubcontractorService (no tax fields)
- `create`, `update` — SubcontractorFormScreen.
- `setPhoto` — SubcontractorDetailScreen.
- `recordEntry` — SubcontractorDetailScreen (Record Amount sheet, create and edit).
- `payNow` — SubcontractorDetailScreen (Pay Now sheet).

### ProjectService
- `createAndAssign` — ProjectScreens (Add to Project sheet).
- `assign` — ProjectScreens; `save_job`'s `project_id` (null takes the job out).
- `rename` — ProjectScreens (Rename alert).

### EstimateService
- `create`, `update` — EstimateFormScreen; the assistant's `create_estimate` / `edit_estimate`.
- `setStatus` — EstimateDetailScreen (status picker); `set_status` kind estimate.
- `existingInvoice`, `convertToInvoice` — EstimateDetailScreen (Convert to invoice);
  `create_invoice` with `from_estimate_id` (`create_another` is the tool's `force`).
- `setValidUntil` — tool only.
- `businessProfile` — internal helper, used by InvoiceService.

### InvoiceService
- `create`, `update` — InvoiceFormScreen; the assistant's `create_invoice` / `edit_invoice`.
  `jobBillingDraft` — InvoiceFormScreen (bill a job) and `create_invoice` with `job_id`.
  `create(job:)` refuses another customer's job. From a tool, change-order rows are read-only:
  a `fromChangeOrder` line or a change-order group must be an unchanged row this invoice already
  has (`.changeOrderLinesReadOnly`) — with ONE allowance, `create(job:)`'s carry: a new billing
  invoice may bring in exactly the `fromChangeOrder` lines `jobBillingDraft(for:)` copies (matched
  by name, quantity, price, tax and discount, counted so the same credit can't be sent twice).
- `recordPayment`, `paymentExceedsBalance` — InvoiceDetailScreen (Record Payment sheet); the
  assistant's `record_payment` (always confirmed, and refused over the balance before anyone is
  asked). From a
  tool, only the invoice's own unclaimed Stripe link id lifts the over-balance refusal.
- `setAmountDue` — InvoiceDetailScreen (Set Amount Due sheet); `edit_invoice` on a PAID invoice
  (lock-exempt, behind a confirmation).
- `setIncludePayLink` — InvoiceDetailScreen (Pay button toggle); `edit_invoice` on a paid invoice.
- `importJobAttachments` — InvoiceDetailScreen (import job photos); `edit_invoice`'s
  `include_from_job`.
- `setStatus` — `set_status` kind invoice. `setPaymentTerms`, `dueDate` — tool only (the tools
  take terms and the due date through the draft).

### ChangeOrderService
- `create`, `update` — ChangeOrderScreens (Change Order form).
- `settleStatusChange` — SCREEN-ONLY: ChangeOrderScreens (status picker, which writes the status
  first). Gated like `setStatus`.
- `applyToInvoice` — ChangeOrderScreens (Add items to invoice); InvoiceDetailScreen.
- `setStatus` — `set_status` kind change_order (the picker goes through `settleStatusChange`).

### JobService
- `create`, `update`, `proposal` — JobFormScreen; the assistant's `save_job`.
- `schedule` — ScheduleJobSheet; `save_job` with `from_estimate_id` (accepted only, as the
  estimate screen's Schedule is) or `from_invoice_id`.
- `setStatus` — JobDetailScreen (status control); `set_status` kind job (Undo passes the original
  `completedAt` back, so the warranty clock isn't restarted).

### JobScheduling (reads)
- `overlaps(rule:)` — JobFormScreen, ScheduleJobSheet and a tool all ask `.full` (the only rule;
  time windows, 120 days back).
- `jobs`, `expanded`, `expandedJobs`, `jobsByDay`, `upcoming`, `openings`, `nextAvailable`,
  `horizon`, `clearDate`, `hasOpenEndedRecurrence`, `schedule` — reads for the calendar and tools.

### ReceiptService
- `create`, `update`, `prefill`, `read`, `photoData` — ReceiptFormScreen.
- `setScan` — tool only.

### PriceSheetService
- `create`, `update` — PriceSheetItemFormScreen.
- `search`, `grouped`, `sortedCategories` — PriceSheetScreen.
- `ensureID`, `groupName` — tool only.

### BusinessProfileService
- `updateDetails` — MenuScreen (My Business Details).
- `updateDocumentMessages` — DocumentSettingsScreen.
- `setDisplay`, `setEmailSignatureText` — SettingsScreen (the text field writes with
  `saveNow: false` and saves when editing ends).
- `setPayLinkDefault` — StripeConnectScreen (Pay button on new invoices).
- `setLogo` — tool only.
- `ModelContext.writableBusinessProfile` — internal helper; the profile every profile write (and
  DocumentService's compliance slots) lands on.

### AppSettingsService
- `setAppearance` — AppearanceScreen. `setLanguage` — LanguageScreen.
- `setUseCompanyLogo`, `setOneJobAtATime` — SettingsScreen.
- `useCompanyLogo`, `oneJobAtATime` — reads.

### WorkScheduleService
- `save` — WorkScheduleScreen.
- `setWeekday`, `setHoliday`, `addDayOff`, `addTimeOff`, `addOverride`, `removeEntry`,
  `current`, `minutes` — tool only (one change at a time).

### SendPreparer (no writes except the pay link)
- `estimate` — EstimateDetailScreen. `changeOrder` — ChangeOrderScreens.
- `invoice`, `invoiceFileURLs`, `currentPayLinkURL`, `payLinkPlan`, `mintPayLink`,
  `paymentReceipt` — InvoiceDetailScreen.
- `invoiceMailAttachments`, `payLinkDescription` — helpers.

### MoneyLockPreview (reads)
- `discountZeroesDocument` — UIComponents/ZeroingDiscountGuard.
- `wouldLock`, `isPaid`, `totals` — tool only (warns before a write that would lock an invoice).
  `wouldLock(_:applying:)` guards `edit_invoice`, `wouldLock(_:status:)` guards `set_status` on an
  invoice, `wouldLock(removing:)` guards moving an ADDED change order off Approved (its items come
  off, which can leave the invoice paid), and `wouldLock(applying:)` guards the Undo that puts them
  back. Each one asks the person first; a confirmed write keeps no Undo.

### Foundations
- `DomainGate` (`requireWritable`, `requireCanCreate`, `requireLive`, `requireNonNegative`,
  `requirePercent`, `refusal`), `WriteOrigin`, `DomainMoney`, `DomainSyncIdentity.ensure` (mints a
  `syncID` for a record a tool hands out; saves it unless the app is read-only), `DomainError`, `DomainErrorAlert`.
- Drafts: `CustomerDraft`, `EmployeeDraft`, `SubcontractorDraft`, `EstimateDraft`,
  `InvoiceDraft`, `ChangeOrderDraft`, `JobDraft`, `ReceiptDraft`, `PriceItemDraft`,
  `BusinessDetailsDraft`, `DocumentMessagesDraft`, `LoggedWork`.

## The assistant's read tools (`GLSmallBusiness/AI/`)

`find`, `get`, `report` and `help` write nothing (the one exception: an id is minted, through
`DomainSyncIdentity.ensure` / `PriceSheetService.ensureID`, for a row that has none). They read
through the same code the screens use:

- Lists and filters: the models' `matchesSearch`, `PriceSheetService.search` / `groupName`, the
  Jobs and Receipts screens' search fields, derived statuses (`isPaid`, `isOverdue`, `isExpired`).
- Totals and balances: the models' computed money (`totals`, `balanceDue`, `accruedGross`,
  `outstanding`, the job billing roll-ups). `EstimateService.existingInvoice` for "converted to".
- Money over a period: `StatsEngine.summary` with `StatsPeriod.days(from:to:)` (any span of whole
  days, inclusive).
- Schedule: `ScheduleQueries` / `SchedulingEngine` (`expand`, `openings`, `nextAvailable`,
  `clearDate`, `hasOpenEndedRecurrence`) and `WorkScheduleService.current`.
- Certificates: `GLCertificateStatus`. Card payments: `StripeBackendClient.payLinkStatus` (read).
- Record lookup by id: `GLSyncRegistry.entry(for:).fetch` (the same fetch `DeletionService.target`
  uses); price items by `syncID`.

## The assistant's core write tools (`GLSmallBusiness/AI/`)

Each tool is a thin wrapper: it reads the model's arguments (an amount must be whole cents: one
with a fraction of a cent is refused with `invalid_arguments` by `MBWholeCentsGate` before the tool
runs, law 60), builds the SAME draft the form holds, and calls the service below with
`origin: .tool`. Nothing here touches a `@Model` directly.

| Tool | Service call(s) | Asks the person first |
|---|---|---|
| `save_customer` | `CustomerService.create` / `update` | no |
| `create_estimate` / `edit_estimate` | `EstimateService.create` / `update` | no |
| `create_invoice` | `EstimateService.convertToInvoice`, `InvoiceService.create` (+ `update` for extra fields) | only if it would start out paid |
| `edit_invoice` | `InvoiceService.update`, or on a paid invoice `setAmountDue` / `setIncludePayLink` / `importJobAttachments` | any write to a paid invoice, and any edit that would make it read Paid |
| `set_status` | `EstimateService.setStatus`, `InvoiceService.setStatus`, `ChangeOrderService.setStatus`, `JobService.setStatus` | when the change would make an invoice read Paid |
| `save_job` | `JobService.create` / `schedule` / `update`, `ProjectService.assign`, `JobScheduling.overlaps` (report only) | no |
| `record_payment` | `InvoiceService.recordPayment` | always |
| `delete` | `DeletionService.plan`, then `delete` | always |

## The assistant's area write tools (`GLSmallBusiness/AI/`)

| Tool | Service call(s) | Asks the person first |
|---|---|---|
| `save_change_order` | `ChangeOrderService.create` / `update` | any write to or under a money-locked invoice |
| `apply_change_order` | `ChangeOrderService.applyToInvoice` (guarded by `MoneyLockPreview.wouldLock(applying:)`) | when it would make the invoice read Paid |
| `save_receipt` | `ReceiptService.create` / `update` | no |
| `save_price_item` | `PriceSheetService.create` / `update` | no |
| `save_employee` | `EmployeeService.create` / `update` | no |
| `log_time` | `EmployeeService.logTime` / `logBonus` | no |
| `pay_employee` | `EmployeeService.recordPaycheck` | always |
| `edit_paycheck` | `EmployeeService.editPaycheck` | always |
| `save_subcontractor` | `SubcontractorService.create` / `update` (never a tax field) | no |
| `log_sub_work` | `SubcontractorService.recordEntry` | when the work is recorded as already paid |
| `pay_subcontractor` | `SubcontractorService.payNow` | always |
| `update_business` | `BusinessProfileService.updateDetails` / `updateDocumentMessages` | contact details, message wording and the reviews link, with old → new |
| `update_work_schedule` | `WorkScheduleService.setWeekday` / `setHoliday` / `addTimeOff` / `addDayOff` / `addOverride` / `removeEntry` | no |
| `update_app_settings` | `AppSettingsService` (language, appearance, one-job, logo-in-app) + `BusinessProfileService.setDisplay` / `setEmailSignatureText` / `setPayLinkDefault` | no |
| `save_project` | `ProjectService.createAndAssign` / `assign` / `rename` | no |
| `set_document` | `DocumentService.setExpiry`, or `DocumentService.set(_, data: nil)` to remove | always, to remove |

## The assistant's hand-offs (`GLSmallBusiness/AI/`)

These write nothing themselves. The tool checks its target exists and returns `.handoff`;
`MBAIHandoffPresenter` shows the UI and the loop waits for the real outcome (contract A5).

| Tool | What the presenter shows | What it writes |
|---|---|---|
| `open` | a push onto the assistant's own stack (`MBAssistantDestination`), or the legal sheets | nothing |
| `send` | `MailComposeView` / `MessageComposeView` / `UIActivityViewController`, filled by `SendPreparer` and the PDF renderers | the invoice's pay link (`SendPreparer.mintPayLink`), fail-open |
| `share_document` | `UIActivityViewController` over `W9PDF`, `Form1099NECPDF`, `StatsExport`, `EmployeePayExport`, `SubPayExport` or a stored file | nothing |
| `pick_media` | `PhotosPicker`, `fileImporter`, `DocumentScannerView` or `ContactPickerView` | `MBPickCommit` → `ReceiptService`, `DocumentService`, `CustomerService.setPhoto`, `EmployeeService.setPhoto`, `SubcontractorService.setPhoto`, `BusinessProfileService.setLogo`, or a `create` from a phone contact |
| `save_to_contacts` | `NewContactView` (the system new-contact card) | nothing — the person taps Done |
| `contact_developer` | `MailComposeView` to the app's support address | nothing |

Undo (`GLAIUndo`, the latest request only) re-enters the same services: a create is undone with
`DeletionService`, an edit by saving the "before" draft back with `origin: .screen` (those values
are the record's own stored ones). An entry is DROPPED when money landed on the invoice after the
write or it became money-locked, and SKIPPED when the record moved since — measured by
`MBFingerprint` (the record's and its rows' `updatedAt`) against what the conversation's ledger
last wrote, so an earlier create can still be undone after a later edit. Confirmed changes
(deletes, recorded money, a lock flip) keep no Undo at all.

## Not here, on purpose

- Tax IDs and W-9s (the business TIN, subcontractor TINs, the uploaded subcontractor W-9) stay in
  their screens, behind Face ID and the Keychain. No service, and so no tool, reads or writes them.
- `UserProfile` (Gold Life ID) is never written here.
