# GLSync — the My Business sync client (platform Phase 3)

**Owner ruling, 2026-08-22:** My Business has exactly ONE paying customer (Adrian), and he
explicitly accepts starting his own account over: *"immediately. i do not care if i have to
create my account all over again. better now then after i get subscribers."*

That collapses the migration plan. **There is no shadow mode, no cohort rollout, no
dual-write soak, and no rollback window.** One release removes CloudKit and turns on
`gl-business-api`. The staged phases in `claude/docs/GoldLife-Platform-Architecture.md` §5
were written for a large installed base; they are superseded for My Business by this file.

What survives from that plan, and why:
- **Mass-delete circuit breaker** — cheap, and it stops a server-side bug from wiping the
  one real device. Kept.
- **Checksum self-heal** — cheap, catches silent divergence. Kept.
- **Privacy labels + policy copy** — legal, not caution. Ships in the SAME release
  (§7 below). Not optional, not deferrable.
- **First-run upload** — the device's SwiftData store is already a complete replica, so the
  "migration" is just pushing what is already there. One function, so we keep it rather
  than making him retype his business.

## 1. Shape

```
SwiftData (unchanged, still the local source of truth on device)
   │  history tracking
   ▼
GLSyncOutbox ──push──▶ POST /sync ──▶ gl-business-api (D1)
   ▲                        │
   └──────apply results─────┘  + pulled changes (cursor)
Attachments ──▶ POST /attachments (R2, content-addressed)
```

The client is deliberately dumb: it never resolves a conflict, never computes a merge, never
decides a winner. It ships changes, applies what comes back, and surfaces what the server
says was contested. All policy lives in the Worker.

## 2. Change capture — history-driven, NOT save-site-driven

`ModelContext.saveChanges` stamps `updatedAt` today but **SwiftUI autosaves bypass it**, so
it cannot be the change signal (this is a known, documented gap). GLSync instead reads
**SwiftData persistent history** (already enabled on the container — the store options carry
`NSPersistentHistoryTrackingKey`), which catches every mutation regardless of save path.

- Keep a `lastHistoryToken` in the sync state store. On each cycle, fetch transactions since
  that token, fold them into outbox rows, then advance the token **only after** the push
  succeeds.
- **INVESTIGATE FIRST (build blocker):** whether this SDK's `HistoryUpdate` exposes
  per-attribute change detail (`changedAttributes` / `updatedProperties`). If it does, the
  outbox stores exactly the touched fields — real per-field merge. If it does not, fall back
  to whole-record patches, and write the limitation into this file plus a code comment:
  every field looks touched, so concurrent edits to different fields on one record surface
  as contests instead of merging silently. Do not pretend field-level fidelity we do not
  have.
- The outbox is **state-based and coalescing**: one row per dirty record carrying the set of
  changed fields with their LAST value, plus `base_version` captured when the record first
  went dirty. Eight offline hours editing one invoice thirty times is ONE row. No op log.

## 2a. History API findings

Measured on 2026-08-22 against real on-disk SwiftData stores (Xcode 26.6, iOS 26 SDK,
`IPHONEOS_DEPLOYMENT_TARGET = 26.0`), plus the SDK's own
`SwiftData.framework/.../arm64e-apple-ios.swiftinterface`. Nothing below is from memory or
generic docs. **The build blocker in §2 is cleared: history works and it is per-field.**

**(a) Fetching history — YES.** `ModelContext.fetchHistory(_ descriptor:)` (iOS 18+), with
`HistoryDescriptor<DefaultHistoryTransaction>`. `HistoryDescriptor.sortBy` is iOS 26+, which
our floor already is. `fetchLimit` defaults to `0` (unlimited), so a fold cannot be silently
truncated. History persists across container instances and survives relaunch.

**(b) Per-attribute detail — YES.** `HistoryUpdate.updatedAttributes` is
`[any PartialKeyPath<Model> & Sendable]`, and a single save touching two properties reports
both. Two consequences:
- `updatedAttributes` is typed on the protocol's `Model`, so it is unreachable through
  `any HistoryUpdate` — it must be read inside a generic function that opens the existential.
  Same for `HistoryDelete.tombstone`.
- Key paths are not names. There is no public key-path-to-name API: `Schema.Attribute` has no
  `keypath` (only `Schema.Relationship` does), and `Schema.PropertyMetadata` exposes an
  initializer and nothing else. `String(describing:)` renders `\Invoice.total`, which is the
  only bridge, so `GLSyncHistory` parses that and validates every candidate against
  `Schema.Entity.attributesByName` / `relationshipsByName`. An unresolvable key path taints the
  whole update to `changedFields == nil`, i.e. a whole-record patch — coarse, never wrong.
  **Whole-record patches mean concurrent edits to DIFFERENT fields of one record surface as
  contests instead of merging silently.** That is the degenerate path only; the normal path has
  true field-level fidelity.

