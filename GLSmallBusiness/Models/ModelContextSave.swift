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
    /// Persistence / data-layer log channel.
    static let data = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GLSmallBusiness",
                             category: "data")
}

extension ModelContext {
    /// Save pending changes, logging (not swallowing) any failure. Drop-in for `try? save()`.
    func saveChanges(_ site: StaticString = #function) {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            Logger.data.error("SwiftData save failed at \(site, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
