//
//  DomainError.swift
//  GLSmallBusiness
//
//  The one refusal type every domain service throws. The screens and (later) the assistant's tools
//  call the SAME services, so they get the same refusals: a form maps one to its existing alert, a
//  tool maps one to `{ ok: false, reason: code }` plus a "Not done" row. Law 6 in two halves — the
//  PERSON reads `errorDescription` (EN + ES, resolved when it is read), the DEVELOPER reads the
//  OSLog line `DomainGate` writes, which names the operation and `code` and never a value.
//
//  `nonisolated`, with the operation kept as its raw name: the error crosses isolation (it is an
//  `Error`), and `MBWriteOperation` is main-actor by the module default.
//

import Foundation

nonisolated enum DomainError: LocalizedError, Equatable, Sendable {
    /// `ReadOnlyGate` said no: lapsed (`lapsed == true`) or offline. `operation` is the
    /// `MBWriteOperation` raw value.
    case readOnly(operation: String, lapsed: Bool)
    /// A never-subscribed account is at this record type's `FreeTier` cap.
    case freeLimitReached(operation: String)
    /// The record was deleted (here or by a sync pull) or never saved.
    case recordNotFound
    /// Customers and subcontractors: first, last or business name.
    case nameRequired
    /// Employees: first or last name.
    case personNameRequired
    case projectNameRequired
    /// Money, rates, hours or quantities below zero, or not a finite number.
    case negativeValue
    case percentOutOfRange
    /// A payment, bonus or flat amount has to be more than zero.
    case amountRequired
    /// Hours-based work needs hours and a rate above zero (the Log Hours rule).
    case hoursAndRateRequired
    /// A job can only join a project with no customer or its own customer.
    case projectBelongsToAnotherCustomer
    /// The write would change money on a paid invoice (`Invoice.isMoneyLocked`).
    case paidLocked
    /// An invoice's change-order rows are changed only through the change order (a tool tried to
    /// add, edit or re-link one on the invoice itself).
    case changeOrderLinesReadOnly
    /// Estimates and invoices: the job title is empty.
    case titleRequired
    /// Change orders: no item has a description.
    case itemRequired
    /// A hand-recorded payment is more than the balance due (the Record Payment sheet's rule).
    case exceedsBalance
    /// Converting an options estimate needs at least one of its options chosen.
    case optionsRequired
    /// Only an approved change order can be added to its invoice.
    case changeOrderNotApproved
    /// A job made from scratch needs a customer (the Job form's rule).
    case customerRequired
    /// A receipt for a customer can only be attached to one of that customer's jobs.
    case jobBelongsToAnotherCustomer
    /// Receipts: a vendor, a total above zero, or a photo (the Receipt form's rule).
    case receiptDetailsRequired
    /// Price sheet items: the name is empty.
    case itemNameRequired
    /// Business details: the business name is empty.
    case businessNameRequired
    /// Business details: neither an email nor a phone number.
    case contactRequired
    /// Work schedule: a window whose start is not before its end.
    case invalidHours
    /// Work schedule: time off that ends before it starts.
    case invalidDateRange
    /// Work schedule: a weekday, holiday or entry that does not exist.
    case unknownScheduleItem
    /// Payments are append-only: they are never deleted, only added to.
    case paymentsCannotBeDeleted
    /// A delete that would take a recorded payment with it (law 60, QA F148): an invoice holding
    /// one (`customer == false`), or a customer with such an invoice (`customer == true`). Both
    /// carry the server's one reason, `has_payments`; only the sentence differs.
    case hasRecordedPayments(customer: Bool)
    /// The delete would carry more rows than the server takes in one delete (500).
    case tooMuchToDelete
    /// Documents: this slot has no "good through" date.
    case noExpiry

    /// The developer's name for the refusal — stable, never localized. Logged, and what a tool
    /// hands the model as its `reason`.
    var code: String {
        switch self {
        case .readOnly(_, let lapsed): return lapsed ? "read_only_lapsed" : "read_only_offline"
        case .freeLimitReached: return "free_limit_reached"
        case .recordNotFound: return "record_not_found"
        case .nameRequired: return "name_required"
        case .personNameRequired: return "person_name_required"
        case .projectNameRequired: return "project_name_required"
        case .negativeValue: return "negative_value"
        case .percentOutOfRange: return "percent_out_of_range"
        case .amountRequired: return "amount_required"
        case .hoursAndRateRequired: return "hours_and_rate_required"
        case .projectBelongsToAnotherCustomer: return "project_other_customer"
        case .paidLocked: return "paid_locked"
        case .changeOrderLinesReadOnly: return "change_order_lines_read_only"
        case .titleRequired: return "title_required"
        case .itemRequired: return "item_required"
        case .exceedsBalance: return "exceeds_balance"
        case .optionsRequired: return "options_required"
        case .changeOrderNotApproved: return "change_order_not_approved"
        case .customerRequired: return "customer_required"
        case .jobBelongsToAnotherCustomer: return "job_other_customer"
        case .receiptDetailsRequired: return "receipt_details_required"
        case .itemNameRequired: return "item_name_required"
        case .businessNameRequired: return "business_name_required"
        case .contactRequired: return "contact_required"
        case .invalidHours: return "invalid_hours"
        case .invalidDateRange: return "invalid_date_range"
        case .unknownScheduleItem: return "unknown_schedule_item"
        case .paymentsCannotBeDeleted: return "payment_append_only"
        case .hasRecordedPayments: return "has_payments"
        case .tooMuchToDelete: return "cascade_too_large"
        case .noExpiry: return "no_expiry"
        }
    }

    /// `MBLocalization.string`, not `mbLoc`: this enum is nonisolated, so it reads the chosen
    /// language through the static path (the StripeBackendError pattern).
    var errorDescription: String? { MBLocalization.string(message) }

    /// The same sentence, unresolved — what the assistant's activity card draws (laws 1–2: a
    /// refusal shown in a "Not done" row is localized when it is drawn, not when it is thrown).
    var personReason: LocalizedStringResource { LocalizedStringResource(message, bundle: .main) }

    /// The person's half of the refusal, as its catalog key. One table, read two ways.
    var message: String.LocalizationValue {
        switch self {
        case .readOnly(_, let lapsed):
            return lapsed
                ? "This needs an active subscription. Nothing can be added or changed until you reactivate."
                : "This needs an internet connection. Nothing can be added or changed until you reconnect."
        case .freeLimitReached:
            return "You’ve reached the free limit for this. Subscribe to add more."
        case .recordNotFound:
            return "That record isn’t here anymore. It may have been deleted."
        case .nameRequired:
            return "Enter a first name, last name, or business name."
        case .personNameRequired:
            return "Enter a first or last name."
        case .projectNameRequired:
            return "Enter a project name."
        case .negativeValue:
            return "Amounts, rates, and hours can’t be negative."
        case .percentOutOfRange:
            return "A percentage has to be between 0 and 100."
        case .amountRequired:
            return "Enter an amount greater than zero."
        case .hoursAndRateRequired:
            return "Enter hours and a pay rate greater than zero."
        case .projectBelongsToAnotherCustomer:
            return "That project belongs to a different customer."
        case .paidLocked:
            return "This is part of a paid invoice, so it can’t be changed."
        case .changeOrderLinesReadOnly:
            return "Change order items can only be changed on the change order."
        case .titleRequired:
            return "Enter a job title."
        case .itemRequired:
            return "Add at least one item with a description."
        case .exceedsBalance:
            return "That’s more than the balance due. Enter the balance due or less."
        case .optionsRequired:
            return "Choose at least one option to put on the invoice."
        case .changeOrderNotApproved:
            return "Approve this change order before adding it to the invoice."
        case .customerRequired:
            return "Choose a customer for this job."
        case .jobBelongsToAnotherCustomer:
            return "That job belongs to a different customer."
        case .receiptDetailsRequired:
            return "Enter a vendor or a total, or add a photo of the receipt."
        case .itemNameRequired:
            return "Enter a name for this item."
        case .businessNameRequired:
            return "Enter your business name."
        case .contactRequired:
            return "Enter an email or a phone number."
        case .invalidHours:
            return "The start time has to be before the end time."
        case .invalidDateRange:
            return "The end date can’t be before the start date."
        case .unknownScheduleItem:
            return "That isn’t part of your work schedule."
        case .paymentsCannotBeDeleted:
            return "Payments can’t be deleted once they’re recorded."
        case .hasRecordedPayments(let customer):
            return customer
                ? "This customer has invoices with recorded payments, so they can’t be deleted."
                : "This invoice has recorded payments, so it can’t be deleted."
        case .tooMuchToDelete:
            return "This has too much attached to delete in one step. Delete some of the records under it first, then try again."
        case .noExpiry:
            return "This document doesn’t have an expiry date."
        }
    }
}
