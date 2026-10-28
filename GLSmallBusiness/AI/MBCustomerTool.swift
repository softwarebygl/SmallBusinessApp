//
//  MBCustomerTool.swift
//  GLSmallBusiness — AI
//
//  `save_customer`: add a customer (no id) or change one (with id) — through `CustomerService`,
//  the same code the Customer form's Save calls (law 58). Only the fields the model sent change;
//  the photo, the certificates and the delete are other doors.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBSaveCustomerTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let dto = MBRecordDTO(env: env, context: store)

        if let id = args.string("id") {
            guard let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return MBToolFailure.notFound(.customer)
            }
            let before = CustomerDraft(customer)
            let draft = patched(before, args)
            if CustomerService.isReservedPronounName(first: draft.firstName, last: draft.lastName, business: draft.businessName) {
                return MBToolFailure.invalid("Customer name cannot be 'me' or 'for me'. Please provide a client's name.")
            }
            do {
                try CustomerService.update(customer, with: draft, in: store, subscription: env.subscription())
            } catch {
                return MBToolFailure.unexpected(error, MBWrite.ref(.customer, id))
            }
            let recordID = MBIDs.id(customer, env)
            let ref = MBWrite.ref(.customer, recordID)
            env.ledger.note(recordID, MBFingerprint.of(customer))
            let token = env.ledger.stash(.customer(before))
            return .result(["ok": true, "id": .string(recordID), "customer": dto.row(customer)],
                           activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.customer,
                                                   title: MBWriteStrings.customerUpdated,
                                                   detail: customer.listDisplayName, record: ref)],
                           undo: undoEdit(ref, name: customer.listDisplayName, token: token, env: env))
        }

        let draft = patched(CustomerDraft(), args)
        if CustomerService.isReservedPronounName(first: draft.firstName, last: draft.lastName, business: draft.businessName) {
            return MBToolFailure.invalid("Customer name cannot be 'me' or 'for me'. Please provide a client's name.")
        }
        let customer: Customer
        do {
            customer = try CustomerService.create(draft, in: store, subscription: env.subscription())
        } catch {
            return MBToolFailure.unexpected(error)
        }
        let recordID = MBIDs.id(customer, env)
        let ref = MBWrite.ref(.customer, recordID)
        env.ledger.note(recordID, MBFingerprint.of(customer))
        return .result(["ok": true, "id": .string(recordID), "customer": dto.row(customer)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.customer,
                                               title: MBWriteStrings.customerAdded,
                                               detail: customer.listDisplayName, record: ref)],
                       undo: undoCreate(ref, name: customer.listDisplayName, env: env))
    }

    /// Only the sent fields change (the manifest's rule for every save_* tool).
    private func patched(_ draft: CustomerDraft, _ args: MBArguments) -> CustomerDraft {
        var draft = draft
        if let value = args.json["first_name"]?.stringValue { draft.firstName = value }
        if let value = args.json["middle_name"]?.stringValue { draft.middleName = value }
        if let value = args.json["last_name"]?.stringValue { draft.lastName = value }
        if let value = args.json["business_name"]?.stringValue { draft.businessName = value }
        if let value = args.json["email"]?.stringValue { draft.email = value }
        if let value = args.json["phone"]?.stringValue { draft.phoneNumber = value }
        if let value = args.json["office_phone"]?.stringValue { draft.officePhone = value }
        draft.address = MBWriteValue.address(draft.address, patch: args.object("address"))
        if args.has("service_address") {
            draft.serviceAddress = MBWriteValue.address(draft.serviceAddress, patch: args.object("service_address"))
            draft.sameAsBillingAddress = false
        }
        if let same = args.bool("same_as_billing_address") {
            draft.sameAsBillingAddress = same
            if same { draft.serviceAddress = draft.address }
        }
        return draft
    }

    // MARK: Undo

    private func undoCreate(_ ref: GLAIRecordRef, name: String, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(customer: name), ledger: env.ledger,
                     fingerprint: { MBWrite.customer(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context() else { return MBUndo.recordGone }
            guard let customer = MBWrite.customer(ref.id, env) else { return MBUndo.recordGone }
            // A customer that has picked up records since (an estimate typed on the form, an
            // invoice from another request) is kept: deleting would take those with it.
            let dependents = customer.liveRows(customer.estimates).count
                + customer.liveRows(customer.invoices).count
                + customer.liveRows(customer.scheduledJobs).count
                + customer.liveRows(customer.receipts).count
            guard dependents == 0 else { return .failed(MBWriteStrings.undoKeptHasRecords) }
            let label = customer.listDisplayName
            do {
                try DeletionService.delete([.customer(customer)], in: store, subscription: env.subscription())
            } catch let error as DomainError {
                return .failed(error.personReason)
            } catch {
                return .failed(GLAIStrings.errorGeneric)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.customer,
                                   MBWriteStrings.deleted(.customer), detail: label, record: nil)
        }
    }

    private func undoEdit(_ ref: GLAIRecordRef, name: String, token: UUID, env: MBToolEnvironment) -> GLAIUndo {
        MBUndo.entry(ref, title: MBWriteStrings.undoTitle(customer: name), ledger: env.ledger,
                     fingerprint: { MBWrite.customer(ref.id, env).map(MBFingerprint.of) }) {
            guard let store = env.context(), let customer = MBWrite.customer(ref.id, env),
                  case .customer(let before)? = env.ledger.snapshot(token) else { return MBUndo.recordGone }
            do {
                // `.screen` on the way back: these are the record's own stored values.
                try CustomerService.update(customer, with: before, in: store, subscription: env.subscription())
            } catch let error as DomainError {
                return .failed(error.personReason)
            } catch {
                return .failed(GLAIStrings.errorGeneric)
            }
            env.ledger.note(ref.id, MBFingerprint.of(customer))
            return MBUndo.reverted(.updated, MBWriteSymbol.customer, MBWriteStrings.customerRestored,
                                   detail: customer.listDisplayName, record: ref)
        }
    }
}
