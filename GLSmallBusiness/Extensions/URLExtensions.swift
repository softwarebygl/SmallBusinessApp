//
//  URLExtensions.swift
//  GLSmallBusiness
//

import Foundation

extension URL {
    /// Reads a security-scoped file (e.g. one returned by a SwiftUI `.fileImporter`) into memory,
    /// handling the start/stop-access dance those picker URLs require on device. Returns nil if the
    /// file can't be read or is empty — callers treat nil as "couldn't import this file".
    func readSecurityScoped() -> Data? {
        let access = startAccessingSecurityScopedResource()
        defer { if access { stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: self), !data.isEmpty else { return nil }
        return data
    }
}
