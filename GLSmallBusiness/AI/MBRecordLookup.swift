//
//  MBRecordLookup.swift
//  GLSmallBusiness — AI
//
//  Finds one live record by the id a tool handed out (its `syncID`), through the same sync
//  registry fetch the delete service uses — so "the record with this id" means one thing
//  everywhere. A deleted row is never returned (reading a deleted model traps).
//

import Foundation
import SwiftData

@MainActor
enum MBRecordLookup {

    /// The registry key each kind is stored under (`GLSyncRegistry`).
    static func registryKey(_ kind: MBRecordKind) -> String? {
        switch kind {
        case .customer: return "customer"
        case .estimate: return "estimate"
        case .invoice: return "invoice"
        case .changeOrder: return "change_order"
        case .job: return "scheduled_job"
        case .receipt: return "receipt"
        case .employee: return "employee"
        case .subcontractor: return "subcontractor"
        case .project: return "project"
        case .payment: return "invoice_payment"
        case .timeEntry: return "time_entry"
        case .paycheck: return "paycheck"
        case .subPayment: return "sub_payment"
        case .attachment: return "job_attachment"
        case .document: return "customer_document"
        case .contract, .priceItem, .business, .workSchedule, .appSettings, .goldLifeID, .deviceInfo: return nil
        }
    }

    static func record<T: PersistentModel>(_ kind: MBRecordKind, id: String?, as type: T.Type,
                                           in context: ModelContext) -> T? {
        guard let uuid = MBIDs.uuid(id) else { return nil }
        if kind == .priceItem {
            let descriptor = FetchDescriptor<PriceSheetItem>(predicate: #Predicate { $0.syncID == uuid })
            return ((try? context.fetch(descriptor)) ?? []).first { !$0.isDeleted } as? T
        }
        if kind == .contract {
            let descriptor = FetchDescriptor<Contract>(predicate: #Predicate { $0.syncID == uuid })
            return ((try? context.fetch(descriptor)) ?? []).first { !$0.isDeleted && $0.modelContext != nil } as? T
        }
        guard let key = registryKey(kind),
              let record = GLSyncRegistry.entry(for: key)?.fetch(uuid, context) as? T,
              !record.isDeleted, record.modelContext != nil else { return nil }
        return record
    }

    /// Every live record of a type.
    static func all<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> [T] {
        ((try? context.fetch(FetchDescriptor<T>())) ?? []).filter { !$0.isDeleted }
    }

    static func businessProfile(in context: ModelContext) -> BusinessProfile? {
        all(BusinessProfile.self, in: context).first
    }
}
