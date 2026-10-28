//
//  ProfileDedup.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  BusinessProfile and UserProfile are meant to be singletons, but sync can leave more than one when
//  two devices each create a blank copy during the server bootstrap window — the same race CloudKit
//  used to lose, now against gl-business-api's first snapshot. Readers use `.first`
//  (unsorted), so a blank duplicate can nondeterministically win and blank out the company name / logo
//  / signature on generated invoices and W-9s. On launch we collapse the duplicates by deleting only
//  the BLANK extras when a populated one exists (never touching a profile that has real data), so
//  `.first` resolves to the real profile. If every copy is blank, we keep exactly one.
//
//  The invoice/estimate counter MAX-merge below is now enforced server-side as well (the Worker keeps
//  the higher value), so a number can't walk backwards even on a device where this never runs.
//

import Foundation
import SwiftData

enum ProfileDedup {
    @MainActor
    static func run(_ context: ModelContext) {
        let business = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
        carryCounters(business)   // preserve the highest invoice/estimate number before deleting any copy
        collapse(business, isBlank: isBlank, context: context)
        let user = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        collapse(user, isBlank: isBlank, context: context)
        context.saveChanges()
    }

    /// Deletes blank extras. Keeps every populated row (never risks real data); if all are blank, keeps one.
    @MainActor
    private static func collapse<T: PersistentModel>(_ all: [T], isBlank: (T) -> Bool, context: ModelContext) {
        guard all.count > 1 else { return }
        let blanks = all.filter(isBlank)
        let hasPopulated = all.contains { !isBlank($0) }
        let toDelete = hasPopulated ? blanks : Array(blanks.dropFirst())
        toDelete.forEach(context.delete)
    }

    /// Before dedup deletes any duplicate, copy the highest monotonic invoice/estimate counter onto
    /// every copy — so whichever profile survives keeps the highest number and can't reissue one.
    @MainActor
    private static func carryCounters(_ profiles: [BusinessProfile]) {
        guard profiles.count > 1 else { return }
        let maxInvoice = profiles.map(\.lastInvoiceNumber).max() ?? 0
        let maxEstimate = profiles.map(\.lastEstimateNumber).max() ?? 0
        for p in profiles {
            if p.lastInvoiceNumber < maxInvoice { p.lastInvoiceNumber = maxInvoice }
            if p.lastEstimateNumber < maxEstimate { p.lastEstimateNumber = maxEstimate }
        }
    }

    /// Blank only when EVERY user-settable stored property is still at its model default. Deliberately
    /// exhaustive over the @Model's stored properties: any field missed here is a field dedup can
    /// destroy on a duplicate row (e.g. a Stripe-only copy created before the populated one synced).
    /// The only exclusions are the monotonic counters (`lastInvoiceNumber`/`lastEstimateNumber`) —
    /// `carryCounters` copies the max onto every row before collapse, so counting them here would make
    /// every copy look populated once a single invoice exists and dedup would never collapse anything.
    private static func isBlank(_ p: BusinessProfile) -> Bool {
        func empty(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let strings = [
            p.businessName, p.ownerFirstName, p.ownerLastName, p.phone, p.email,
            p.websiteURL, p.reviewsURL, p.licenseNumber, p.warrantyText,
            // Per-document message customizations.
            p.estimateMessageSubject, p.messageIntro, p.messageClosing,
            p.invoiceMessageSubject, p.invoiceMessageIntro, p.invoiceMessageClosing,
            p.receiptMessageSubject, p.receiptMessageIntro, p.receiptMessageClosing,
            p.changeOrderMessageSubject, p.changeOrderMessageIntro, p.changeOrderMessageClosing,
            p.packageMessageSubject, p.packageMessageIntro, p.packageMessageClosing,
            p.completionMessageSubject, p.completionMessageIntro, p.completionMessageClosing,
            // W-9. `w9TIN` is the legacy plaintext TIN — for a pre-Keychain user it can be the LAST
            // remaining copy of their SSN/EIN (`secureTIN` falls back to it), so it must count.
            p.w9Name, p.w9TaxClassificationRaw, p.w9LLCClassification, p.w9OtherClassification,
            p.w9TINTypeRaw, p.w9TIN, p.w9ExemptPayeeCode, p.w9FATCACode,
            // Compliance document names (paired with the Data? blobs below).
            p.proofOfInsuranceName, p.wcInsuranceName, p.wcExemptionName,
            p.licenseDocumentName, p.ownerReferenceCOIName,
            // Stripe: the durable connected-account resume key + signed ownership claim. Deleting a
            // copy that holds only these orphans the Stripe account — re-onboarding mints a duplicate.
            p.stripeConnectedAccountId, p.stripeAccountClaim,
        ]
        let blobs: [Data?] = [
            p.logoData, p.logoDataDark, p.workScheduleData,
            p.proofOfInsuranceData, p.wcInsuranceData, p.wcExemptionData,
            p.licenseDocumentData, p.ownerReferenceCOIData,
        ]
        // Non-string/non-blob fields: any value off its default means someone touched this row.
        let togglesAtDefault = p.showLogoOnDocuments && p.showAddressOnDocuments
            && p.payLinkDefaultOn && !p.stripeChargesEnabled
            && p.payLinkInclusionRaw == PayLinkInclusion.all.rawValue
            && !p.coiCoverExistingHolder
            && p.coiHolderOffsetX == 0 && p.coiHolderOffsetY == 0 && p.coiHolderBoxWidth == 0
        return strings.allSatisfy(empty)
            && blobs.allSatisfy { $0 == nil }
            && p.address.isEmpty
            && togglesAtDefault
            && (p.paymentProcessors?.isEmpty ?? true)   // retired, but legacy fee data is still real data
    }

    /// `UserProfile` now holds only `useMyNameInEmails` (default `false`); any row where
    /// the person turned it on is populated and must not be mistaken for blank.
    private static func isBlank(_ userProfile: UserProfile) -> Bool {
        !userProfile.useMyNameInEmails
    }
}
