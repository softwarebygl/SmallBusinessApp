//
//  URLExtensions.swift
//  GLSmallBusiness
//

import Foundation
import SwiftUI

/// Why a file picked in Files wasn't added.
enum FileImportFailure: Error, Equatable {
    /// It couldn't be opened, or it was empty.
    case unreadable
    /// It is over the backup's limit, so it would attach on this phone and never back up.
    case tooLarge
}

/// Reads a file picked with a SwiftUI `.fileImporter` (F124, 2026-10-03 audit).
nonisolated enum FileImport {
    /// The largest file the backup takes: the sync's own limit (the Worker's MAX_BYTES), so the
    /// two can never disagree.
    static let byteLimit = GLSyncTransport.attachmentByteLimit

    /// The file's bytes, read on a background thread after its size is checked, handling the
    /// start/stop-access dance a picker URL needs on device. A file over `byteLimit` is refused
    /// before it is read, so a huge file never loads into memory.
    static func read(_ url: URL) async -> Result<Data, FileImportFailure> {
        await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > byteLimit {
                return .failure(.tooLarge)
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .failure(.unreadable) }
            // The size can be unknown up front (a file still in iCloud): check what was read.
            guard data.count <= byteLimit else { return .failure(.tooLarge) }
            return .success(data)
        }.value
    }
}

extension View {
    /// The one alert every Files importer shows when a pick can't be added. The message comes
    /// from the presented value, so it doesn't change while the alert animates away.
    func fileImportFailureAlert(_ failure: Binding<FileImportFailure?>) -> some View {
        alert("Couldn’t add that file",
              isPresented: Binding(get: { failure.wrappedValue != nil },
                                   set: { if !$0 { failure.wrappedValue = nil } }),
              presenting: failure.wrappedValue) { _ in
            Button("OK", role: .cancel) {}
        } message: { reason in
            switch reason {
            case .tooLarge:
                Text("That file is over 25 MB, so it can’t be backed up.")
            case .unreadable:
                Text("That file couldn’t be opened. Try a different file, or export it as a PDF first.")
            }
        }
    }
}