**(c) The token.** `DefaultHistoryToken` is `Codable`; `tokenValue` is `[String: Int64]` keyed
by store identifier. `GLSyncState.lastHistoryTokenData` stores `JSONEncoder().encode(token)` —
58 bytes in practice, e.g. `{"storeTokens":{"<store-uuid>":4}}` — and round-trips equal.

**(d) History tracking is ON by default, and CloudKit is not what turns it on.** A store built
with `cloudKitDatabase: .none` and no entitlement still recorded every transaction. So the
`NSPersistentHistoryTrackingKey: 1` in today's crash log is SwiftData's own default, and §7's
removal of `cloudKitDatabase: .automatic` does NOT switch history off. Nothing to add to
`ModelConfiguration` — it has no history knob to set anyway.

### Three traps, all of which fail SILENTLY

1. **Never filter by `author` in the predicate.** Predicates run as SQL, where
   `author != 'gl-sync'` drops every NULL-author row — that is *all of the user's own edits*.
   Measured: 0 rows returned out of 3. `GLSyncHistory` filters by author in memory instead, and
   computes the new token from the *unfiltered* window so our own apply-writes are skipped once
   rather than re-examined forever. The engine MUST set `context.author =
   GLSyncHistory.applyAuthor` on the context it uses to apply pulled changes, or every pulled
   change echoes straight back into the outbox.
2. **A token from a different store matches ZERO rows and does not throw.**
   `SwiftDataError.historyTokenExpired` exists but is not raised for this. A dev-store wipe, a
   restore from backup, or the Phase 3 store switch would leave the app reporting "nothing
   changed" forever. `GLSyncHistory` compares the token's store key against the live store's
   identifier and throws `GLSyncHistoryError.tokenFromAnotherStore`; the engine must treat that
   (and `.tokenUnreadable`) as "drop the token and re-bootstrap".
3. **Nothing prunes history once CloudKit is gone.** The mirroring delegate is what trims the
   table today. `GLSyncHistory.prune(before:in:)` wraps `deleteHistory`; the engine must call it
   after a successful push, with a cutoff comfortably behind the persisted token so a
   long-offline device still finds its window intact.

### Open gap: deletes cannot be resolved to a `syncID`

A history delete carries only a `PersistentIdentifier` for a row that no longer exists —
`registeredModel(for:)` returns nil, and `HistoryDelete.tombstone` is EMPTY unless the attribute
is marked `@Attribute(.preserveValueOnDeletion)`. No model in the app marks anything. So the
delete half of §5 has no way to name the record to the server.

Recommendation: mark `syncID` with `@Attribute(.preserveValueOnDeletion)` on all 23 types. It is
one line per model, and it was tested against an existing on-disk store: the store reopened
cleanly, rows and their `syncID` values survived, and the tombstone then carried the UUID. It is
a stored-property *option* change, not a retype, so schema rule 1 is intact — but it does move
the entity hash, so it wants the versioned-schema treatment and an old-build-to-new-build
upgrade test before it ships. The alternative, a durable `PersistentIdentifier -> syncID` index,
is strictly more machinery for the same result.

### Contract note

`GLSyncHistoryChange.recordType` is the SwiftData **entity name** (`"Invoice"`), not the
snake_case manifest key. History knows nothing about the mappers, so translating entity name to
`GLSyncMappable.glSyncType` belongs to the engine, which owns the mapper registry.

## 3. The outbox model (new @Model — additive into GLSchemaV1)

