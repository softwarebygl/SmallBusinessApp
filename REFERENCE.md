
## Archive ledger

⚠️ **GoldLifeUI is now a LOCAL package (`../GoldLifeUI`), changed 2026-08-31 — the
pins recorded below are historical and no longer meaningful.** This app used to
reference the design system as an `XCRemoteSwiftPackageReference` pinned to a
revision while other apps referenced it by local path. The result: a full day of
design-system fixes did not reach My Business —
the apps compiled different versions of the same file while every diff,
review and test looked correct. That is what let the app-switcher privacy cover
stay broken through several "fixes". See GoldLifeUI/REQUIREMENTS.md law 39.

Archive + upload uses `Scripts/archive_and_upload.sh` with `-scheme GLSmallBusiness`.

- **3.0.0 (68)** — 2026-09-02. The suite-architecture build: one harness
  (`GLSmallBusinessTests/Harness/`), 11 duplicate clusters collapsed (13 test
  files deleted, nothing weakened), 12 gap suites for the audit's crash classes,
  and two self-enforced laws (hosting suites serialized; no raw relationship
  reads — the lint converted 14 more app sites). Zero compiler warnings across
  app + both test targets. FULL SUITE GREEN — 1212/1212 units in 136 suites
  (+1 env-gated skip) in 103 s, 33/33 UI (+1 skip; MarketingShots excluded by
  plan).
- **3.0.0 (67)** — 2026-09-02. The confidence build: the wife's save crash
  root-fixed for the whole class (LiveRows fence at every relationship
  accessor + DeletedRecordView as a branch on 12 screens), the CRUD-audit
  lifecycle fixes (deferred default-store wipe, version-cache purge, thrown
  saves alert), and the FULL SUITE GREEN — 1323/1323 units + 35/35 UI. The
  suite's first day back caught 1 bug in the new fence and 3 app gaps
  (coiData blob registration, a missed law-40 menu, a title clearance).
  Zero warnings.
- **3.0.0 (66)** — 2026-09-01 night. Options estimates (combineTotals off =
  per-option pricing, multi-select convert) + the same-day 44-agent QA round
  (7 confirmed bugs fixed — conversion deposit/discount, messages, Stats, job
  value, hidden-toggle trap, ES tax line, $0-invoice guard). Also the iOS 26.6
  PDF details wrap guard. ⚠️ Suite still not run this series. ⚠️ gl-business-api
  manifest protects combineTotals but deploy waits on dispatch's in-flight work.
- **3.0.0 (65)** — 2026-09-01 night. Law 41: warm relock is MBLockWindow over
  the running app, never a gate swap — backgrounding past the 60s grace no
  longer destroys navigation + half-typed forms (the lost-estimate bug).
  Sim-verified both paths with -mb.relockGrace. Also law 40 (7 one-option
  menus flattened) and the zero-warnings sweep. ⚠️ Suite still not run this
  series — run it before the ASC version ships.
- **3.0.0 (64)** — 2026-09-01. The build-62 SIGTRAP root fix: `Address.street2:
  String?` poisoned persistent history on EVERY address update (proven by three
  deterministic repros); all eight Address composites went dormant behind flat
  columns + façades (`@Attribute(originalName:)` keeps the public names), with
  `AddressFlatsBackfill` + a fold-sentinel crash-loop breaker ("Sync was
  repaired" alert) + the changedFields wire-alias fix (address edits silently
  not syncing since b49). Also: Settings ▸ What customers see ▸ "Name in
  emails" (per-person, synced; owner default). ⚠️ Suite NOT run — owner's
  explicit "forget tests for now"; run the full suite before the ASC version
  ships.
- **3.0.0 (62)** — 2026-08-31. GoldLifeUI switched to a LOCAL package reference.
  App-switcher privacy cover actually fixed (two stacked faults: a scene lookup
  that returned nil at background, and a SwiftUI `scenePhase` raise that runs
  after iOS has already taken the snapshot — see REQUIREMENTS law 38). Verified
  by reading the `.ktx` iOS wrote to `Library/SplashBoard/Snapshots` in BOTH the
  setting-on and setting-off states. Also: the Logo section's ⓘ no longer claims
  "Show logo on documents" puts your logo on emailed estimates — it does not;
  the email logo is gated solely by "Include email signature". Full suite green
  (1320 unit in 140 suites + 35 UI, 1 skip) before archive.
- **3.0.0 (47)** — 2026-08-29, the one-UI hardening pass. GoldLifeUI pin
  `5c971819566b740c26ed315efd723dc812281177` (revision-kind). Full suite green
  (35 UI + units, 1 skip) before archive.
- **3.0.0 (54)** — 2026-08-30 morning, the batch-3 + flow-audit pass (export
  REMOVED + legal deployed; fleet GL ID skeleton; flag-era sign-in surfaces
  retired; deletion screen + copy canon). GoldLifeUI pin
  `c5b6aaba468621f8bdb28f55b680f754edd58354`. Gate: UI 35/35 green; units at
  the 5 documented stale pins exactly (re-pointed suites spot-verified green).
- **3.0.0 (53)** — 2026-08-29 overnight, the gate kit (gate + email sheet
  composed from GoldLifeUI/Gate; behavior unchanged, sim-verified). GoldLifeUI
  pin `439eeeb21bf80f114a3bbb823cf44f37f4d87c8d`. Gate: UI 35/35 green; units
  1319 with only the 5 documented stale pins.
- **3.0.0 (52)** — 2026-08-29 late night, gate ruling twins (no standalone
  Create Account; email sheet faces as [Email / Create] segments). GoldLifeUI
  pin `b4c5859eb2cb1756ee43ad12a21190253e7144a8`. Gate: UI 35/35 green; units
  1319 with only the 5 documented stale pins.
