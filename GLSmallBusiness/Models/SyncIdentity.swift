//
//  SyncIdentity.swift
//  GLSmallBusiness
//
//  Platform migration Phase 0: every record carries a stable identity (`syncID`)
//  and a last-edit stamp (`updatedAt`) so the coming server sync (gl-business-api)
//  has something to key on. Fields are OPTIONAL additive members of GLSchemaV1 —
//  see the note on each model: a `= UUID()` attribute default is captured once in
//  schema metadata, so migrating would stamp every existing record with the SAME
//  uuid. This backfill mints them uniquely in code instead.
//
//  Unlike ReviewLinkBackfill this is NOT run-once: records created on devices
//  still running an older build sync down through CloudKit with nil syncIDs at any
//  time, so the sweep is a cheap idempotent pass on every launch. If two devices
//  backfill the same record concurrently, CloudKit's last-writer-wins picks one
//  uuid and both devices converge on it — acceptable now; identity is finalized
//  when the sync client lands (migration Phase 3).
//

import Foundation
import SwiftData

/// A record that carries the platform sync identity.
protocol GLSyncIdentified: AnyObject {
    var syncID: UUID? { get set }
    var updatedAt: Date? { get set }
}

extension BusinessProfile: GLSyncIdentified {}
extension ChangeOrder: GLSyncIdentified {}
extension ChangeOrderLineItem: GLSyncIdentified {}
extension Contract: GLSyncIdentified {}
extension ContractGroup: GLSyncIdentified {}
extension ContractLineItem: GLSyncIdentified {}
extension Customer: GLSyncIdentified {}
extension CustomerDocument: GLSyncIdentified {}
extension Employee: GLSyncIdentified {}
extension Estimate: GLSyncIdentified {}
extension EstimateGroup: GLSyncIdentified {}
extension EstimateLineItem: GLSyncIdentified {}
extension Invoice: GLSyncIdentified {}
extension InvoiceGroup: GLSyncIdentified {}
extension InvoiceLineItem: GLSyncIdentified {}
extension InvoicePayment: GLSyncIdentified {}
extension JobAttachment: GLSyncIdentified {}
extension Paycheck: GLSyncIdentified {}
extension PaymentProcessor: GLSyncIdentified {}
// The Price Sheet joined sync on 2026-10-03 (QA finding F3). Items saved before ids were minted
// get one from the sweep below, so the first sync after the update uploads them.
extension PriceSheetItem: GLSyncIdentified {}
extension Project: GLSyncIdentified {}
extension Receipt: GLSyncIdentified {}
extension ScheduledJob: GLSyncIdentified {}
extension SubPayment: GLSyncIdentified {}
extension Subcontractor: GLSyncIdentified {}
extension TimeEntry: GLSyncIdentified {}
extension UserProfile: GLSyncIdentified {}

/// Phase 0 side-quest with real security value TODAY: drain legacy plaintext TINs
/// out of the synced store. `BusinessProfile.w9TIN` predates SecureTINStore and
/// still holds a plaintext SSN/EIN on installs that never re-saved the W-9 form —
/// and it SYNCS through CloudKit. The audit (DATA-MAP.md) flagged it as the one
/// NEVER-SYNCS field; the migration must not carry it to the server, and there is
/// no reason to keep shipping it through CloudKit in the meantime.
///
/// Direction matters: legacy plaintext must never overwrite a newer Keychain TIN.
///   - Keychain EMPTY  -> updateTIN(w9TIN): write to Keychain, which clears the
///     plaintext only after a CONFIRMED write (existing semantics).
///   - Keychain HAS a value -> the Keychain copy is authoritative (secureTIN never
///     reads the fallback when the Keychain answers); just purge the stale plaintext.
enum LegacyTINDrain {
    @MainActor
    static func run(_ context: ModelContext) {
        guard let profiles = try? context.fetch(FetchDescriptor<BusinessProfile>()) else { return }
        var changed = false
        for profile in profiles where !profile.w9TIN.isEmpty {
            if SecureTINStore.read().isEmpty {
                changed = profile.updateTIN(profile.w9TIN) || changed
            } else {
                profile.w9TIN = ""
                changed = true
            }
        }
        if changed { context.saveChanges() }
    }
}

