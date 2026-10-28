//
//  MBPaymentTool.swift
//  GLSmallBusiness — AI
//
//  `record_payment`: money received on one invoice, through `InvoiceService.recordPayment` — the
//  same call the Record Payment sheet makes (law 58).
//
//  Money is always confirmed by the person (contract §5), and a confirmed change keeps no Undo:
//  payments are append-only (a mistake is corrected with a credit change order). More than the
//  balance due is refused before the person is ever asked, so the model can offer a split instead.
//  The call's idempotency key (turn id + call id) is remembered, so a step that runs twice can
//  never record the same money twice.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBRecordPaymentTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)

        // The same call, run again (a retried step): the money is already recorded.
        if let done = env.ledger.recordedPayment(call.idempotencyKey) {
            return .result(done.setting("already_recorded", to: true))
        }

        guard let invoiceID = args.string("invoice_id"),
              let invoice = MBRecordLookup.record(.invoice, id: invoiceID, as: Invoice.self, in: store) else {
            return MBToolFailure.notFound(.invoice)
        }
        let recordID = MBIDs.id(invoice, env)
        let ref = MBWrite.ref(.invoice, recordID)
        guard let amount = args.money("amount"), amount > 0 else {
            return MBToolFailure.domain(.amountRequired, ref)
        }
        guard let method = args.raw("method", PaymentMethod.self) else {
            return MBToolFailure.invalid("method must be one of the listed ways to pay (cash, check, card, …).")
        }
        let date = value.parseDay(args.string("date")) ?? env.calendar.startOfDay(for: env.now())
        let note = args.json["note"]?.stringValue ?? ""

        // Over the balance: refused before anyone is asked, with the balance so the model can
        // offer to split it across the customer's open invoices.
        if InvoiceService.paymentExceedsBalance(invoice, amount: amount) {
            let balance = MBWriteValue.amount(invoice.balanceDue)
            return .failure(GLAIFailure(
                reason: DomainError.exceedsBalance.code,
                message: "The balance due on \(invoice.number) is \(balance). Record that or less, and offer to split the rest across the customer's other open invoices, one call each.",
                personReason: DomainError.exceedsBalance.personReason, record: ref))
        }

        let number = invoice.number
        let amountText = MBWriteValue.amount(amount)
        let key = call.idempotencyKey
        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [recordID],
            line: MBWriteStrings.confirmPayment(amount: amountText, invoice: number),
            actionLabel: MBWriteStrings.confirmRecordPaymentAction,
            isDestructive: false,
            declinedMessage: "The user chose not to record that payment on \(number).",
            perform: { [env] in
                Self.record(recordID, amount: amount, date: date, method: method, note: note,
                            key: key, env: env)
            }))
    }

    /// The write itself. Confirmed money keeps no Undo (contract §5).
    static func record(_ recordID: String, amount: Double, date: Date, method: PaymentMethod,
                       note: String, key: String, env: MBToolEnvironment) -> GLAIToolOutcome {
        let ref = MBWrite.ref(.invoice, recordID)
        guard let store = env.context(), let invoice = MBWrite.invoice(recordID, env) else {
            return MBToolFailure.notFound(.invoice)
        }
        if let done = env.ledger.recordedPayment(key) { return .result(done.setting("already_recorded", to: true)) }
        let payment: InvoicePayment
        do {
            payment = try InvoiceService.recordPayment(on: invoice, amount: amount, date: date,
                                                       method: method, note: note, origin: .tool,
                                                       in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error, ref)
        }
        env.ledger.note(recordID, MBFingerprint.of(invoice))
        let value = MBValue(calendar: env.calendar)
        let dto = MBRecordDTO(env: env, context: store)
        let output: GLAIJSON = [
            "ok": true,
            "payment": [
                "id": .string(MBIDs.id(payment, env)),
                "amount": value.money(payment.amount),
                "date": value.day(payment.date),
                "method": .string(payment.method.rawValue),
            ],
            "invoice": dto.row(invoice),
            "paid_in_full": .bool(invoice.isPaid),
        ]
        env.ledger.notePayment(key, output)
        return .result(output,
                       activity: [GLAIActivity(kind: .recorded, symbol: MBWriteSymbol.payment,
                                               title: MBWriteStrings.paymentRecorded,
                                               detail: "\(MBWriteValue.amount(payment.amount)) · \(invoice.number)",
                                               record: ref)])
    }
}
