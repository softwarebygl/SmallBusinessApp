//
//  ModelContextSave.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  A single save helper used instead of a bare `try? modelContext.save()`. A local SwiftData save
//  effectively never fails in normal use (CloudKit sync is separate and queues offline), so we don't
//  interrupt the user — but a swallowed `try?` hides a real problem (disk full, a validation error)
//  with zero trace. This logs the failure (with the call site) so it's diagnosable, without crashing.
//

import SwiftData
import OSLog

extension Logger {
    /// Persistence / data-layer log channel. `nonisolated`: loggers are Sendable
    /// and this is read from the sync engine off the main actor.
    nonisolated static let data = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GLSmallBusiness",
                             category: "data")
}

extension ModelContext {
    /// Save pending changes, logging (not swallowing) any failure. Drop-in for `try? save()`.
    func saveChanges(_ site: StaticString = #function) {
        guard hasChanges else { return }
        // Platform Phase 0: stamp the sync identity on everything this save touches.
        // New records get their syncID here (no waiting for the next launch sweep);
        // edits move updatedAt. Autosaved edits bypass this — real change capture is
        // the sync client's job when it lands (migration Phase 3).
        for model in insertedModelsArray + changedModelsArray {
            if let record = model as? GLSyncIdentified {
                if record.syncID == nil { record.syncID = UUID() }
                record.updatedAt = .now
            }
        }
        do {
            try save()
        } catch {
            Logger.data.error("SwiftData save failed at \(site, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // The person's half (alert AND log, never one without the other): a
            // form that dismissed as "saved" while the save silently failed was
            // the CRUD audit's saveChanges hazard (2026-09-02).
            Task { @MainActor in StoreRecovery.noteSaveFailed() }
        }
    }
}
