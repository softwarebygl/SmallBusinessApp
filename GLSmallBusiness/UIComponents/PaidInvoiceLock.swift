//
//  PaidInvoiceLock.swift
//  GLSmallBusiness
//
//  The app half of the paid-invoice money lock. Owner ruling, 2026-08-23: once an invoice's
//  DERIVED state is paid, its money is settled — so the sync Worker refuses not only money-field
//  edits but DELETES of the invoice, its groups, and its line items, all with `paid_locked`
//  (gl-business-api: sync-manifest.json, src/merge.ts, README section 3.6) — and, since the same
//  day's second ruling, deletes that reach a paid invoice from ABOVE it: deleting the customer
//  cascaded their paid invoices and every payment inside them into the grave that deleting the
//  invoice itself is refused for (gl-business-api src/sync.ts `paidInvoiceInSubtree`).
//
//  What the lock does NOT cover, equally deliberately: `Invoice.amountDueNow` is
//  `paid_lock_exempt` in the manifest. It is a REQUEST for money, not a record of money
//  collected — invisible to the totals formula, and capped at the remaining balance everywhere
//  it is shown or charged — so the payment that settles an invoice still draws it down to 0
//  rather than leaving a paid invoice asking for money it already got.
//
//  Why this file has to exist rather than letting the server carry the rule alone: the two halves
//  must agree about what is allowed, in BOTH directions. A server-only lock refuses a write the
//  app already performed, and the record is then changed on this phone and untouched on the
//  server — the silent-divergence bug class. Editing a paid invoice is exactly that shape:
//  `InvoiceFormScreen.save()` saves rows in place (RowReconciler), so the edits leave as UPDATE
//  ops on the invoice, its groups and its line items, plus DELETEs for any row removed — and the
//  server refuses every one of them with `paid_locked`. The person would see their edit on this
//  phone and nowhere else. So every gesture that could change or remove something inside a paid
//  invoice asks here first.
//
//  House rule: explain, never a dead disabled control. The button stays tappable and says what to
//  do instead.
//

import SwiftUI

extension Invoice {
    /// True while this invoice's money is settled, so the server will refuse edits and deletes to
    /// it, its groups, and its line items.
    ///
    /// Deliberately just `isPaid`: paid is DERIVED from payments and the totals formula (there is
    /// no stored flag), and the server computes the identical verdict from the identical formula
    /// in `money.ts`, half-cent epsilon included. Naming the concept separately keeps the call
    /// sites readable and gives the lock one place to change if its scope ever stops being
    /// "exactly paid".
    var isMoneyLocked: Bool { isPaid }
}

extension Customer {
    /// True when deleting this customer would take a settled invoice down with it.
    ///
    /// Owner ruling, 2026-08-23: it would. `Customer` is not a `paid_lock` type, so for one day
    /// the whole lock had a door in it — the Worker refused to delete a paid invoice, and happily
    /// cascaded the same invoice, its line items and its InvoicePayments away when the customer
    /// above it was deleted. A paid invoice is the record of money that changed hands; losing it by
    /// deleting the person it belongs to is exactly the silent history loss that makes books
    /// untrustworthy. The Worker now refuses that delete too (`paid_locked`, from its own subtree
    /// scan in gl-business-api/src/sync.ts), so the app has to block the same gesture — a delete
    /// the app performs and the server refuses leaves the customer gone here and alive there.
    ///
    /// The honest cost of the ruling, stated plainly rather than hidden: a customer who has ever
    /// paid an invoice can no longer be deleted at all. That is the same trade the app already
    /// makes for the invoice itself, and the alert says so instead of failing silently.
    var hasPaidInvoice: Bool {
        liveRows(invoices).contains(where: \.isMoneyLocked)
    }
}

extension ChangeOrder {
    /// True when this order's items are billed on an invoice whose money is settled — the case
    /// where deleting or re-syncing the order would delete an `InvoiceGroup` under a paid invoice.
    ///
    /// An order that was never applied owns nothing on the invoice: `removeItemsFromInvoice` and
    /// `resyncInvoiceItems` both no-op for it, so it stays freely deletable even on a paid invoice.
    /// Scoping the block this tightly is the point — a lock that also fired on unapplied orders
    /// would refuse work the server happily accepts.
    var isBilledToLockedInvoice: Bool {
        appliedToInvoice && (invoice?.isMoneyLocked ?? false)
    }
}

extension View {
    /// The one explanation shown wherever a paid invoice blocks a destructive gesture: editing it,
    /// deleting it, or deleting a change order whose items are billed on it.
    ///
    /// One string for every site on purpose — a person who hits this from two different screens
    /// should read the same sentence, and there is exactly one way forward to describe. The copy
    /// names real controls in this app: "New change order" on the invoice's menu, and the New
    /// Invoice button. It deliberately avoids the word "void" — the sanctioned path is
    /// void-and-reissue, but this app has no Void action, and pointing at a button that does not
    /// exist is worse than plain English.
    func paidInvoiceLockAlert(isPresented: Binding<Bool>) -> some View {
        alert("This invoice is paid", isPresented: isPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Its billing is locked. Add a change order to correct it, or make a new invoice.")
        }
    }

    /// The same block one level up: deleting a customer would cascade their paid invoices away,
    /// so the gesture is refused wherever a customer can be deleted.
    ///
    /// A separate sentence from the invoice alert on purpose. The invoice one points at a change
    /// order and a new invoice, and neither is a way to delete a customer — pointing someone at a
    /// button that cannot help is worse than plain English. This one names what is blocking and
    /// stops, because there is honestly nothing else to do: a paid invoice is permanent, and so is
    /// the customer it belongs to.
    ///
    /// Both lines are count-neutral on purpose: the same alert answers a swipe on one customer and
    /// a multi-select of twenty, and "1 paid invoice" copy would be wrong in half of those.
    func paidCustomerLockAlert(isPresented: Binding<Bool>) -> some View {
        alert("Paid invoices can’t be deleted", isPresented: isPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("They’re your record of money you collected, so the customer they belong to can’t be deleted either.")
        }
    }
}
