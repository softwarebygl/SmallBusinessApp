//
//  MBRecordDTO.swift
//  GLSmallBusiness — AI
//
//  The ONLY shapes a record takes on its way to the model: hand-written allowlists, one per kind,
//  field by field (contract §5). Nothing here reflects over a model, so a property added to a
//  model later never reaches the model by accident.
//
//  Quarantine (contract §5) — never serialized, by construction (no line below reads them):
//    • UserProfile, all of it (the Gold Life ID person);
//    • BusinessProfile owner name, every w9* field, the tax ID, the Stripe account id / claim /
//      charges flag, the logo blobs, the number counters;
//    • Subcontractor tinKey / w9* / the Keychain tax ID;
//    • every `Data` blob (certificates, photos, scans, documents, the master agreement): only
//      "is one on file" booleans and dates cross;
//    • Invoice stripe* fields and the payment's link id (only "paid through the card link" as a
//      boolean), signatures, tokens.
//  `QuarantineTests` serializes every output below for a fully populated record of every kind and
//  fails on a key that looks like any of those, or on a value that looks like an encoded blob.
//
//  Key names avoid the quarantine test's words even for harmless flags (a "logo" toggle is
//  `company_mark_*`, the receipt's scanned words are `receipt_text`): the test is a tripwire on
//  the words themselves, and a harmless key that trips it would teach people to ignore it.
//
//  `row` = one compact line for `find` (≈ 150–250 bytes). `detail` = everything `get` returns.
//  Ids are the records' `syncID`s, minted on first read (`MBIDs`).
//

import Foundation
import SwiftData
import GoldLifeAI
import GoldLifeUI

@MainActor
struct MBRecordDTO {
    let env: MBToolEnvironment
    let v: MBValue
    /// The effective work schedule (job end days), read once per call.
    let schedule: WorkSchedule

    init(env: MBToolEnvironment, context: ModelContext) {
        self.env = env
        self.v = MBValue(calendar: env.calendar)
        self.schedule = WorkScheduleService.current(in: context, legacyMask: env.legacyMask())
    }

    // MARK: - Shared spellings

    func estimateStatus(_ estimate: Estimate) -> String {
        estimate.isExpired ? "expired" : estimate.status.rawValue
    }

    /// Paid > overdue > partially paid > the stored status — the order the invoice screens show.
    func invoiceStatus(_ invoice: Invoice) -> String {
        if invoice.isPaid { return "paid" }
        if invoice.isOverdue { return "overdue" }
        if invoice.isPartiallyPaid { return "partiallyPaid" }
        return invoice.status.rawValue
    }

    /// The required deposit the app works out (`Estimate.depositAmount`), in whole cents rounded
    /// half-up like every money figure in the app (law 60) — null when there is none, and on an
    /// options estimate (the deposit would be sized on every option added together; the screens
    /// never show it and "Convert to Invoice" never asks for it). The same cents as the estimate
    /// screen and PDF: a $2,000.05 total at 50% is a $1,000.03 deposit everywhere.
    func depositDue(_ estimate: Estimate) -> GLAIJSON {
        guard !estimate.isOptionsMode else { return .null }
        let deposit = estimate.depositAmount
        return deposit > 0 ? v.money(deposit) : .null
    }

    /// The amount the invoice asks for now (a deposit or milestone, capped at the balance) — null
    /// when it asks for the whole balance. Rounded like `depositDue(_:)`: the same cents the invoice
    /// screen, PDF and email show and the pay link charges.
    func amountDueNow(_ invoice: Invoice) -> GLAIJSON {
        invoice.hasAmountDueRequest ? v.money(invoice.currentAmountDue) : .null
    }

