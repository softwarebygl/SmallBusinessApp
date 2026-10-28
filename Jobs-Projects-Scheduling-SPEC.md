# GL Business — Jobs, Projects & Scheduling Blueprint

**Owner:** Adrian Gutierrez / Gold Life LLC (DBA Evolved by GL)
**Status:** Approved design, not yet built. Build blueprint for the next major feature set.
**Decided:** 2026-06-24 (captures the full design conversation). Code references verified against the
repo the same day.

> **Release context.** The app is mid-resubmission as **v1.0 (build 5)** after the Apple rejection (see
> `TODO.md`; the CloudKit production schema deploy is still a pending owner action). Everything here
> lands in the release(s) **after** that resubmit, **staged** (see §9). The SwiftData schema must be
> treated as shipped → every change is **additive** (see §1.0).

> **Cross-references use section names** (not just numbers) — the numbers shifted during drafting. If you
> renumber, keep the names.

---

## 0. The problem this fixes — "un-blurring"

Today estimates and invoices are blurred with the idea that they *become* jobs. In code there is **no
Job entity at all**: a "job" is only `ScheduledJob` (`Models/ScheduledJob.swift`) — a thin calendar
booking that **cannot exist** without an estimate or invoice behind it. The fix: make **Job a
first-class concept and the operational source of truth**, creatable on its own.

### The noun model

| Noun | Role |
|---|---|
| **Estimate** | A proposal. Editable, pre-commitment. Once accepted, it *is* the agreement (no separate "Contract" entity). |
| **Job** | **The source of truth** — the blueprint of the work. The **only schedulable** thing. |
| **Change Order** | Amends the agreed scope/price. **Stays invoice-attached in this release** (re-homing onto the Job is deferred — see §1.6 / §10). |
| **Invoice** | A request for payment against a job (and, via the job, a project). |
| **Receipt** | Proof of payment. |
| **Project** *(optional)* | An **optional** grouping above jobs, invisible until used. Bundles jobs + their invoices + a signed master agreement; rolls up to one total. |

**Why no mandatory "Contract" layer:** the target user is *everyone* — solo cleaner to multi-phase GC. A
required Contract wrapper would punish the simple user (against the Gold Standard: *"with restraint"*).
The **Job is the unit**; the **Project** is opt-in and only appears when reached for.

---

## 1. Data model changes (SwiftData / CloudKit) — all additive

### 1.0 First post-launch schema change — versioning + release-state gate

`GLSchemaV1.models` (`GLSchema.swift:43-65`) points at the **live** `@Model` types, and the container
builds from `Schema(versionedSchema: GLCurrentSchema.self)` (`GLSmallBusinessApp.swift:26`) — there is
**no** hand-kept `Schema([...])` array; the container reads only `GLCurrentSchema.models`.

**Hard gate before touching any `@Model` (owner ticks this):**
> ☐ Has build 5 (or any build carrying `GLSchemaV1`) reached **TestFlight or the App Store** by
> implementation time?
> - **Yes** → this is the first post-launch migration: (1) freeze `GLSchemaV1` to copied launch-shape
>   types; (2) add `GLSchemaV2` snapshotting the new shape; (3) **register every new `@Model`
>   (`Project`, any snapshot model) in `GLSchemaV2.models`** — declaring the `@Model` is not enough,
>   it fails silently at query time; (4) append `.lightweight(fromVersion: GLSchemaV1, toVersion:
>   GLSchemaV2)` to `GLMigrationPlan.schemas`; (5) repoint `GLCurrentSchema` to V2; (6) deploy the new
>   fields/record types to CloudKit **Production**.
> - **No** (not yet released to any user) → may still fold into V1. Getting this wrong corrupts
>   production sync — confirm before starting.

**Additive rules (README §6):** new scalars optional or defaulted; new to-many relationships
`Optional` (`var x: [T]?`, **never** `= []`, per `GLSchema.swift:24-27`); new to-one relationships
optional with explicit inverse and `.nullify` delete rule where a snapshot must survive deletion.

### 1.1 `ScheduledJob` → first-class **Job** (additive promotion)

