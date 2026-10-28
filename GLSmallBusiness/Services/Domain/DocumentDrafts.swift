//
//  DocumentDrafts.swift
//  GLSmallBusiness
//
//  The save rules shared by the three money-document drafts (EstimateDraft.swift,
//  InvoiceDraft.swift, ChangeOrderDraft.swift). Those drafts are what the forms hold in @State and
//  what the assistant's tools will build, so both hand EstimateService, InvoiceService and
//  ChangeOrderService the same value. They moved from the forms (where they were file-private) with
//  their fields, defaults and `init(from:)` copies unchanged.
//
//  `modelID` is the live row a draft was read from: the services' RowReconciler updates that row
//  in place, a draft without one inserts a new row, and a live row no draft names is deleted.
//

import Foundation
import SwiftData

enum DocumentDraftRules {
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The service address as the forms store it: every part trimmed, an empty Apt/Suite as nil.
    static func trimmedAddress(_ address: Address) -> Address {
        let street2 = trim(address.street2 ?? "")
        return Address(street1: trim(address.street1), street2: street2.isEmpty ? nil : street2,
                       city: trim(address.city), state: trim(address.state),
                       postalCode: trim(address.postalCode))
    }

    /// The estimate keep-filter: a line survives with a name, details or a non-zero price; a group
    /// with a name or at least one kept line. Names and notes come back trimmed, so the index the
    /// reconciler hands back IS the sortIndex.
    static func keptGroups(_ groups: [EstimateGroupDraft]) -> [EstimateGroupDraft] {
        groups.compactMap { draft in
            var kept = draft
            kept.name = trim(draft.name)
            kept.note = trim(draft.note)
            kept.lines = draft.lines.filter {
                !trim($0.name).isEmpty || !trim($0.details).isEmpty || $0.unitPrice != 0
            }
            return (kept.lines.isEmpty && kept.name.isEmpty) ? nil : kept
        }
    }

    /// The invoice keep-filter — the same rule as the estimate's.
    static func keptGroups(_ groups: [InvoiceGroupDraft]) -> [InvoiceGroupDraft] {
        groups.compactMap { draft in
            var kept = draft
            kept.name = trim(draft.name)
            kept.note = trim(draft.note)
            kept.lines = draft.lines.filter {
                !trim($0.name).isEmpty || !trim($0.details).isEmpty || $0.unitPrice != 0
            }
            return (kept.lines.isEmpty && kept.name.isEmpty) ? nil : kept
        }
    }
}
