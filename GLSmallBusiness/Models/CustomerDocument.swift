//
//  CustomerDocument.swift
//  GLSmallBusiness
//
//  An additional document (PDF or image) included in one customer's Contractor Package — the extras
//  a GC sometimes asks for beyond the standard COI + W-9 + workers'-comp + license (an OSHA card, a
//  signed vendor agreement, a bonding letter, …). Uploaded on the Contractor Package screen and
//  merged into that customer's package after the standard documents, in upload order. Byte-identical
//  to the other document slots at the storage layer: an external-storage blob + a name, matching
//  `JobAttachment`.
//
//  Cascade-deletes with its customer (see `Customer.packageDocuments`) — these were added for that
//  customer's package and mean nothing without them.
//

import Foundation
import SwiftData

@Model
final class CustomerDocument {

    // MARK: Sync identity (platform Phase 0 — additive into GLSchemaV1)
    /// Stable identity for the coming server sync. Optional, NOT `= UUID()`: a SwiftData
    /// attribute default is captured once in schema metadata, so migration would give
    /// every existing record the SAME uuid. SyncIdentityBackfill mints these uniquely.
    /// `.preserveValueOnDeletion` keeps the uuid in the DELETE tombstone. Without it the
    /// tombstone is empty, the syncID dies with the row, and the server can never be told
    /// the record went away — i.e. deletes do not sync at all (GLSYNC-SPEC.md §2a).
    @Attribute(.preserveValueOnDeletion) var syncID: UUID?
    /// Last local edit, stamped by `saveChanges`. Autosaved edits are not stamped yet —
    /// the GLSync client owns real change capture when it lands (migration Phase 3).
    var updatedAt: Date?
    /// The file bytes (a PDF or image). External storage keeps the SQLite row small and
    /// CloudKit-friendly, matching `JobAttachment.data`.
    @Attribute(.externalStorage) var data: Data?
    /// Original filename — used as the row label and the share filename.
    var name: String = ""
    var createdAt: Date = Date.now

    /// The customer whose package carries this document. Bare to-one; the cascade inverse lives on
    /// `Customer.packageDocuments`.
    var customer: Customer?

    init(name: String = "", data: Data? = nil, createdAt: Date = .now, customer: Customer? = nil) {
        self.name = name
        self.data = data
        self.createdAt = createdAt
        self.customer = customer
    }
}