Relax the "must have a source" invariant **in code only** — `estimate`/`invoice` are *already* optional
(`ScheduledJob.swift:49-50`), so both-nil from-scratch jobs need no schema change. Add (all
optional/defaulted):

- `customer: Customer?` — optional, `.nullify`, inverse `Customer.scheduledJobs: [ScheduledJob]?`
  (mirrors `Customer.swift:44-50`). **Keep** the `customerName` String snapshot (`ScheduledJob.swift:40`).
- `project: Project?` — optional (see §3).
- `statusRaw: String = "scheduled"` → `JobStatus` { scheduled, inProgress, completed }. (Backfill: §1.7.)
- `completedAt: Date?` — **the single canonical completion date** (warranty start + completion package);
  the Invoice reads it through the job link, never stored twice.
- **All-day vs timed** (see §4.1): `isAllDay: Bool = true`; for timed jobs `startTime: Date?` +
  `durationMinutes: Int?`. All-day jobs keep `startDate`/`durationDays` as their occupancy length. **The
  engine reads `durationDays` when `isAllDay`, `durationMinutes` when timed.**
- `serviceAddress` fields (optional).
- `agreedPrice: Double?` — single amount for from-scratch jobs. **`Double`** to match the codebase's
  money convention (`Invoice.amountDueNow: Double`, `Invoice.swift:115`), not `Decimal`.
- `recurrenceRule` (see §6) — encoded `Data?` / optional scalars (frequency, interval, weekday-mask,
  endKind, endDate, endCount), **not** a relational model.
- **Completion snapshot** (see §8) — `completionSnapshotData: Data?` (encoded immutable record:
  completion date, contracted value, invoiced total, amount paid, per-invoice payment lines). Inline
  blob, not a new `@Model`.

### 1.2 New **`Project`** `@Model` (register in `GLSchemaV2.models`)

- `name: String`; `customer: Customer?` (optional, `.nullify`, inverse `Customer.projects: [Project]?`).
- `jobs: [Job]?` — **optional** to-many (inverse `Job.project`). Never `[Job] = []`.
- `masterAgreementData: Data?` (externalStorage) — the signed contract PDF.
- All roll-up totals are **computed** (no stored totals), consistent with Invoice deriving
  `isPaid`/`balanceDue`.

### 1.3 Invoice changes for progress billing

- **New:** `Invoice.job: ScheduledJob?` (optional, inverse `ScheduledJob.invoices: [Invoice]?`). Multiple
  invoices per job (deposit + draws + final). **Invoices attach to Jobs only — there is NO direct
  `Invoice.project` relationship**; project totals are derived by summing across the project's jobs'
  invoices.
- **"Paid in full" stays computed** — reuse `Invoice.isPaid` (`:267`), `balanceDue` (`:254`),
  `displayStatus` (`:272`). Roll-ups are computed from **recorded `InvoicePayment` records only** (sum
  `payment.amount` across attached invoices, `Invoice.swift:217-219`); the existing per-invoice
  `amountDueNow`/`amountDueDetail` (`:115-116`) remain a **presentation** concern and are **not** used in
  roll-up math (avoids double-counting). The legacy single-invoice milestone resend still works; it is
  not removed, just no longer the only path.

### 1.4 `BusinessProfile` additions (all `String = ""`, mirror `BusinessProfile.swift:91-114`)

- `warrantyText` (§7); `completionMessageSubject` / `completionMessageIntro` / `completionMessageClosing`
  (§8). Ride them into `GLSchemaV2`.

### 1.5 Work-schedule config storage (synced)

Today the workdays mask + "one job at a time" are device-local `@AppStorage` (`ScheduledJob.swift:20-21`).
The new config follows the owner across devices: store one **`Codable WorkSchedule`** encoded as `Data?`
on `BusinessProfile`:

```
WorkSchedule {
  weekdayHours: [WeekdayHours]   // exactly 7, Sun…Sat; each { isWorkday, start, end }
  holidays:     [HolidayState]   // keyed by a STABLE holiday id (NOT date), { id, enabled, oneTimeOnly }
  vacations:    [DateRange]      // { start, end }
  overrides:    [DateOverride]   // { date, kind: .blocked | .customHours(start,end) }
}
```

