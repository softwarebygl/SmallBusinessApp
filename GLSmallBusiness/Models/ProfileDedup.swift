//
//  ProfileDedup.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  BusinessProfile and UserProfile are meant to be singletons, but CloudKit can leave more than one
//  when two devices each create a blank copy during the initial-sync window. Readers use `.first`
//  (unsorted), so a blank duplicate can nondeterministically win and blank out the company name / logo
//  / signature on generated invoices and W-9s. On launch we collapse the duplicates by deleting only
//  the BLANK extras when a populated one exists (never touching a profile that has real data), so
//  `.first` resolves to the real profile. If every copy is blank, we keep exactly one.
//

import Foundation
import SwiftData

enum ProfileDedup {
    @MainActor
    static func run(_ context: ModelContext) {
        let business = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
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

    private static func isBlank(_ p: BusinessProfile) -> Bool {
        p.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.logoData == nil
    }

    private static func isBlank(_ p: UserProfile) -> Bool {
        p.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.signatureData == nil
    }
}
