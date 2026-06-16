# TODO

## Release-readiness pass — done (code)
The code-review findings and pending fixes have been worked through: money / data-integrity /
perf / security fixes, locale-aware number parsing, Keychain error handling, W-9 TIN validation,
signature white-knockout, duplicate-profile guard, type-ahead caching, detail-screen hoists.
A unit-test target was added (96 tests, ~89% business-logic coverage). Build number bumped to 5.

## Remaining — owner actions only (can't be done from code)
- [ ] **Archive a Release build and submit.** (Build number is at 5; bump again for each later submission.)
- [ ] **Deploy the CloudKit schema to Production.** CloudKit Dashboard → Deploy Schema Changes —
      promote the schema (including the new `ChangeOrder` / `ChangeOrderLineItem` record types and the
      `Invoice.changeOrders` relationship) to Production, or sync silently breaks for real users.
- [ ] On your own device: **delete + reinstall** once (new data models), then clear the stray
      no-customer invoice via **Menu → All Invoices**.