**Stable holiday identifiers** (e.g. `"us.federal.independence-day"`) are independent of the year, so
"unchecked" / "one-time" state survives across years and across our list updates; the actual dates are
computed per year. On first launch, **import** the existing `@AppStorage` keys, then stop reading them
(don't delete abruptly). These are **new V2 fields**.

### 1.6 ChangeOrder — unchanged this release (see §10)

`ChangeOrder` is hard-bound to `Invoice` today (`ChangeOrder.swift:40`; per-invoice numbering
`:75-80`; form requires an invoice `ChangeOrderScreens.swift:38`; entry point is the invoice detail
menu `InvoiceDetailScreen.swift:93,179`). **It stays invoice-attached.** Re-homing onto the Job
(numbering, entry point, `job` link) is **deferred** (§10). Approved change orders raise the **invoiced
total**, so added scope still satisfies the "fully billed" gate (§3.2) without a CO→Job link.

### 1.7 Migration backfill for existing `ScheduledJob` rows

A CloudKit lightweight migration only writes literal defaults; run a **one-time in-code backfill** on
first launch of the new build. Per field:

| New field | Rule | Fallback |
|---|---|---|
| `customer` | **Leave nil** — name-matching against `customerName` is unsafe/collision-prone. | keep `customerName` snapshot |
| `statusRaw` | derive `completed` if the source invoice `isPaid`; else `scheduled` | `scheduled` |
| `completedAt` | for derived-complete rows, latest `InvoicePayment.date` on the source invoice | nil → completion package blocked until the user sets it |
| `isAllDay` | `true` (all legacy bookings are day-based) | — |
| occupancy | legacy rows keep `durationDays`; engine reads `durationDays` when all-day | — |
| `serviceAddress` | copy from the source invoice's address (`Invoice.swift:96`) if present | nil |

---

## 2. Jobs as a first-class feature

### 2.1 Where jobs surface (no new tab)

- **Customer detail:** add a `.jobs` case to **`CustomerDocumentKind`** (defined in
  `Screens/CustomerDocumentsScreen.swift:11`; cases + `pluralTitle`/`singularTitle`/`systemImage` at
  `:18-40`) **and** a `.jobs` branch to the row switch in `Screens/CustomerDetailScreen.swift:155-162`
  (→ `JobsListScreen(customer:)`). **Both files change.**
- **Jobs tab (2026-08-21 rework):** lands on `AllJobsScreen` (the list); the **Calendar** is pushed from its toolbar button. (Previously: Calendar tab with an "All Jobs" row.)
- **Menu → "Job Records":** for parity with every other record type, add **"All Jobs"** (and, once
  Projects ship, **"All Projects"**) `NavigationLink` rows to the existing section
  (`MenuScreen.swift:53-93`). This is the "follows existing flows, doesn't feel out of place" requirement.
- **iPad (2026-08-21 rework):** the Jobs section's content column is the All Jobs LIST; the Calendar fills the detail pane by default (both visible at once). (Previously: Calendar in the content column with no detail pane
  (`IPadRootSplitView.swift:279-280`); confirm the pushed All-Jobs list and Job detail work there and in
  the Customer detail column — add a verification pass.

### 2.2 Creation paths (all coexist)

1. **From an accepted estimate or an invoice** — existing flow, now producing a real Job holding the
   source link. **Linking rule across the estimate→invoice transition:** scheduling an accepted estimate
   creates a Job with `job.estimate` set; when that estimate is later invoiced (`Invoice.make(from:)`,
   `Invoice.swift:290`), the new invoice's `Invoice.job` is set to the **same** Job (no duplicate). A Job
   is created at **schedule time**, not at convert-to-invoice time.
   - **Source picker** (`ScheduleSourcePicker`, `CalendarScreen.swift:305-310`) now filters on **whether a
     Job already exists** for the source (hide already-scheduled sources), instead of the old
     per-document `scheduledJob` check.
   - Navigation is bidirectional: job → source doc, invoice → job.
2. **From scratch on the Calendar** — the `+` offers **"New job"** alongside "From an estimate/invoice."
3. **From a tapped gap row** (§4.5) — starts a **new job pre-filled** to that range, fully editable.

> The README's *"never free-form — the GL way"* rule is **reversed**. Copy to update is enumerated in §12.

### 2.3 From-scratch job form (`JobFormScreen`, lightweight)

Reuse the customer picker, `AddressSearch`, `SaveOnceButton`. Fields: **Customer** (pick/create,
required) · **Service address** (autofills from customer, editable) · **Title** · **All-day / Timed
toggle** (all-day default, §4.1) · **Agreed price** (optional) · **Notes** · **Recurrence** toggle (§6).
**Line items on jobs are deferred** — estimate-sourced jobs carry the breakdown via their linked estimate.

### 2.4 Status & completion

`scheduled → inProgress → completed`. Marking **complete** sets `completedAt` (default-suggest the final
payment date) and **starts the warranty clock immediately**.

> **Precedence:** a job may be marked **completed independently of billing** — the warranty clock starts
> right away. The completion **package** stays gated on **fully-billed + zero-balance** (§3.2, §8). Two
> separate states.

### 2.5 New screens (inventory)

`JobsListScreen(customer:)`, `AllJobsScreen`, `JobDetailScreen` (sections: summary, schedule, customer,
linked source doc, invoices/billing, complete action, completion package), `JobFormScreen` (§2.3),
`AllProjectsScreen`, `ProjectDetailScreen` (roll-up totals + jobs + "New invoice (project draw)" + master
agreement), and the work-schedule editor (§5, extends `SettingsScreen` or a new `WorkScheduleScreen`).
Each mirrors an existing list/detail/form pattern.

---

## 3. Projects & progress billing

### 3.0 Project entry points (decided)

- **Creation:** an **"Add to project"** action on the **Job detail**, offering **create-new-or-pick-
  existing inline**. There is **no upfront Projects tab**.
- **Browse:** **Menu → Job Records → "All Projects"** (`AllProjectsScreen`), shown **only once ≥1 project
  exists** (invisible until used).
- A Project, once it exists, surfaces its roll-up (contracted / invoiced / paid / remaining) and a "New
  invoice (project draw)" action on `ProjectDetailScreen`.

### 3.1 Optional grouping

Solo / single-job users never see it. A GC groups jobs under one Project, attaches the signed master
agreement, and rolls invoices up to one total — structure appears **because they reached for it**.

### 3.2 Progress / milestone billing (in v1)

Multiple invoices per job/project (deposit + draws + final), rolling up.

**Contracted value** (the "billed to 100%" denominator), by precedence:
1. `job.agreedPrice` if set; else
2. the linked **accepted estimate** total (`Estimate.total`, `Estimate.swift:257`); else
3. the **sum of attached invoice totals** (which makes "billed to 100%" trivially true → the gate reduces
   to zero-balance — intended for jobs that were never given an upfront price).

Project contracted value = sum of its jobs' contracted values.

**The gate predicate** (one place, reused by §8):
```
isFullyBilledAndCollected =
  (contractedValue <= 0.005 || invoicedTotal >= contractedValue - 0.005)
  && (totalBalanceDue <= 0.005)
```
- **$0 / fully-comped:** a $0-contracted job may complete **with no invoice** (both clauses vacuously
  true). A real job comped 100% on its single invoice (billed 100 %, balance $0, paid $0) **is**
  "paid in full" — the rollup receipt shows the **PAID IN FULL** badge (`PaymentReceiptDocument.swift:78`)
  even when amount-paid is $0.
- Approved change orders raise `invoicedTotal` (§1.6); added scope still satisfies the gate once collected.

---

## 4. Scheduling engine rewrite (whole-day → time-interval)

The single largest work item. Today `SchedulingEngine` (`Models/ScheduledJob.swift:99-151`) models
occupancy as a whole-day `Set<Date>` and has **no** concept of time or recurrence. `SchedulingTests.swift`
will need **rewriting**, not just extending.

### 4.1 All-day vs timed jobs (Apple Calendar's shape)

Inline toggle, **all-day by default**:
- **All-day** — project work: N **workdays** long, owns those days.
- **Timed** — service work: **start time + duration**, multiple per day. UI input in **30-minute
  increments**, stored as `durationMinutes` (§1.1).

Under the hood both are time intervals → one occupancy/overlap/gaps code path.

### 4.2 Availability primitives

- `isWorkday(date) -> Bool` and `workingHours(date) -> [Interval]` (a day may be empty = non-working).
- **Two orthogonal override axes** (resolves the "hours vs blocked" conflation): a `DateOverride` is
  either `.blocked` (force off) or `.customHours(start,end)` (force on with those hours).
- **Precedence:** `DateOverride` (most specific) → days-off list (holidays/vacation/custom) → weekday
  setting. **Intra-days-off tiebreak:** if *any* days-off entry blocks the date, it is non-working —
  a vacation range beats an *unchecked* holiday on the same date.

### 4.3 Interval model & intra-day gaps

- A workday = its `workingHours(date)` interval(s) **minus** occupied sub-intervals.
- An **all-day** job occupies the **entire working interval** of each day it owns.
- A **timed** job occupies `[startTime, startTime+durationMinutes]`, **clipped** to working hours if it
  runs past close.
- **Minimum surfaced gap = 30 minutes** (slivers below are ignored).
- Back-to-back timed jobs with a lunch break in working hours produce **two** gaps.
- **No cross-day merge for timed gaps:** an end-of-day timed gap does not merge with the next free day.
  Multi-day stretches are reported as whole-day capacity (for all-day project work); intra-day gaps are
  single-day with an hours capacity.

### 4.4 The two banner rows

- **Row 1 — "Next available date"** = the soonest **bounded** gap (`gaps().first`) + capacity (N
  workdays, or "X hrs free" for an intra-day gap). "View gaps" shows the rest.
- **Row 2 — "Next clear date"** = the first workday after your **last bounded commitment** with clear
  road ahead. Computed over a **finite horizon** (reuse the existing 90-day horizon,
  `SchedulingEngine.gaps horizonDays:90`).

**Recurrence interaction (open-ended series):** the clear-date tail considers only jobs with a **defined
end** (one-offs + bounded series). An **open-ended** ("Never"-ending) series never ends, so it is
**excluded** from the tail calc; instead, when one exists, Row 2 shows the clear date **plus** a
"(recurring commitments continue)" note. If an open-ended series occupies certain weekdays such that no
clear tail exists within the horizon, **hide Row 2** and show "Ongoing recurring series — no open-ended
date."

**Edge states:** nothing booked → Row 1 hides, Row 2 = next workday from today. Only recurring booked, or
all bookings in the past (`endDay >= today`, `CalendarScreen.swift:30-33`) → Row 2 = next workday from
today. Jobs booked but no bounded gap before the tail → Row 1 = "No openings before [clear date]."
Soonest opening is an intra-day hole on an otherwise-full day → Row 1 shows that day + "X hrs free."

### 4.5 View gaps → pushed list

Change "View gaps" from `.sheet` to a **pushed list** (`NavigationLink`). Each row = date range +
capacity ("N open workdays" or "Tue · 1:00–5:00 PM · 4 hrs free"). **Tap → new job pre-filled** to that
range (§2.2 path 3).

### 4.6 Overlap warning, repurposed

The device-local `oneJobAtATime` flag (default **true**; `SettingsScreen.swift:102`,
`ScheduleJobSheet.swift:40,97`) is relabeled (e.g. **"Warn about overlapping jobs"**), default stays
true. New predicate (replacing whole-day intersection at `ScheduleJobSheet.swift:104-110`): **all-day**
jobs warn on any **shared day**; **timed** jobs warn only on actual **time-interval** intersection.
Recurring series **warn once at series creation** (on the form), never per generated occurrence (§6.3).

---

## 5. Work-schedule settings

Consolidated where the workdays control lives (`Screens/SettingsScreen.swift`). One canonical weekday
order in prose — **Sun–Sat** (matches the `weekday-1` bitmask / `Calendar`); the chip UI renders
Mon-first. Same seven independent toggles throughout.

### 5.1 Workdays (already exists)

`WorkdayPicker` is already a per-day chip selector (bit `weekday-1`, guard against zero). **Done.**

### 5.2 Working hours (new)

Per weekday: each workday gets its own start/end (extends `WorkdayPicker`). Per specific date: a
one-off `DateOverride` (§4.2) — custom hours or blocked.

### 5.3 Days off — one model, three flavors

To the engine, one thing (a non-working date); labeled for the user. Stored per §1.5.
- **US holidays** — a **built-in** computed list (**no Apple US-holidays API** — iOS only exposes a
  permission-gated subscribed calendar; ours is offline, no permission). The **full** American list,
  grouped **Federal · Common closures · Cultural & religious**. **Common days-off auto-ON** (federal +
  Christmas Eve / Black Friday / New Year's Eve) to minimize unchecking; everything else **present but
  default-OFF**. Unchecking a holiday makes it a workday (subject to the §4.2 tiebreak). **Repeat yearly
  by default**, per-holiday "one-time only" toggle. Keyed by stable id (§1.5).
- **Vacation** — a date **range**.
- **Custom** — anything the list misses.
- All show as marked days on the calendar grid.

**Worked precedence examples:** (a) a `.customHours` override on July 4 → **workday** with those hours
(explicit user action wins). (b) July 4 inside a vacation range → **off** (vacation blocks, beats an
unchecked holiday). (c) An unchecked holiday with no other rule → **workday**.

---

## 6. Recurring jobs

- **Vocabulary:** Weekly / Every-2-weeks / Monthly; weekly picks **multiple weekdays** (Mon+Thu); ends
  **Never / On date / After N visits**. Each occurrence inherits the job's all-day/timed setting.
- **Occurrence model:** parent Job + rule expanded **on the fly within the 90-day horizon** (§4.4);
  **materialize** an occurrence only when it needs per-visit data (notes, completion).
- **Interactions:** occurrences participate in occupancy/gaps; the overlap warning fires **once** at
  series creation (§4.6); **no per-visit billing** (schedule-only standing approval); **completion /
  warranty / completion package apply to ONE-OFF jobs only** — a series has no single completion date.

---

## 7. Warranty

- **One saved warranty**, **plain multi-line text**, **blank by default**, **no structured term** (period
  stated inside the text). Backed by `BusinessProfile.warrantyText` (§1.4).
- **Edit** in **`MyCompanyFormScreen`** (`MenuScreen.swift`, near the message sections ~`:513`; state vars
  `:320-334`). **Display** as a read-only card in **`CompanyDetailsScreen`** (`Screens/CompanyDetails.swift`,
  after the message cards ~`:74`). Note: that screen's nav title is **"More Info"** (`:89`); the hub
  titled **"My Business Details"** is `MyCompanyDetailScreen` (`MenuScreen.swift:176`) which links to "More
  Info" at `:206-209`. The warranty card goes on the **"More Info"** screen, not the hub root.
- **Snapshotted** into each completion package (rendered to a branded PDF page, like the W-9 in the
  Contractor Package). Caption: coverage starts from the job's completion date.

---

## 8. Completion package

Mirrors the **Contractor Package** pipeline (`Screens/ContractorPackage.swift`, `ContractorPackagePDF.merge`,
`ContractorPackageMessage`, `ShareLink`, `DocumentPreviewSheet`).

- **Launches from `JobDetailScreen`** (owns the completion date + invoice links), shortcut from a paid
  invoice. **Hard-gated** on `isFullyBilledAndCollected` (§3.2). **Empty state branches both failure
  modes:** under-billed → "Invoice the remaining $X"; billed-but-unpaid → "Record the outstanding $Y
  payment."
- **One merged PDF, in order:**
  1. **Completion cover** — job title, **the Job's** customer + service address, completion date.
  2. **Paid-in-full receipt** — a **job/project-level rollup** aggregating all `InvoicePayment` records
     across the job's/project's invoices (deposit + draws + final). Reuse `PaymentReceiptDocument`'s
     layout + "PAID IN FULL" badge, **adapted from invoice-scoped to a multi-invoice rollup**. Header
     source = **the Job's** customer + service address (not per-invoice snapshots). Count only **sent +
     paid** invoices toward "billed"/the rollup (exclude drafts/voided). One line per invoice.
  3. **Warranty page** — rendered from the saved text (§7).
- **Own branded `CompletionPackageMessage`** (overridable subject/intro/closing on `BusinessProfile` §1.4,
  edited in `MyCompanyFormScreen`, shown in `CompanyDetailsScreen`), mirroring the existing five message
  types end-to-end.
- **No signature step.**
- **Persistence:** completion date + paid-in-full snapshot persist on the Job (`completionSnapshotData`,
  §1.1) — immutable so later edits/payments can't rewrite history. The merged PDF stays
  **ephemeral/regenerable** — no stored blob.

---

## 9. Build order (STAGED — decided)

Staged delivery (matches the one-feature-per-round cadence; each phase is its own additive V2 bump +
CloudKit deploy). **Each phase includes Swift Testing coverage (§11) and demo-seed updates (below).**

1. **First-class Job** + from-scratch creation + Customer Jobs row + All-Jobs (Calendar + Job Records) +
   the §1.0 V1→V2 freeze + §1.7 backfill.
2. **Scheduling rewrite** — time-interval engine, all-day/timed, working hours, holidays/vacation/overrides,
   two banner rows, gaps-as-pushed-list, repurposed overlap warning.
3. **Projects + progress / milestone billing.**
4. **Recurring jobs.**
5. **Warranty** (independent).
6. **Completion package.**

**Demo seed (`DemoMode.swift:185-190` currently seeds only two source-bound all-day jobs):** as each
phase lands, extend `DemoSeed` to show the feature in App Store screenshots — a from-scratch Job with an
`agreedPrice`, a **timed** cleaning Job (several per day), a **recurring** series, a **completed** Job
(for the completion package + warranty), and a **Project** grouping two jobs with deposit + draw invoices.

---

## 10. Explicitly deferred (out of scope — conscious, not forgotten)

- **Re-homing Change Orders onto the Job** (§1.6) — they stay invoice-attached.
- **Job/Project metrics in Stats** (`Stats.swift` is invoice/estimate/receipt-only) — and note: progress
  billing means multiple invoices per job, which **inflates** `invoiceCount`/`invoiced`
  (`StatsEngine`, `Stats.swift:123-130`); decide later whether per-job draws are de-duplicated.
- Worker assignment (Employee/Subcontractor on a job); line items on from-scratch jobs; per-weekday
  **split shifts**; multiple named warranties / structured warranty term; per-occurrence recurring billing.

---

## 11. Engine acceptance examples (test fixtures)

Add Swift Testing coverage in `GLSmallBusinessTests/` — **rewrite** `SchedulingTests.swift` for
time-interval occupancy; new tests for `workingHours` precedence (override→days-off→weekday), timed-vs-
all-day gaps with intra-day capacity, the "next clear date" tail, holiday computed-date correctness +
yearly-repeat + one-time toggle, vacation ranges, and recurrence expansion (weekly multi-weekday, every-
2-weeks, monthly, ends never/on-date/after-N). Pin the ambiguous behaviors with fixed input→output cases:

1. A day with two timed jobs and a lunch break → exactly two intra-day gaps of the expected hours.
2. An all-day job spanning a holiday → the holiday is non-working; the job's occupancy skips it.
3. An unbounded weekly **Mon+Thu** series → Row 2 hides with the "ongoing series" copy; bounded in-week
   gaps still surface.
4. A $0-comped job with one fully-discounted invoice → `isFullyBilledAndCollected == true`, rollup shows
   PAID IN FULL.
5. `.customHours` override on a default-ON holiday → workday with those hours; same date inside a vacation
   range → off.

---

## 12. Copy / surfaces to update (makes "done" grep-verifiable)

Reversing "never free-form" and renaming touch these exact surfaces (per the "done means user-visible
matches architecture" rule):
- `Localizable.xcstrings:7816` — "No jobs scheduled. Tap + to schedule an accepted estimate or an invoice."
- `CalendarScreen.swift:114` (same literal) + source-picker header/comments (`:296,320`).
- `ScheduledJob.swift:7-8` and `ScheduleJobSheet.swift:7` header comments ("never free-form").
- `README.md:303-305` (§Calendar rule) — and the README §Calendar section overall.
