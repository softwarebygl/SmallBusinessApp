//
//  JobAttachment.swift
//  GLSmallBusiness
//
//  A file attached to a Job: either a proof-of-work PHOTO (pictures of finalized work) or an
//  additional DOCUMENT (a PDF or image — a permit, a supplier slip, etc.). One model discriminated by
//  `kind`, since both are byte-identical at the storage layer (an external-storage blob + a name);
//  only the picker that adds them and the way they're shown differ. Receipts attach to a job
//  separately, via the first-class `Receipt` model.
//
//  Cascade-deletes with its job (see `ScheduledJob.attachments`) — these belong to the job, unlike
//  receipts (financial records that survive the job).
//

import Foundation
import SwiftData

/// Whether a `JobAttachment` is a proof-of-work photo or an additional document. Pure value type, so
/// `nonisolated` (the target defaults to MainActor isolation).
nonisolated enum JobAttachmentKind: String, Codable, CaseIterable {
    case photo
    case document
}

@Model
final class JobAttachment {
    /// The file bytes (a JPEG for photos, a PDF or image for documents). External storage keeps the
    /// SQLite row small and CloudKit-friendly, matching `Receipt.scanData`.
    @Attribute(.externalStorage) var data: Data?
    /// Filename for documents; a generated name for photos. Used as the share filename + list label.
    var name: String = ""
    /// Optional user note shown under the item.
    var caption: String = ""
    var createdAt: Date = Date.now
    /// Persisted discriminator; read/write via `kind`.
    var kindRaw: String = JobAttachmentKind.photo.rawValue

    /// The job this is attached to. Bare to-one; the cascade inverse lives on `ScheduledJob.attachments`.
    var job: ScheduledJob?

    /// Typed accessor over the raw kind string (mirrors `ScheduledJob.status`).
    var kind: JobAttachmentKind {
        get { JobAttachmentKind(rawValue: kindRaw) ?? .photo }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: JobAttachmentKind = .photo, name: String = "", caption: String = "",
         data: Data? = nil, createdAt: Date = .now, job: ScheduledJob? = nil) {
        self.kindRaw = kind.rawValue
        self.name = name
        self.caption = caption
        self.data = data
        self.createdAt = createdAt
        self.job = job
    }
}