/// Forward-copy of the eight dormant-legacy `Address` composites (build-62 SIGTRAP,
/// 2026-09-01 — `Address.street2: String?` made every composite UPDATE poison
/// persistent history) into their flat `*Street1…*PostalCode` columns, the write path
/// now. READING a composite is safe; only history rows recording a WRITE to one fatal.
///
/// One-shot per store, marked by a file next to it: an address the person later CLEARS
/// empties the flats while the legacy composite still holds the old value, and an
/// emptiness-driven re-run would resurrect it. The marker lands only after a successful
/// save, and dies with the store on wipe.
enum AddressFlatsBackfill {
    @MainActor
    static func run(_ context: ModelContext, storeURL: URL?) {
        let marker = storeURL.map {
            $0.deletingLastPathComponent()
                .appendingPathComponent($0.lastPathComponent + ".addr-flats-backfilled")
        }
        if let marker, FileManager.default.fileExists(atPath: marker.path) { return }

        var changed = false
        if let rows = try? context.fetch(FetchDescriptor<BusinessProfile>()) {
            for r in rows where r.address.isEmpty && !r.legacyAddress.isEmpty {
                r.address = r.legacyAddress; changed = true
            }
        }
        if let rows = try? context.fetch(FetchDescriptor<Customer>()) {
            for r in rows where r.address.isEmpty && !r.legacyAddress.isEmpty {
                r.address = r.legacyAddress; changed = true
            }
        }
        if let rows = try? context.fetch(FetchDescriptor<Subcontractor>()) {
            for r in rows where r.address.isEmpty && !r.legacyAddress.isEmpty {
                r.address = r.legacyAddress; changed = true
            }
        }
        if let rows = try? context.fetch(FetchDescriptor<Estimate>()) {
            for r in rows {
                if r.customerAddress.isEmpty && !r.legacyCustomerAddress.isEmpty {
                    r.customerAddress = r.legacyCustomerAddress; changed = true
                }
                if r.serviceAddress.isEmpty && !r.legacyServiceAddress.isEmpty {
                    r.serviceAddress = r.legacyServiceAddress; changed = true
                }
            }
        }
        if let rows = try? context.fetch(FetchDescriptor<Invoice>()) {
            for r in rows {
                if r.customerAddress.isEmpty && !r.legacyCustomerAddress.isEmpty {
                    r.customerAddress = r.legacyCustomerAddress; changed = true
                }
                if r.serviceAddress.isEmpty && !r.legacyServiceAddress.isEmpty {
                    r.serviceAddress = r.legacyServiceAddress; changed = true
                }
            }
        }
        if let rows = try? context.fetch(FetchDescriptor<ScheduledJob>()) {
            for r in rows where r.serviceAddress.isEmpty && !r.legacyServiceAddress.isEmpty {
                r.serviceAddress = r.legacyServiceAddress; changed = true
            }
        }
        if changed { context.saveChanges() }
        // Only after the copy is durable (or there was nothing to copy).
        if !context.hasChanges, let marker {
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        }
    }
}

enum SyncIdentityBackfill {

    /// Mint a unique `syncID` for every record that lacks one, across every model
    /// type. Runs on each launch, and stays per-launch on purpose: an autosaved insert
    /// never passes `saveChanges`, so it can reach a later launch without an id, and a
    /// record without an id never syncs. It costs one query per type that returns only
    /// the records still missing an id — none, on a fully-minted store. It used to load
    /// every record of every type on the main actor at each launch (audit 2026-10-03 F152).
    /// `updatedAt` is left nil here — nil means "no tracked edit yet", and stamping
    /// backfill time would fake an edit history the sync layer would later trust.
    /// Returns how many records it loaded — the ones that needed an id.
    @MainActor
    @discardableResult
    static func run(_ context: ModelContext) -> Int {
        var minted = 0
        minted += sweep(#Predicate<BusinessProfile> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<ChangeOrder> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<ChangeOrderLineItem> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Contract> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<ContractGroup> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<ContractLineItem> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Customer> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<CustomerDocument> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Employee> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Estimate> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<EstimateGroup> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<EstimateLineItem> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Invoice> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<InvoiceGroup> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<InvoiceLineItem> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<InvoicePayment> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<JobAttachment> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Paycheck> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<PaymentProcessor> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<PriceSheetItem> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Project> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Receipt> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<ScheduledJob> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<SubPayment> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<Subcontractor> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<TimeEntry> { $0.syncID == nil }, context)
        minted += sweep(#Predicate<UserProfile> { $0.syncID == nil }, context)
        if minted > 0 { context.saveChanges() }
        return minted
    }

    /// One concrete predicate per type (a #Predicate cannot reach a protocol member
    /// through a generic), so the store returns only the rows that still need an id.
    @MainActor
    private static func sweep<T: PersistentModel & GLSyncIdentified>(
        _ missingID: Predicate<T>, _ context: ModelContext
    ) -> Int {
        guard let missing = try? context.fetch(FetchDescriptor<T>(predicate: missingID)) else { return 0 }
        for record in missing where record.syncID == nil {
            record.syncID = UUID()
        }
        return missing.count
    }
}
