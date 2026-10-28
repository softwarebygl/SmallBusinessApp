//
//  CustomerInsurance.swift
//  GLSmallBusiness
//
//  A customer's insurer-issued Certificates of Insurance — General Liability and Workers' Comp.
//  Unlike the exemption and license documents (which are general and live on the business), a COI
//  names its certificate holder, so each customer has their own — issued by the insurer with that
//  customer listed — uploaded and managed here, then sent as-is in their Contractor Package.
//
//  Thin wrappers over the shared `DocumentDetailScreen`, backed by the Customer.
//

import SwiftUI
import SwiftData

struct CustomerCOIDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query private var allCustomers: [Customer]
    let customer: Customer

    /// False once this customer is deleted out from under the view (e.g. on another device) —
    /// without it, replace/remove would write onto the deleted model and be lost on next sync.
    private var stillExists: Bool {
        allCustomers.contains { $0.persistentModelID == customer.persistentModelID }
    }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("General Liability Certificate"), noun: "this customer") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: mbLoc("General Liability Certificate"),
            data: customer.coiData,
            name: customer.coiName,
            fallbackFileName: "Certificate-of-Insurance.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove certificate",
            removeSubtitle: "Delete this customer's COI from your records.",
            store: {
                // The customer can be deleted (on another device) while the picker/remove alert is
                // up — don't write onto the deleted model, where it would vanish on next sync.
                // DocumentDetailScreen has already gated (and refused out loud); `try?` here only
                // drops a write DocumentService finds impossible (the record went away).
                guard stillExists else { return }
                try? DocumentService.set(.customerCertificate(customer, .generalLiability), data: $0, name: $1,
                                         in: modelContext)
            },
            expiresOn: Binding(get: { customer.coiExpiresOn },
                               set: {
                                   guard stillExists else { return }
                                   try? DocumentService.setExpiry(.customerCertificate(customer, .generalLiability), $0,
                                                                  in: modelContext)
                               })
        ))
    }
}

struct CustomerWCCOIDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query private var allCustomers: [Customer]
    let customer: Customer

    /// False once this customer is deleted out from under the view (e.g. on another device) —
    /// without it, replace/remove would write onto the deleted model and be lost on next sync.
    private var stillExists: Bool {
        allCustomers.contains { $0.persistentModelID == customer.persistentModelID }
    }

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Workers' Comp Certificate"), noun: "this customer") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: mbLoc("Workers' Comp Certificate"),
            data: customer.wcCoiData,
            name: customer.wcCoiName,
            fallbackFileName: "Workers-Comp-Certificate.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove certificate",
            removeSubtitle: "Delete this customer's workers' comp certificate from your records.",
            store: {
                // The customer can be deleted (on another device) while the picker/remove alert is
                // up — don't write onto the deleted model, where it would vanish on next sync.
                // DocumentDetailScreen has already gated (and refused out loud); `try?` here only
                // drops a write DocumentService finds impossible (the record went away).
                guard stillExists else { return }
                try? DocumentService.set(.customerCertificate(customer, .workersComp), data: $0, name: $1,
                                         in: modelContext)
            },
            expiresOn: Binding(get: { customer.wcCoiExpiresOn },
                               set: {
                                   guard stillExists else { return }
                                   try? DocumentService.setExpiry(.customerCertificate(customer, .workersComp), $0,
                                                                  in: modelContext)
                               })
        ))
    }
}