- **3.0.0 (51)** — 2026-08-29 night, law-29 re-ruling (two-option Language /
  three-option Appearance, invisible account sync) + background edit flush
  (a pending save uploads the moment the app is backgrounded). GoldLifeUI pin
  `82ac6c42c809a7acf119ccc5515453f048518f38`. Gate: UI 35/35 green; units 1319
  with only the 5 documented stale pins.
- **3.0.0 (50)** — 2026-08-29 night, batch-2 parity twins ("Gold Life ID" sheet
  title, door-failure logging, proportional script bleed via the package).
  GoldLifeUI pin `ee61be392a36b5009284528f6a58a7da2253d257`. Gate: UI 35/35
  green; units 1319 with only the 5 documented stale pins. Large title
  pixel-checked at zoom.
- **3.0.0 (57)** — 2026-08-31, the owner's first real TestFlight feedback
  pass (pulled directly from ASC via Claude in Chrome + full-res screenshot
  downloads). Same-night regression root-caused and fixed: the shared
  GoldLifeUI head-bleed inset (45%, sized for a theoretical lowercase j/p
  leading swash no real title has) was pushing every large title ~29pt off
  the body content beneath it — measured the shipped Italianno-Regular.ttf
  via CoreText, found capital J is the only real title-initial offender
  (22.2%em), reset to a measured 28%. Also fixed a shared GLScriptText gap
  (no lineLimit/minimumScaleFactor — a long dynamic title could truncate
  mid-word) that MB inherits from the same package. GoldLifeUI pin
  `acfa8444f0253eabb66c8116a1ab0bcf51d0b4f6`. Gate: 1346/1346 executed green,
  0 failed. Sim-verified on an iPhone 16 Pro: Menu/Gold Life ID title
  alignment fixed, Jobs' leading J intact, Gold Life ID's trailing D intact.
  Uploaded to ASC.

- **3.0.0 (56)** — 2026-08-30 night, the ultracode pass. Profile-sync ROOT
  CAUSE closed (four links, 10-agent workflow + live-D1 evidence): fingerprint
  plumbed through fold, establishHistoryBaseline moves the watermark off nil
  once, bootstrap reconcile is a per-field diff (no more echo clobber),
  the engine observes ModelContext.didSave (noteEdit was never called). Title
  clip CLASS-fixed: GLScript.padded 3-NBSP tail + 45% head at all 86 sites,
  pixel-proven at the Dynamic Type cap on an iPhone 16 Pro sim. Launch frame
  on the token ground (law 34 — the white flash is dead). Single-flight pref
  drains + owner-keyed residue clearing. GoldLifeUI pin ff3cd412. Gate: 1345
  green + the one red proven a TEST artifact (it matched the padded detail bar
  title as the "list"; made honest and green — save path hand-proven on sim).
  Sim-proven inline: launch frame, gate, one-flow sheet, GL-ID D at the cap,
  lapsed banner + Reactivate, menu. Uploaded to ASC ("Upload succeeded").
  OPEN, named honestly: the delete-reinstall LIVE loop needs one relayed OTP
  to prove on-device (engine-verified only until then).
- **3.0.0 (55)** — 2026-08-30 afternoon, the retest-feedback pass (reinstall
  sync ROOT fix — bootstrap reconciles pulled records as updates so orphaned
  local edits re-push; three-tier account settings + GL-ID account pickers +
  Appearance row; one email flow; wordmark splash; fleet Subscription skeleton
  with live StoreKit price + renewal facts; W-9 linearized; tertiary Sign out).
  GoldLifeUI pin `91d8c3158136babdb89d2103be38bd4e1697ae01`. DEFINITIVE gate on
  the shipped code: 1343 total / 1342 executed green / 0 failed / 1 skip —
  units AND UI 35/35, the first fully green full run (stale pins re-pointed:
  status-token tints, typographic apostrophe, offline log decision; Entitlement
  fixtures pin sample-mode OFF; the missing `.entered` lapsed-banner sentence
  added to the catalog with es). Sim-verified: gate hero parity, GL-ID byte
  pass vs MM, account picker live re-render, Subscription skeleton, Details
  stroke/W-9, Sign out. Uploaded to ASC.
- **3.0.0 (49)** — 2026-08-29 night, the launch-crash fix (optional-composite history
  poisoning; flats + facade + backfill + purge defenses). GoldLifeUI pin unchanged
  (`0a455037af4d44fdb2072252b617586d01a41b65`). Gate: UI 35/35 green; units 1319 with
  only the 5 documented stale pins red. Poisoned build-48 devices self-heal on update.
- **3.0.0 (48)** — 2026-08-29, the fix pass (ledger items + bar-title bleed +
  email signature + GLScriptText law). GoldLifeUI pin
  `0a455037af4d44fdb2072252b617586d01a41b65`. Gate: UI 35/35 green; units green
  after depollution except 5 documented stale pins of owner-approved changes.

- **3.1.0 (84)** — 2026-09-27, TestFlight (IN_BETA_TESTING). Launch-gate entitlement; typed-name client delete (swipe crash fixed); real names always save; paid-invoice lock kept; one half-up money rule + whole-cent amount entry (matches the live server gl-business-api 7044683); estimate/invoice results carry deposit / amount due now to the assistant; AI consent v3 names Gold Life's server; shared search matcher; shared Gold Life ID deletion warning; no force-unwrapped addresses. Packages at local path, clean trees: GoldLifeUI `c179df2`, GoldLifeCloud `45a727b`, GoldLifeID `3eba428`, GoldLifeAI `586852b`. Suite: 1,687 unit + 38 UI, 82.15%. Not yet for the App Store (law 79).