    func ref(_ customer: Customer?) -> GLAIJSON {
        guard let customer, !customer.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(customer, env)), "name": v.text(customer.listDisplayName, limit: 120)]
    }

    func ref(_ job: ScheduledJob?) -> GLAIJSON {
        guard let job, !job.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(job, env)), "title": v.text(job.displayTitle, limit: 120)]
    }

    func ref(_ invoice: Invoice?) -> GLAIJSON {
        guard let invoice, !invoice.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(invoice, env)), "number": .string(invoice.number)]
    }

    func ref(_ estimate: Estimate?) -> GLAIJSON {
        guard let estimate, !estimate.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(estimate, env)), "number": .string(estimate.number)]
    }

    func ref(_ contract: Contract?) -> GLAIJSON {
        guard let contract, !contract.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(contract, env)), "number": .string(contract.number)]
    }

    func ref(_ project: Project?) -> GLAIJSON {
        guard let project, !project.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(project, env)), "name": v.text(project.displayName, limit: 120)]
    }

    func ref(_ employee: Employee?) -> GLAIJSON {
        guard let employee, !employee.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(employee, env)), "name": v.text(employee.fullName, limit: 120)]
    }

    func ref(_ sub: Subcontractor?) -> GLAIJSON {
        guard let sub, !sub.isDeleted else { return .null }
        return ["id": .string(MBIDs.id(sub, env)), "name": v.text(sub.listDisplayName, limit: 120)]
    }

    /// A certificate slot: on file, the "good through" date, and whether it has run out or runs
    /// out within 30 days. Never the file.
    func certificate(onFile: Bool, expiresOn: Date?) -> GLAIJSON {
        [
            "on_file": .bool(onFile),
            "expires_on": v.day(expiresOn),
            "expired": .bool(GLCertificateStatus.isExpired(expiresOn)),
            "expiring_soon": .bool(GLCertificateStatus.isExpiringSoon(expiresOn)),
        ]
    }

    func recurrence(_ job: ScheduledJob) -> GLAIJSON {
        guard let frequency = job.recurrenceFrequency else { return .null }
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekdays = (0..<7).filter { job.recurrenceWeekdayMask & (1 << $0) != 0 }.map { GLAIJSON.string(names[$0]) }
        return [
            "frequency": .string(frequency.rawValue),
            "weekdays": .array(weekdays),
            "ends_on": v.day(job.recurrenceEndDate),
            "visits": job.recurrenceCount > 0 ? v.int(job.recurrenceCount) : .null,
            "open_ended": .bool(job.isOpenEndedRecurrence),
        ]
    }

    // MARK: - Rows (find)

    // The write tools hand back these rows, so a row carries every figure the app works out that
    // the person may be told (the total after a discount, the deposit, the amount due now): the
    // model repeats the app's numbers and never has to do the math itself.

    func row(_ customer: Customer) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(customer, env)),
            "name": v.text(customer.fullName, limit: 120),
            "business": v.text(customer.businessName ?? "", limit: 120),
            "phone": v.text(customer.phoneNumber, limit: 40),
            "email": v.text(customer.email, limit: 120),
            "owes": v.money(customer.outstanding),
        ]
    }

    func row(_ estimate: Estimate) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(estimate, env)),
            "number": .string(estimate.number),
            "title": v.text(estimate.jobTitle, limit: 120),
            "customer": ref(estimate.customer),
            "customer_name": v.text(estimate.customerDisplayName, limit: 120),
            "status": .string(estimateStatus(estimate)),
            "total": estimate.isOptionsMode ? .null : v.money(estimate.total),
            "deposit": depositDue(estimate),
            "options": .bool(estimate.isOptionsMode),
            "created": v.day(estimate.createdAt),
            "valid_until": v.day(estimate.validUntil),
        ]
    }

    func row(_ contract: Contract) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(contract, env)),
            "number": .string(contract.number),
            "title": v.text(contract.displayTitle, limit: 120),
            "customer": ref(contract.customer),
            "customer_name": v.text(contract.displayCustomerName, limit: 120),
            "status": .string(contract.status.rawValue),
            "total": v.money(contract.contractedValue),
            "invoiced": v.money(contract.invoicedTotal),
            "remaining_to_invoice": v.money(contract.remainingToInvoice),
            "balance_due": v.money(contract.balanceDue),
            "customer_signed": .bool(contract.isSigned),
            "start_date": v.day(contract.startDate),
            "created": v.day(contract.createdAt),
        ]
    }

    func row(_ invoice: Invoice) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(invoice, env)),
            "number": .string(invoice.number),
            "title": v.text(invoice.jobTitle, limit: 120),
            "customer": ref(invoice.customer),
            "customer_name": v.text(invoice.customerDisplayName, limit: 120),
            "status": .string(invoiceStatus(invoice)),
            "total": v.money(invoice.total),
            "balance_due": v.money(invoice.balanceDue),
            "amount_due_now": amountDueNow(invoice),
            "due_date": v.day(invoice.dueDate),
            "created": v.day(invoice.createdAt),
        ]
    }

    func row(_ order: ChangeOrder) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(order, env)),
            "number": .string(order.number),
            "title": v.text(order.title, limit: 120),
            "invoice": ref(order.invoice),
            "contract": ref(order.contract),
            "status": .string(order.status.rawValue),
            "total": v.money(order.total),
            "added_to_invoice": .bool(order.appliedToInvoice),
        ]
    }

    func row(_ job: ScheduledJob) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(job, env)),
            "title": v.text(job.displayTitle, limit: 120),
            "customer": ref(job.customer),
            "customer_name": v.text(job.customerName, limit: 120),
            "status": .string(job.status.rawValue),
            "start_date": v.day(job.startDate),
            "end_date": v.day(job.endDay(schedule: schedule, calendar: env.calendar)),
            "all_day": .bool(job.isAllDay),
            "start_time": job.isAllDay ? .null : job.startTime.map(v.clock) ?? .null,
            "repeats": .bool(job.isRecurring),
            "agreed_price": job.agreedPrice.map(v.money) ?? .null,
        ]
    }

    func row(_ receipt: Receipt) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(receipt, env)),
            "vendor": v.text(receipt.displayVendor, limit: 120),
            "date": v.day(receipt.date),
            "total": v.money(receipt.total),
            "category": v.text(receipt.category, limit: 60),
            "customer": ref(receipt.customer),
            "job": ref(receipt.job),
            "contract": ref(receipt.contract),
        ]
    }

    func row(_ item: PriceSheetItem) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(item, env)),
            "name": v.text(item.name, limit: 120),
            "category": .string(PriceSheetService.groupName(item)),
            "unit": .string(item.unit.rawValue),
            "unit_price": v.rate(item.unitPrice),
            "kind": .string(item.kind.rawValue),
            "taxable": .bool(item.isTaxable),
        ]
    }

    func row(_ employee: Employee) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(employee, env)),
            "name": v.text(employee.fullName, limit: 120),
            "phone": v.text(employee.phone, limit: 40),
            "pay_type": .string(employee.payType.rawValue),
            "hourly_rate": employee.payType == .hourly ? v.rate(employee.hourlyRate) : .null,
            "annual_salary": employee.payType == .salary ? v.money(employee.annualSalary) : .null,
            "active": .bool(employee.isActive),
            "owed": v.money(employee.accruedGross),
        ]
    }

    func row(_ sub: Subcontractor) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(sub, env)),
            "name": v.text(sub.fullName, limit: 120),
            "business": v.text(sub.businessName, limit: 120),
            "phone": v.text(sub.phone, limit: 40),
            "active": .bool(sub.isActive),
            "owed": v.money(sub.outstanding),
        ]
    }

    func row(_ project: Project) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(project, env)),
            "name": v.text(project.displayName, limit: 120),
            "customer": ref(project.customer),
            "jobs": v.int(project.sortedJobs.count),
            "balance_due": v.money(project.balanceDue),
        ]
    }

    func row(_ payment: InvoicePayment) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(payment, env)),
            "invoice": ref(payment.invoice),
            "customer": ref(payment.invoice?.customer),
            "amount": v.money(payment.amount),
            "date": v.day(payment.date),
            "method": .string(payment.method.rawValue),
        ]
    }

    func row(_ entry: TimeEntry) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(entry, env)),
            "employee": ref(entry.employee),
            "date": v.day(entry.date),
            "hours": v.number(entry.hours),
            "amount": v.money(entry.grossValue),
            "bonus": .bool(entry.amount > DomainMoney.epsilon),
            "customer": ref(entry.customer),
            "paid": .bool(entry.paycheck != nil),
        ]
    }

    func row(_ paycheck: Paycheck) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(paycheck, env)),
            "employee": ref(paycheck.employee),
            "pay_date": v.day(paycheck.payDate),
            "gross": v.money(paycheck.grossAmount),
            "hours": v.number(paycheck.hoursPaid),
            "method": .string(paycheck.method.rawValue),
        ]
    }

    func row(_ entry: SubPayment) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(entry, env)),
            "subcontractor": ref(entry.subcontractor),
            "date": v.day(entry.date),
            "amount": v.money(entry.amount),
            "hours": v.number(entry.hours),
            "paid": .bool(entry.isPaid),
            "paid_date": v.day(entry.paidDate),
            "customer": ref(entry.customer),
        ]
    }

    func row(_ attachment: JobAttachment) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(attachment, env)),
            "kind": .string(attachment.kind.rawValue),
            "name": v.text(attachment.name, limit: 120),
            "caption": v.text(attachment.caption, limit: 160),
            "job": ref(attachment.job),
            "invoice": ref(attachment.invoice),
            "contract": ref(attachment.contract),
            "added": v.day(attachment.createdAt),
        ]
    }

    func row(_ document: CustomerDocument) -> GLAIJSON {
        [
            "id": .string(MBIDs.id(document, env)),
            "name": v.text(document.name, limit: 120),
            "customer": ref(document.customer),
            "added": v.day(document.createdAt),
        ]
    }

    // MARK: - Details (get)

    func detail(_ customer: Customer) -> [String: GLAIJSON] {
        let estimates = customer.liveRows(customer.estimates).sorted { $0.createdAt > $1.createdAt }
        let contracts = customer.liveRows(customer.contracts).sorted { $0.createdAt > $1.createdAt }
        let invoices = customer.liveRows(customer.invoices).sorted { $0.createdAt > $1.createdAt }
        let jobs = customer.liveRows(customer.scheduledJobs).sorted { $0.startDate > $1.startDate }
        let projects = customer.liveRows(customer.projects)
        return [
            "kind": "customer",
            "id": .string(MBIDs.id(customer, env)),
            "first_name": v.text(customer.firstName, limit: 80),
            "middle_name": v.text(customer.middleName, limit: 80),
            "last_name": v.text(customer.lastName, limit: 80),
            "business": v.text(customer.businessName ?? "", limit: 120),
            "email": v.text(customer.email, limit: 120),
            "mobile_phone": v.text(customer.phoneNumber, limit: 40),
            "office_phone": v.text(customer.officePhone, limit: 40),
            "address": v.address(customer.address),
            "service_address": v.address(customer.serviceAddress),
            "same_as_billing_address": .bool(customer.sameAsBillingAddress),
            "created": v.day(customer.createdAt),
            "owes": v.money(customer.outstanding),
            "paid_to_date": v.money(customer.totalPaidToUs),
            "has_paid_invoice": .bool(customer.hasPaidInvoice),
            "general_liability_certificate": certificate(onFile: customer.hasCOI, expiresOn: customer.coiExpiresOn),
            "workers_comp_certificate": certificate(onFile: customer.hasWCCOI, expiresOn: customer.wcCoiExpiresOn),
            "package_documents": v.int(customer.sortedPackageDocuments.count),
            "receipts": v.int(customer.liveRows(customer.receipts).count),
            "estimate_count": v.int(estimates.count),
            "contract_count": v.int(contracts.count),
            "invoice_count": v.int(invoices.count),
            "job_count": v.int(jobs.count),
            "estimates": .array(estimates.prefix(15).map {
                ["id": .string(MBIDs.id($0, env)), "number": .string($0.number),
                 "status": .string(estimateStatus($0)), "total": $0.isOptionsMode ? .null : v.money($0.total)]
            }),
            "contracts": .array(contracts.prefix(15).map {
                ["id": .string(MBIDs.id($0, env)), "number": .string($0.number),
                 "status": .string($0.status.rawValue), "total": v.money($0.contractedValue)]
            }),
            "invoices": .array(invoices.prefix(15).map {
                ["id": .string(MBIDs.id($0, env)), "number": .string($0.number),
                 "status": .string(invoiceStatus($0)), "balance_due": v.money($0.balanceDue)]
            }),
            "jobs": .array(jobs.prefix(15).map {
                ["id": .string(MBIDs.id($0, env)), "title": v.text($0.displayTitle, limit: 120),
                 "status": .string($0.status.rawValue), "start_date": v.day($0.startDate)]
            }),
            "projects": .array(projects.prefix(10).map { ref($0) }),
        ]
    }

    /// An estimate's header (without lines — `get` pages those).
    func detail(_ estimate: Estimate, context: ModelContext) -> [String: GLAIJSON] {
        let options = estimate.isOptionsMode
        var totals: GLAIJSON = [
            "subtotal": v.money(estimate.subtotal),
            "discount": v.money(estimate.discountAmount),
            "tax": v.money(estimate.taxAmount),
            "total": v.money(estimate.total),
            "deposit": v.money(estimate.depositAmount),
        ]
        if options {
            totals = ["note": "Options estimate: each group is its own choice with its own total; there is no single total."]
        }
        let groups = estimate.sortedGroups.map { group -> GLAIJSON in
            var object: [String: GLAIJSON] = [
                "id": .string(MBIDs.id(group, env)),
                "name": v.text(group.name, limit: 120),
                "note": v.text(group.note, limit: 300),
                "subtotal": v.money(group.subtotal),
                "lines": v.int(group.sortedLineItems.count),
            ]
            if options { object["option_total"] = v.money(group.optionTotals(taxRatePercent: estimate.taxRatePercent).total) }
            return .object(object)
        }
        return [
            "kind": "estimate",
            "id": .string(MBIDs.id(estimate, env)),
            "number": .string(estimate.number),
            "title": v.text(estimate.jobTitle, limit: 160),
            "status": .string(estimateStatus(estimate)),
            "created": v.day(estimate.createdAt),
            "valid_until": v.day(estimate.validUntil),
            "customer": ref(estimate.customer),
            "customer_name": v.text(estimate.customerDisplayName, limit: 120),
            "customer_email": v.text(estimate.recipientEmail, limit: 120),
            "customer_phone": v.text(estimate.recipientPhone, limit: 40),
            "customer_address": v.address(estimate.customerAddress),
            "service_address": v.address(estimate.serviceAddress),
            "combine_totals": .bool(estimate.combineTotals),
            "options": .bool(options),
            "tax_rate": v.rate(estimate.taxRatePercent),
            "discount": ["type": .string(estimate.discountType.rawValue), "value": v.number(estimate.discountValue)],
            "deposit": ["type": .string(estimate.depositType.rawValue), "value": v.number(estimate.depositValue)],
            "totals": totals,
            "notes": v.text(estimate.customerNotes, limit: 800),
            "terms": v.text(estimate.terms, limit: 800),
            "groups": .array(groups),
            "invoice": ref(EstimateService.existingInvoice(convertedFrom: estimate, in: context)),
            "jobs": .array(estimate.liveRows(estimate.scheduledJobs).prefix(10).map { ref($0) }),
        ]
    }

    func lines(_ estimate: Estimate) -> [GLAIJSON] {
        estimate.sortedGroups.flatMap { group in
            group.sortedLineItems.map { line -> GLAIJSON in
                [
                    "id": .string(MBIDs.id(line, env)),
                    "group_id": .string(MBIDs.id(group, env)),
                    "name": v.text(line.name, limit: 160),
                    "details": v.text(line.details, limit: 300),
                    "quantity": v.rate(line.quantity),
                    "unit": .string(line.unit.rawValue),
                    "unit_price": v.rate(line.unitPrice),
                    "kind": .string(line.kind.rawValue),
                    "taxable": .bool(line.isTaxable),
                    "discount": ["type": .string(line.discountType.rawValue), "value": v.number(line.discountValue)],
                    "line_total": v.money(line.lineTotal),
                ]
            }
        }
    }

    /// A contract's header (without lines — `get` pages those).
    func detail(_ contract: Contract) -> [String: GLAIJSON] {
        let invoices = contract.liveRows(contract.billingInvoices).sorted { $0.createdAt < $1.createdAt }
        let orders = contract.sortedChangeOrders
        let attachments = contract.sortedAttachments
        let receipts = contract.liveRows(contract.receipts).sorted { $0.date > $1.date }
        let groups = contract.sortedGroups.map { group -> GLAIJSON in
            [
                "id": .string(MBIDs.id(group, env)),
                "name": v.text(group.name, limit: 120),
                "note": v.text(group.note, limit: 300),
                "subtotal": v.money(group.subtotal),
                "lines": v.int(group.sortedLineItems.count),
            ]
        }
        return [
            "kind": "contract",
            "id": .string(MBIDs.id(contract, env)),
            "number": .string(contract.number),
            "title": v.text(contract.displayTitle, limit: 160),
            "status": .string(contract.status.rawValue),
            "created": v.day(contract.createdAt),
            "completed_on": v.day(contract.completedAt),
            "customer": ref(contract.customer),
            "customer_name": v.text(contract.displayCustomerName, limit: 120),
            "customer_email": v.text(contract.recipientEmail, limit: 120),
            "customer_phone": v.text(contract.recipientPhone, limit: 40),
            "service_address": v.address(contract.serviceAddress),
            "from_estimate": ref(contract.estimate),
            "job": ref(contract.scheduledJob),
            "start_date": v.day(contract.startDate),
            "workdays": v.int(contract.durationDays),
            "all_day": .bool(contract.isAllDay),
            "start_time": contract.isAllDay ? .null : contract.startTime.map(v.clock) ?? .null,
            "duration_minutes": contract.isAllDay ? .null : contract.durationMinutes.map(v.int) ?? .null,
            "agreed_price": contract.agreedPrice.map(v.money) ?? .null,
            "tax_rate": v.rate(contract.taxRatePercent),
            "customer_signed": .bool(contract.isSigned),
            "physical_autograph": .bool(contract.hasPhysicalSignature),
            "signer_name": v.text(contract.signerName, limit: 120),
            "signed_at": v.day(contract.signedAt),
            "totals": [
                "contracted": v.money(contract.contractedValue),
                "invoiced": v.money(contract.invoicedTotal),
                "collected": v.money(contract.amountPaid),
                "remaining_to_invoice": v.money(contract.remainingToInvoice),
                "balance_due": v.money(contract.balanceDue),
            ],
            "notes": v.text(contract.notes, limit: 800),
            "terms": v.text(contract.terms, limit: 800),
            "groups": .array(groups),
            "invoices": .array(invoices.prefix(15).map { invoice -> GLAIJSON in
                ["id": .string(MBIDs.id(invoice, env)), "number": .string(invoice.number),
                 "status": .string(invoiceStatus(invoice)), "total": v.money(invoice.total),
                 "balance_due": v.money(invoice.balanceDue)]
            }),
            "change_orders": .array(orders.prefix(20).map { row($0) }),
            "receipts": .array(receipts.prefix(15).map { receipt -> GLAIJSON in
                ["id": .string(MBIDs.id(receipt, env)), "vendor": v.text(receipt.displayVendor, limit: 120),
                 "total": v.money(receipt.total), "date": v.day(receipt.date)]
            }),
            "attachments": .array(attachments.prefix(15).map { attachment -> GLAIJSON in
                ["id": .string(MBIDs.id(attachment, env)), "kind": .string(attachment.kind.rawValue),
                 "name": v.text(attachment.name, limit: 120), "caption": v.text(attachment.caption, limit: 160)]
            }),
        ]
    }

    func lines(_ contract: Contract) -> [GLAIJSON] {
        contract.sortedGroups.flatMap { group in
            group.sortedLineItems.map { line -> GLAIJSON in
                [
                    "id": .string(MBIDs.id(line, env)),
                    "group_id": .string(MBIDs.id(group, env)),
                    "name": v.text(line.name, limit: 160),
                    "details": v.text(line.details, limit: 300),
                    "quantity": v.rate(line.quantity),
                    "unit": .string(line.unit.rawValue),
                    "unit_price": v.rate(line.unitPrice),
                    "kind": .string(line.kind.rawValue),
                    "taxable": .bool(line.isTaxable),
                    "from_change_order": .bool(line.fromChangeOrder),
                    "line_total": v.money(line.total),
                ]
            }
        }
    }

    /// An invoice's header (without lines — `get` pages those).
    func detail(_ invoice: Invoice) -> [String: GLAIJSON] {
        let payments = invoice.sortedPayments
        let orders = invoice.sortedChangeOrders
        let attachments = invoice.liveRows(invoice.attachments).sorted { $0.createdAt > $1.createdAt }
        let groups = invoice.sortedGroups.map { group -> GLAIJSON in
            [
                "id": .string(MBIDs.id(group, env)),
                "name": v.text(group.name, limit: 120),
                "note": v.text(group.note, limit: 300),
                // As the invoice screen and PDF show it: a change-order credit keeps its sign.
                "subtotal": v.money(group.shownSubtotal),
                "lines": v.int(group.sortedLineItems.count),
                "change_order_id": group.changeOrder.map { .string(MBIDs.id($0, env)) } ?? .null,
            ]
        }
        return [
            "kind": "invoice",
            "id": .string(MBIDs.id(invoice, env)),
            "number": .string(invoice.number),
            "title": v.text(invoice.jobTitle, limit: 160),
            "status": .string(invoiceStatus(invoice)),
            "stored_status": .string(invoice.status.rawValue),
            "created": v.day(invoice.createdAt),
            "payment_terms": .string(invoice.paymentTerms.rawValue),
            "due_date": v.day(invoice.dueDate),
            "customer": ref(invoice.customer),
            "customer_name": v.text(invoice.customerDisplayName, limit: 120),
            "customer_email": v.text(invoice.recipientEmail, limit: 120),
            "customer_phone": v.text(invoice.recipientPhone, limit: 40),
            "customer_address": v.address(invoice.customerAddress),
            "service_address": v.address(invoice.serviceAddress),
            "from_estimate_number": invoice.sourceEstimateNumber.map { .string($0) } ?? .null,
            "contract": ref(invoice.contract),
            "job": ref(invoice.job),
            "tax_rate": v.rate(invoice.taxRatePercent),
            "discount": ["type": .string(invoice.discountType.rawValue), "value": v.number(invoice.discountValue)],
            "totals": [
                "subtotal": v.money(invoice.subtotal),
                "discount": v.money(invoice.discountAmount),
                "tax": v.money(invoice.taxAmount),
                "total": v.money(invoice.total),
                "paid": v.money(invoice.amountPaid),
                "balance_due": v.money(invoice.balanceDue),
                "approved_change_orders_not_added": v.money(invoice.approvedChangeOrderTotal),
                "revised_total": v.money(invoice.revisedTotal),
            ],
            "amount_due_now": amountDueNow(invoice),
            "amount_due_detail": v.text(invoice.amountDueDetail, limit: 200),
            "pay_button": .bool(invoice.includePayLink),
            "include_zelle": .bool(invoice.includeZelle),
            "is_marked_past_due": .bool(invoice.isMarkedPastDue),
            "auto_reminders_enabled": .bool(invoice.autoRemindersEnabled),
            "reminder_start_trigger": .string(invoice.reminderStartTrigger.rawValue),
            "reminder_frequency": .string(invoice.reminderFrequency.rawValue),
            "paid_in_full": .bool(invoice.isPaid),
            "locked_paid": .bool(invoice.isMoneyLocked),
            "notes": v.text(invoice.customerNotes, limit: 800),
            "terms": v.text(invoice.terms, limit: 800),
            "groups": .array(groups),
            "payment_count": v.int(payments.count),
            "payments": .array(payments.suffix(20).reversed().map { payment -> GLAIJSON in
                [
                    "id": .string(MBIDs.id(payment, env)),
                    "amount": v.money(payment.amount),
                    "date": v.day(payment.date),
                    "method": .string(payment.method.rawValue),
                    "note": v.text(payment.note, limit: 160),
                ]
            }),
            "change_orders": .array(orders.prefix(20).map { row($0) }),
            "attachments": .array(attachments.prefix(20).map { attachment -> GLAIJSON in
                ["id": .string(MBIDs.id(attachment, env)), "kind": .string(attachment.kind.rawValue),
                 "name": v.text(attachment.name, limit: 120)]
            }),
        ]
    }

    func lines(_ invoice: Invoice) -> [GLAIJSON] {
        invoice.sortedGroups.flatMap { group in
            group.sortedLineItems.map { line -> GLAIJSON in
                [
                    "id": .string(MBIDs.id(line, env)),
                    "group_id": .string(MBIDs.id(group, env)),
                    "name": v.text(line.name, limit: 160),
                    "details": v.text(line.details, limit: 300),
                    "quantity": v.rate(line.quantity),
                    "unit": .string(line.unit.rawValue),
                    "unit_price": v.rate(line.unitPrice),
                    "kind": .string(line.kind.rawValue),
                    "taxable": .bool(line.isTaxable),
                    "discount": ["type": .string(line.discountType.rawValue), "value": v.number(line.discountValue)],
                    "from_change_order": .bool(line.fromChangeOrder),
                    // Change-order lines keep their sign (a credit is negative); others floor at 0.
                    "line_total": v.money(line.fromChangeOrder ? line.signedLineTotal : line.lineTotal),
                ]
            }
        }
    }

    func detail(_ order: ChangeOrder) -> [String: GLAIJSON] {
        [
            "kind": "change_order",
            "id": .string(MBIDs.id(order, env)),
            "number": .string(order.number),
            "title": v.text(order.title, limit: 160),
            "note": v.text(order.note, limit: 800),
            "status": .string(order.status.rawValue),
            "created": v.day(order.createdAt),
            "invoice": ref(order.invoice),
            "contract": ref(order.contract),
            "customer": ref(order.invoice?.customer ?? order.contract?.customer),
            "tax_rate": v.rate(order.taxRatePercent),
            "added_to_invoice": .bool(order.appliedToInvoice),
            "locked_paid": .bool(order.isBilledToLockedInvoice),
            "subtotal": v.money(order.subtotal),
            "tax": v.money(order.taxAmount),
            "total": v.money(order.total),
            "lines": .array(order.sortedLineItems.map { line -> GLAIJSON in
                [
                    "id": .string(MBIDs.id(line, env)),
                    "name": v.text(line.name, limit: 160),
                    "details": v.text(line.details, limit: 300),
                    "quantity": v.rate(line.quantity),
                    "unit": .string(line.unit.rawValue),
                    "unit_price": v.rate(abs(line.unitPrice)),
                    "is_credit": .bool(line.unitPrice < 0),
                    "taxable": .bool(line.isTaxable),
                    "line_total": v.money(line.lineTotal),
                ]
            }),
        ]
    }

    func detail(_ job: ScheduledJob) -> [String: GLAIJSON] {
        let invoices = job.liveRows(job.billingInvoices).sorted { $0.createdAt < $1.createdAt }
        let attachments = job.liveRows(job.attachments).sorted { $0.createdAt > $1.createdAt }
        return [
            "kind": "job",
            "id": .string(MBIDs.id(job, env)),
            "title": v.text(job.displayTitle, limit: 160),
            "customer": ref(job.customer),
            "customer_name": v.text(job.customerName, limit: 120),
            "status": .string(job.status.rawValue),
            "completed_on": v.day(job.completedAt),
            "start_date": v.day(job.startDate),
            "end_date": v.day(job.endDay(schedule: schedule, calendar: env.calendar)),
            "workdays": v.int(job.durationDays),
            "all_day": .bool(job.isAllDay),
            "start_time": job.isAllDay ? .null : job.startTime.map(v.clock) ?? .null,
            "duration_minutes": job.isAllDay ? .null : job.durationMinutes.map(v.int) ?? .null,
            "repeats": recurrence(job),
            "service_address": v.address(job.serviceAddress),
            "notes": v.text(job.notes, limit: 800),
            "agreed_price": job.agreedPrice.map(v.money) ?? .null,
            "project": ref(job.project),
            "from_estimate": ref(job.estimate),
            "from_invoice": ref(job.invoice),
            "billing": [
                "contracted": v.money(job.contractedValue),
                "invoiced": v.money(job.invoicedTotal),
                "collected": v.money(job.amountPaid),
                "left_to_invoice": v.money(job.remainingToInvoice),
                "balance_due": v.money(job.balanceDue),
                "paid_in_full": .bool(job.isFullyBilledAndCollected),
            ],
            "invoices": .array(invoices.prefix(15).map { invoice -> GLAIJSON in
                ["id": .string(MBIDs.id(invoice, env)), "number": .string(invoice.number),
                 "status": .string(invoiceStatus(invoice)), "total": v.money(invoice.total),
                 "balance_due": v.money(invoice.balanceDue)]
            }),
            "receipts": .array(job.sortedReceipts.prefix(15).map { receipt -> GLAIJSON in
                ["id": .string(MBIDs.id(receipt, env)), "vendor": v.text(receipt.displayVendor, limit: 120),
                 "total": v.money(receipt.total), "date": v.day(receipt.date)]
            }),
            "attachments": .array(attachments.prefix(15).map { attachment -> GLAIJSON in
                ["id": .string(MBIDs.id(attachment, env)), "kind": .string(attachment.kind.rawValue),
                 "name": v.text(attachment.name, limit: 120), "caption": v.text(attachment.caption, limit: 160)]
            }),
        ]
    }

    func detail(_ receipt: Receipt) -> [String: GLAIJSON] {
        [
            "kind": "receipt",
            "id": .string(MBIDs.id(receipt, env)),
            "vendor": v.text(receipt.displayVendor, limit: 120),
            "date": v.day(receipt.date),
            "total": v.money(receipt.total),
            "category": v.text(receipt.category, limit: 80),
            "notes": v.text(receipt.notes, limit: 800),
            "customer": ref(receipt.customer),
            "job": ref(receipt.job),
            "contract": ref(receipt.contract),
            "has_attached_file": .bool(receipt.scanData != nil),
            // The words read off the receipt when it was added (contract §4 consent: "receipts incl.
            // scanned text when asked" — a get on one receipt is the asking).
            "receipt_text": v.text(receipt.recognizedText, limit: 2_000),
        ]
    }

    func detail(_ item: PriceSheetItem) -> [String: GLAIJSON] {
        [
            "kind": "price_item",
            "id": .string(MBIDs.id(item, env)),
            "name": v.text(item.name, limit: 160),
            "details": v.text(item.details, limit: 600),
            "category": .string(PriceSheetService.groupName(item)),
            "default_quantity": v.rate(item.defaultQuantity),
            "unit": .string(item.unit.rawValue),
            "unit_price": v.rate(item.unitPrice),
            "kind_of_work": .string(item.kind.rawValue),
            "taxable": .bool(item.isTaxable),
            "discount": ["type": .string(item.discountType.rawValue), "value": v.number(item.discountValue)],
            "net_total": v.money(item.netTotal),
        ]
    }

    func detail(_ employee: Employee) -> [String: GLAIJSON] {
        let now = env.now()
        let year = env.calendar.component(.year, from: now)
        let owed: GLAIJSON = [
            "amount": v.money(employee.accruedGross),
            "unpaid_hours": v.number(employee.unpaidHours),
            "past_due": .bool(employee.owedStatus == .pastDue),
        ]
        return [
            "kind": "employee",
            "id": .string(MBIDs.id(employee, env)),
            "first_name": v.text(employee.firstName, limit: 80),
            "last_name": v.text(employee.lastName, limit: 80),
            "email": v.text(employee.email, limit: 120),
            "phone": v.text(employee.phone, limit: 40),
            "pay_type": .string(employee.payType.rawValue),
            "hourly_rate": v.rate(employee.hourlyRate),
            "annual_salary": v.money(employee.annualSalary),
            "pay_frequency": .string(employee.payFrequency.rawValue),
            "salary_per_period": employee.payType == .salary ? v.money(employee.salaryPerPeriod) : .null,
            "hire_date": v.day(employee.hireDate),
            "active": .bool(employee.isActive),
            "notes": v.text(employee.notes, limit: 600),
            "owed": owed,
            "next_payday": v.day(employee.nextPayday(onOrAfter: now)),
            "paid_this_year": v.money(employee.ytdGross(year: year)),
            "hours_this_year": v.number(employee.ytdHours(year: year)),
            "hours_this_week": v.number(employee.hoursInWeek(of: now)),
            "recent_hours": .array(employee.sortedTimeEntries.prefix(10).map { row($0) }),
            "recent_paychecks": .array(employee.sortedPaychecks.prefix(5).map { row($0) }),
        ]
    }

    func detail(_ sub: Subcontractor) -> [String: GLAIJSON] {
        let year = env.calendar.component(.year, from: env.now())
        return [
            "kind": "subcontractor",
            "id": .string(MBIDs.id(sub, env)),
            "first_name": v.text(sub.firstName, limit: 80),
            "last_name": v.text(sub.lastName, limit: 80),
            "business": v.text(sub.businessName, limit: 120),
            "email": v.text(sub.email, limit: 120),
            "phone": v.text(sub.phone, limit: 40),
            "hourly_rate": v.rate(sub.hourlyRate),
            "address": v.address(sub.address),
            "active": .bool(sub.isActive),
            "notes": v.text(sub.notes, limit: 600),
            "insurance_certificate": certificate(onFile: sub.coiData != nil, expiresOn: sub.coiExpiresOn),
            // Presence only — the form itself and the tax ID never leave the phone.
            "tax_form_on_file": .bool(sub.hasW9OnFile),
            "owed": v.money(sub.outstanding),
            "past_due": .bool(sub.owedStatus == .pastDue),
            "paid_this_year": v.money(sub.totalPaid(year: year)),
            "paid_all_time": v.money(sub.lifetimePaid),
            "needs_1099_this_year": .bool(sub.requires1099(year: year)),
            "recent_work": .array(sub.sortedPayments.prefix(10).map { row($0) }),
        ]
    }

    func detail(_ project: Project) -> [String: GLAIJSON] {
        [
            "kind": "project",
            "id": .string(MBIDs.id(project, env)),
            "name": v.text(project.displayName, limit: 160),
            "customer": ref(project.customer),
            "created": v.day(project.createdAt),
            "agreement_on_file": .bool(project.hasMasterAgreement),
            "contracted": v.money(project.contractedValue),
            "invoiced": v.money(project.invoicedTotal),
            "collected": v.money(project.amountPaid),
            "left_to_invoice": v.money(project.remainingToInvoice),
            "balance_due": v.money(project.balanceDue),
            "jobs": .array(project.sortedJobs.prefix(25).map { job -> GLAIJSON in
                ["id": .string(MBIDs.id(job, env)), "title": v.text(job.displayTitle, limit: 120),
                 "status": .string(job.status.rawValue), "start_date": v.day(job.startDate)]
            }),
        ]
    }

    func detail(_ payment: InvoicePayment) -> [String: GLAIJSON] {
        [
            "kind": "payment",
            "id": .string(MBIDs.id(payment, env)),
            "invoice": ref(payment.invoice),
            "customer": ref(payment.invoice?.customer),
            "amount": v.money(payment.amount),
            "date": v.day(payment.date),
            "method": .string(payment.method.rawValue),
            "note": v.text(payment.note, limit: 400),
            "processing_fee": v.money(payment.processingFee),
            "paid_through_card_link": .bool(!payment.stripePaymentLinkId.isEmpty),
        ]
    }

    func detail(_ entry: TimeEntry) -> [String: GLAIJSON] {
        [
            "kind": "time_entry",
            "id": .string(MBIDs.id(entry, env)),
            "employee": ref(entry.employee),
            "date": v.day(entry.date),
            "hours": v.number(entry.hours),
            "rate": v.rate(entry.rateSnapshot),
            "flat_amount": v.money(entry.amount),
            "value": v.money(entry.grossValue),
            "note": v.text(entry.note, limit: 400),
            "customer": ref(entry.customer),
            "paid": .bool(entry.paycheck != nil),
            "paycheck_id": entry.paycheck.map { .string(MBIDs.id($0, env)) } ?? .null,
        ]
    }

    func detail(_ paycheck: Paycheck) -> [String: GLAIJSON] {
        [
            "kind": "paycheck",
            "id": .string(MBIDs.id(paycheck, env)),
            "employee": ref(paycheck.employee),
            "period_start": v.day(paycheck.payPeriodStart),
            "period_end": v.day(paycheck.payPeriodEnd),
            "pay_date": v.day(paycheck.payDate),
            "gross": v.money(paycheck.grossAmount),
            "hours": v.number(paycheck.hoursPaid),
            "method": .string(paycheck.method.rawValue),
            "note": v.text(paycheck.note, limit: 400),
            "entries_covered": v.int(paycheck.liveRows(paycheck.coveredEntries).count),
        ]
    }

    func detail(_ entry: SubPayment) -> [String: GLAIJSON] {
        [
            "kind": "sub_payment",
            "id": .string(MBIDs.id(entry, env)),
            "subcontractor": ref(entry.subcontractor),
            "date": v.day(entry.date),
            "amount": v.money(entry.amount),
            "hours": v.number(entry.hours),
            "paid": .bool(entry.isPaid),
            "paid_date": v.day(entry.paidDate),
            "method": .string(entry.method.rawValue),
            "detail": v.text(entry.detail, limit: 400),
            "customer": ref(entry.customer),
        ]
    }

    func detail(_ attachment: JobAttachment) -> [String: GLAIJSON] {
        [
            "kind": "attachment",
            "id": .string(MBIDs.id(attachment, env)),
            "type": .string(attachment.kind.rawValue),
            "name": v.text(attachment.name, limit: 160),
            "caption": v.text(attachment.caption, limit: 400),
            "added": v.day(attachment.createdAt),
            "on_file": .bool(attachment.data != nil),
            "job": ref(attachment.job),
            "invoice": ref(attachment.invoice),
            "contract": ref(attachment.contract),
        ]
    }

    func detail(_ document: CustomerDocument) -> [String: GLAIJSON] {
        [
            "kind": "document",
            "id": .string(MBIDs.id(document, env)),
            "name": v.text(document.name, limit: 160),
            "added": v.day(document.createdAt),
            "on_file": .bool(document.data != nil),
            "customer": ref(document.customer),
        ]
    }

    // MARK: - Singletons

    /// The business details printed on documents. Never the owner's name, the tax details, the
    /// card-payments account or the logos (contract §5).
    func business(_ profile: BusinessProfile?) -> [String: GLAIJSON] {
        guard let profile else { return ["kind": "business", "set_up": false] }
        func message(_ subject: String, _ intro: String, _ closing: String) -> GLAIJSON {
            ["subject": v.text(subject, limit: 200), "intro": v.text(intro, limit: 600),
             "closing": v.text(closing, limit: 400)]
        }
        return [
            "kind": "business",
            "set_up": true,
            "business_name": v.text(profile.businessName, limit: 160),
            "phone": v.text(profile.phone, limit: 40),
            "email": v.text(profile.email, limit: 120),
            "website_url": v.text(profile.websiteURL, limit: 200),
            "reviews_url": v.text(profile.reviewsURL, limit: 200),
            "review_link_on_receipts": .bool(profile.includeReviewLinkOnReceipts),
            "license_number": v.text(profile.licenseNumber, limit: 60),
            "address": v.address(profile.address),
            "warranty_text": v.text(profile.warrantyText, limit: 800),
            "details_complete": .bool(profile.isComplete),
            "zelle_configured": .bool(profile.zelleIsConfigured),
            "zelle_tag": v.text(profile.zelleTag, limit: 120),
            "zelle_email": v.text(profile.zelleEmail, limit: 120),
            "zelle_phone": v.text(profile.zellePhone, limit: 40),
            "zelle_default_on": .bool(profile.zelleDefaultOn),
            "zelle_qr_on_file": .bool(profile.zelleQRCodeData != nil),
            // Empty wording means the app's suggested wording is used.
            "messages": [
                "estimate": message(profile.estimateMessageSubject, profile.messageIntro, profile.messageClosing),
                "invoice": message(profile.invoiceMessageSubject, profile.invoiceMessageIntro, profile.invoiceMessageClosing),
                "receipt": message(profile.receiptMessageSubject, profile.receiptMessageIntro, profile.receiptMessageClosing),
                "change_order": message(profile.changeOrderMessageSubject, profile.changeOrderMessageIntro, profile.changeOrderMessageClosing),
                "contractor_package": message(profile.packageMessageSubject, profile.packageMessageIntro, profile.packageMessageClosing),
                "completion_package": message(profile.completionMessageSubject, profile.completionMessageIntro, profile.completionMessageClosing),
            ],
            "wc_exemption": certificate(onFile: profile.hasWCExemption, expiresOn: profile.wcExemptionExpiresOn),
            "license": certificate(onFile: profile.hasLicenseDocument, expiresOn: profile.licenseExpiresOn),
            "reference_certificate_on_file": .bool(profile.ownerReferenceCOIData != nil),
        ]
    }

    func workSchedule(_ schedule: WorkSchedule) -> [String: GLAIJSON] {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekdays = schedule.weekdayHours.enumerated().map { index, hours -> GLAIJSON in
            [
                "day": .string(names.indices.contains(index) ? names[index] : String(index)),
                "works": .bool(hours.isWorkday),
                "start": v.clock(minutes: hours.startMinutes),
                "end": v.clock(minutes: hours.endMinutes),
            ]
        }
        let holidays = USHoliday.catalog.map { holiday -> GLAIJSON in
            ["id": .string(holiday.id), "off": .bool(schedule.isHolidayOff(holiday.id))]
        }
        let overrides = schedule.overrides.map { item -> GLAIJSON in
            switch item.kind {
            case .blocked:
                return ["id": .string(item.id.uuidString), "date": v.day(item.date), "kind": "day_off"]
            case .customHours(let start, let end):
                return ["id": .string(item.id.uuidString), "date": v.day(item.date), "kind": "custom_hours",
                        "start": v.clock(minutes: start), "end": v.clock(minutes: end)]
            }
        }
        return [
            "kind": "work_schedule",
            "weekdays": .array(weekdays),
            "holidays": .array(holidays),
            "time_off": .array(schedule.vacations.map {
                ["id": .string($0.id.uuidString), "start": v.day($0.start), "end": v.day($0.end)]
            }),
            "days_off": .array(schedule.customDaysOff.map {
                ["id": .string($0.id.uuidString), "date": v.day($0.date), "label": v.text($0.label, limit: 80),
                 "repeats_yearly": .bool($0.repeatsYearly)]
            }),
            "overrides": .array(overrides),
        ]
    }

    /// This app's settings, as `update_app_settings` changes them. The logo switches are named
    /// `company_mark_*` here (see the header).
    func appSettings(_ profile: BusinessProfile?) -> [String: GLAIJSON] {
        [
            "kind": "app_settings",
            "language": .string(AppSettingsService.language.rawValue),
            "appearance": .string(AppSettingsService.appearance.rawValue),
            "book_one_job_at_a_time": .bool(AppSettingsService.oneJobAtATime()),
            "company_mark_on_documents": .bool(profile?.showLogoOnDocuments ?? true),
            "company_mark_in_emails": .bool(profile?.emailSignatureEnabled ?? true),
            "email_extra_line": v.text(profile?.emailSignatureText ?? "", limit: 300),
            "address_on_documents": .bool(profile?.showAddressOnDocuments ?? true),
            "company_mark_in_app": .bool(AppSettingsService.useCompanyLogo()),
            "pay_button_by_default": .bool(profile?.payLinkDefaultOn ?? true),
            "zelle_by_default": .bool(profile?.zelleDefaultOn ?? false),
        ]
    }

    func goldLifeID() -> [String: GLAIJSON] {
        let id = MBIdentity.shared.current
        let addr = id.address
        let addressJSON: GLAIJSON = addr.isEmpty ? .null : [
            "number": v.text(addr.number, limit: 40),
            "street": v.text(addr.street, limit: 120),
            "city": v.text(addr.city, limit: 80),
            "state": v.text(addr.state, limit: 40),
            "postal_code": v.text(addr.zip, limit: 20),
        ]
        return [
            "kind": "gold_life_id",
            "first_name": v.text(id.firstName, limit: 80),
            "last_name": v.text(id.lastName, limit: 80),
            "full_name": v.text(id.fullName, limit: 160),
            "email": v.text(id.email, limit: 120),
            "phone": v.text(id.phone, limit: 40),
            "address": addressJSON,
            "autograph_on_file": .bool(MBIdentity.shared.signatureData != nil),
        ]
    }

    func deviceInfo() -> [String: GLAIJSON] {
        let facts = AIDeviceFacts.current()
        return [
            "kind": "device_info",
            "app_name": .string(MBAssistantSession.appName),
            "app_version": .string(facts.appVersion),
            "build_number": .string(facts.appBuild),
            "device_type": .string(facts.kind.rawValue),
            "hardware_id": .string(facts.hardwareID),
            "os_version": .string("\(facts.systemName) \(facts.systemVersion)"),
            "layout": .string(facts.layout.rawValue),
            "timezone": .string(env.calendar.timeZone.identifier),
            "appearance": .string(AppSettingsService.appearance.rawValue),
            "language": .string(AppSettingsService.language.rawValue),
        ]
    }
}
