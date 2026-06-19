//
//  CustomerInsurance.swift
//  GLSmallBusiness
//
//  A customer's General Liability Certificate of Insurance. Unlike the workers'-comp and license
//  documents (which are general and live on the business), a COI names its certificate holder, so each
//  customer has their own — issued by the insurer with that customer listed — uploaded and managed
//  here, then sent as-is in their Contractor Package.
//
//  A thin wrapper over the shared `DocumentDetailScreen`, backed by the Customer.
//

import SwiftUI
import SwiftData

struct CustomerCOIDetailScreen: View {
    @Query private var profiles: [BusinessProfile]
    let customer: Customer

    var body: some View {
        DocumentDetailScreen(slot: DocumentSlot(
            title: String(localized: "Certificate of Insurance"),
            data: customer.coiData,
            name: customer.coiName,
            fallbackFileName: "Certificate-of-Insurance.pdf",
            businessName: profiles.first?.businessName ?? "",
            removeTitle: "Remove certificate",
            removeSubtitle: "Delete this customer's COI from your records.",
            store: { customer.coiData = $0; customer.coiName = $1 }
        ))
    }
}