```swift
@Model final class GLSyncOutboxEntry {
    var recordID: UUID?          // = the domain record's syncID
    var recordType: String = ""  // snake_case manifest type
    var parentID: UUID?
    var baseVersion: Int = 0     // 0 = create
    var fieldsJSON: String = ""  // {field: value} coalesced patch
    var isDelete: Bool = false
    var cascadeJSON: String = "" // [uuid] client-computed cascade subtree
    var firstDirtiedAt: Date = .distantPast
    var opID: UUID?              // stable per attempt-set: idempotency key
    var attempts: Int = 0
    var lastError: String = ""
}
```
Plus `GLSyncState` (singleton @Model): `cursor: Int`, `lastHistoryTokenData: Data?`,
`deviceID: UUID?`, `lastSyncAt: Date?`, `lastChecksumAt: Date?`, `bootstrapComplete: Bool`,
`ownerID: String?` (§4 — whose cursor this is), `breakerTrippedAt: Date?` +
`breakerDeletions: Int` + `breakerThreshold: Int` + `breakerOverrideArmed: Bool` (§5, the
breaker's persisted trip and its one-time override), `suppressBootstrapUpload: Bool`.

**Schema rule 2b applies:** every new property is optional or a plain scalar with a literal
default. No composite (Codable struct) property without `?`. See GLSchema.swift.

## 4. Identity

`GLSyncTokenProvider`: Stytch session → `POST /auth/app-token {audience:"gl-business"}` on
gl-money-api → 15-minute RS256 app JWT → cached in memory, refreshed at T-2min or on 401.
Never persisted to disk (it is short-lived by design). Signed out = **no sync at all**: the
app stays fully usable, local-only, with a persistent, gentle "Not backed up" state (never a
nag, never a block — degrade, don't punish).

**A cached token is re-checked against the LIVE session on every read**, not served on
freshness alone. Otherwise sign-out leaves the engine syncing under the previous person's
identity for the rest of the token's 15 minutes. `GoldLifeAuth.signOut()`,
`handleSessionExpired()` and `deleteAccount()` all call `GLSyncEngine.signedOut()`, which
drops the app token, the document key and every in-session cache.

**The sync state is bound to the account.** The app token's verified `sub` IS the id
gl-business-api partitions records by, so `GLSyncState.ownerID` is set from it. A DIFFERENT
`sub` means the device changed hands: cursor, history token, `bootstrapComplete`, outbox,
version table and `deviceID` are all reset, and the first-run upload is suppressed for that
bootstrap — `seq` is per-user, so an inherited cursor skips the new account's entire history,
and the records already on the device belong to the person who was here before.

## 5. The engine

`GLSyncEngine` (actor). Triggers: app foreground, connectivity restored, ~5s debounce after
an edit. **No polling, ever.**

1. Fold history → outbox.
2. Chunk ≤50 ops, `POST /sync {device_id, cursor, ops}`.
3. Apply per-op results: `applied` → clear the outbox row, stamp the new version;
   `cached` → same (replay); `conflict` → keep the parked value, badge the record, surface
   in Recent Changes; `refused` → surface the machine reason in plain English
   (`paid_locked` → "A paid invoice can’t be changed or deleted, and neither can the customer it
   belongs to. Add a change order to correct it." — one sentence per reason, and since the app
   now blocks every gesture the lock covers, a refusal reaching a current build means an op
   queued before it was updated). The sentence was re-scoped on 2026-08-23: the original
   ("This invoice is already paid — add a change order instead.") assumed an INVOICE op, and the
   same day's customer ruling below means `paid_locked` now also answers a refused CUSTOMER
   delete — where "add a change order" is advice that cannot delete anybody. **All ten sentences
   are catalog keys** (`GLSyncRefusalReason.userMessage` → `MBLocalization.string`, not plain
   literals), because an un-extracted literal reads English in a Spanish app and the in-app
   language switch cannot reach it;
   `subscription_lapsed` (added 2026-08-26) is the tenth and the only reason that is not a
   verdict on the record: the account lapsed, nothing is wrong with what they typed, and it
   becomes writable again the moment they reactivate. Its ABSENCE was the bug — nine cases and
   none matching the Worker's most common refusal, so the person was shown `unknown_type`'s
   "Updating the app should fix it", which sends them to the App Store instead of to their
   subscription. The same word arrives on a second channel — `{error:"subscription_lapsed"}`,
   403, from `POST /attachments` and `GET /account/export` — and
   `GLSyncTransportError.subscriptionLapsed` reads its sentence off the reason rather than
   copying it, so one machine word has exactly one sentence and one catalog key. It is
   classified NON-transient: routed to `.server(status: 403)` it looked retryable, so a refused
   attachment retried on every cycle forever and threw out of `uploadBlobs`, aborting a push
   whose other ops had never touched an attachment;
   `lww_lost` → quiet Recent Changes entry, never a modal.
4. Apply `changes`: pulled rows overwrite CLEAN local records; records with a pending outbox
   entry are SKIPPED and reconcile at the next push (the server merges per-field). **This is
   the one non-obvious client rule and it gets the densest tests.** PARKED rows are NOT
   pending for this purpose: a parked row cannot push, so blocking the pull too would freeze
   that record in both directions forever. The parked value survives in `fieldsJSON`.
5. Advance the cursor and the history token together, transactionally.

**Deletes go through `ModelContext.deleteSynced(_:)`, never `delete(_:)`.** The cascade
subtree has to be read while the record still exists, and it ships as ONE op the Worker
verifies. Per-row independent deletes tombstone the leaves, get `append_only` on
`invoice_payment` and a conflict on the parent — an invoice stripped of its line items with
its payments still attached. Push order is writes first (parent→child), then deletes
(child→parent), so the history-fold fallback degrades instead of corrupting.

**Deletes inside a PAID invoice are blocked in the app, not just refused by the server**
(owner ruling, 2026-08-23 — `UIComponents/PaidInvoiceLock.swift`). Since that ruling the
Worker refuses deletes of an invoice, its groups, and its line items with the same
`paid_locked` reason a money edit gets: deleting a $500 line moved the total exactly as far as
re-pricing it to 0, so a lock that guarded only edits guarded only the polite route. The app
half is not optional — a server-only lock refuses a delete this device already performed, and
the record is then gone here and alive there. `InvoiceFormScreen.save()` makes that concrete:
it saves the rows IN PLACE (`Models/RowReconciler.swift`), so editing a paid invoice reaches the
Worker as UPDATE ops on `invoice_group` / `invoice_line_item` plus a `deleteSynced` for every
removed row — each one refused `paid_locked` — while the CREATEs for added rows are accepted
(creates stay open, below). A refusal parks the op, so without the app half the edit stands on
this phone and never exists on the server: the divergence is silent. Before the in-place rewrite
`save()` deleted every group and rebuilt it, and the same gap was louder — refused deletes,
accepted creates, the OLD line items left sitting beside the new ones. Blocked gestures, each
explained with `.paidInvoiceLockAlert` rather than a dead disabled control: **Edit** on the
invoice (and `save()` itself, for the race where the invoice becomes paid mid-edit), swipe and
bulk delete on both invoice lists, and delete / edit / "move off Approved" for a change order
whose items are billed on it (`ChangeOrder.isBilledToLockedInvoice` — an UNAPPLIED order owns
nothing on the invoice and stays freely deletable, since refusing it would diverge in the other
direction). Creates stay open on both sides: a change order is the sanctioned path forward.

**Deleting the CUSTOMER is blocked too** (same ruling, second half). Their invoices ride the
cascade, so a customer delete used to take settled invoices — and every `InvoicePayment` inside
them — into the grave that deleting the invoice directly is refused for. Nothing diverged, and
that was the problem: both halves permitted it, because the root op's type is not a `paid_lock`
type. A paid invoice is the record of money that changed hands; losing it by deleting the person
it belongs to is exactly the silent history loss that makes books untrustworthy. The Worker now
refuses that delete from its own subtree scan (`paidInvoiceInSubtree`, reason `paid_locked`,
checked before cascade verification so the durable answer wins over a stale-cascade conflict),
and the app blocks all three customer delete gestures — swipe and bulk on `CustomersScreen`,
swipe on the iPad sidebar — with `.paidCustomerLockAlert` and `Customer.hasPaidInvoice`. The
honest cost, said out loud rather than hidden: a customer who has ever paid an invoice cannot be
deleted, which is the same trade the app already makes for the invoice itself.

**What the lock deliberately does NOT freeze:** `Invoice.amountDueNow`, listed
`paid_lock_exempt` in the manifest. It is a REQUEST for money (the milestone ask), not a record
of money collected: the totals formula never reads it, and every surface shows and charges
`min(amountDueNow, balanceDue)` — 0 on a paid invoice — so an exempt write cannot move a dollar.
Recording a payment draws the request down (`Invoice.drawDownAmountDueRequest`), including on the
payment that settles the invoice. Because writes push parent-before-child, that drawdown is
usually judged before the payment lands; when the two are separated (the payment came from
another device, or the drawdown re-pushes after a park) the invoice is already derived-paid, and
without the exemption the patch is refused, the drawdown is silently lost, and every other device
shows a paid invoice still asking for money. `stripePaymentLinkAmountCents` stays locked — it is
what a live pay link would charge.

**`client_ts` is the moment the RECORD was edited** (`GLSyncOutboxEntry.firstDirtiedAt`), not
push time. The server breaks LWW ties on it, so a per-chunk push stamp would hand every
argument to whichever device syncs last.

**Mass-delete circuit breaker:** if a pull would delete more than 10% of the local store (or
more than 25 records, whichever is larger), the client refuses the whole pull and halts sync.
A server bug then costs one paused device, not a wiped business.

Counted per cascade ROOT, not per row — one deleted invoice emits a tombstone per line item,
and counting those individually trips the breaker on the most ordinary delete in the app. The
trip is PERSISTED (`breakerTrippedAt`), so a relaunch does not silently re-pull the same page
and re-trip forever. Settings shows the pause with the number and one action, "Continue and
delete them here", which arms a ONE-TIME override: the page it lets through is the page the
person approved, and a second surprise stops again.

**Bootstrap:** `bootstrapComplete == false` → page `GET /snapshot?after=&limit=` to
completion before any push. **First run on the existing store is the migration:** enqueue
every local record as a create, in parent-before-child order.

**Self-heal:** every ~24h compare `GET /checksums` against local per-type counts; a mismatch
re-bootstraps. Detect a seq gap (`oldest_seq` newer than our cursor) → full resync.

## 6. Payload mapping — 23 types, explicit, no reflection

One `GLSyncMapper` per @Model, hand-written and legible (the no-AI-contingency rule):

```swift
protocol GLSyncMappable: AnyObject {
    static var glSyncType: String { get }          // manifest key
    static var glSyncParentKeyPath: String? { get }
    var glSyncID: UUID? { get set }
    func glSyncPayload() -> [String: any Sendable] // ALL fields, JSON-ready
    func glSyncApply(_ payload: [String: any Sendable], in ctx: ModelContext)
}
```

Rules every mapper obeys:
- `Address` rides as a JSON object, never flattened columns. (Local STORAGE may still be
  flat: `UserProfile.homeAddress` folds five flat columns into the one wire object, because
  writing an optional composite attribute poisons persistent history — the build-48 launch
  crash; GLSchema.swift rule 2c. The wire shape is unchanged either way.)
- Enums ride as their raw strings; **unknown incoming values degrade to the default case,
  never crash** (the shipped `PaymentMethod` → `.other` rule, generalized).
- Blob (`Data`) fields ride as `{sha256, name}` references — the bytes go to
  `/attachments`, never into the payload. `BusinessProfile.workScheduleData` is the ONE
  exception: it is inline JSON, stays in the payload as structured data.
- `BusinessProfile.w9TIN` is **never sent** (the server strips it anyway; the client must
  not rely on that).
- `Subcontractor.tinKey` is write-once — send it on create, never on update.
- Relationships ride as parent/reference UUIDs, never nested objects.
- Money is `Double` with the 0.005 half-cent convention; derived totals are NEVER sent.

## 7. CloudKit removal + legal (same release, non-negotiable)

- `ModelConfiguration` drops `cloudKitDatabase: .automatic`; delete `CloudKitSchemaInit` and
  its DEBUG call; remove the iCloud container entitlement.
- **Never delete the CloudKit container itself** (≥12 months). Costs nothing, and it is the
  only copy of anything we failed to upload.
- The 11 in-app iCloud-promise strings go to ZERO (closed list in DATA-MAP.md; grep is the
  gate). The two Keychain-promise strings stay TRUE and must NOT be reworded.
- Privacy policy + App Store privacy labels change in the SAME release: "Data Not Collected"
  becomes Collected + Linked to You (Contact, Financial, User Content, Identifiers). Account
  deletion (5.1.1(v)) and data export must work against the new backend before submission.
  Account deletion works in EVERY billing state — 5.1.1(v) is not negotiable and the Worker
  leaves `DELETE /account` and the `/account/has-data` probe the delete screen reads open to a
  lapsed caller. Export does NOT: it is refused while lapsed (owner ruling 2026-08-25 —
  exporting is the app acting on the person's behalf), so "must work" here means for a caller
  entitled to it.
- `ProfileDedup` keeps running: its rationale changes from "CloudKit init race" to "server
  bootstrap race", and the counter MAX-merge is now ALSO enforced server-side.

## 8. Tests

- **Conformance vectors:** Swift Testing replays `gl-business-api/test/vectors/*.json`
  against the client's own merge-result handling — the same files the Worker runs, so the
  two platforms cannot drift.
- **Round-trip:** every mapper, every type — `payload(apply(payload)) == payload`, with a
  test that FAILS when a new @Model property is added and not mapped (reflection-based
  property-count guard against the manifest; this is the regression net that keeps the map
  honest).
- **Engine:** pull-overwrites-clean / pull-skips-dirty, circuit breaker trip, bootstrap
  paging, token refresh on 401, offline queue coalescing, cascade ordering.
- **Hardening (GLSyncHardeningTests.swift):** every delete site routes through
  `deleteSynced` (source scan — a missing CALL is not catchable by testing the callee),
  cascade-echo suppression, leaf-first delete order, per-root breaker counting, the
  persisted trip and its one-time override, a parked row that pulls but does not push, the
  stale-row guard on `conflict`/`refused`, per-record `client_ts`, account rebinding, and
  every session exit reaching `GLSyncEngine.signedOut()` (source scan, same reason).
- **Live smoke:** against the deployed Worker with a real Gold Life ID token.
