//
//  ContractorPackagePDF.swift
//  GLSmallBusiness
//
//  Assembles a customer's Contractor Package — their insurer-issued Certificate of Liability
//  Insurance plus the general documents on file (W-9, workers'-comp insurance/exemption, license) —
//  into one shareable PDF.
//
//  Each customer's COI already names them as the certificate holder (it's issued that way by the
//  insurance company), so it's merged in as-is — nothing is stamped, drawn, or altered.
//

import UIKit
import PDFKit

enum ContractorPackagePDF {

    /// Builds a `PDFDocument` from document data that may be a PDF or a single image.
    static func document(from data: Data) -> PDFDocument? {
        if let doc = PDFDocument(data: data) { return doc }
        if let image = UIImage(data: data), let page = PDFPage(image: image) {
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            return doc
        }
        return nil
    }

    /// Merges the given document datas (PDFs and/or images), in order, into one PDF written to a temp
    /// file. Images become full pages. Returns nil if nothing readable was supplied.
    static func merge(_ sources: [Data], fileName: String) -> URL? {
        let combined = PDFDocument()
        var index = 0
        for data in sources {
            guard let doc = document(from: data) else { continue }
            for p in 0..<doc.pageCount {
                guard let page = doc.page(at: p), let copy = page.copy() as? PDFPage else { continue }
                combined.insert(copy, at: index)
                index += 1
            }
        }
        guard index > 0 else { return nil }
        // The package can embed the W-9 (full SSN/EIN), so it gets the same treatment as the 1099/W-9
        // generators: a fresh unique folder per render (prior generations wiped), written with complete
        // file protection, cleaned up by the presenting screen when it goes away.
        cleanUp()
        let safe = fileName.isEmpty ? "Contractor-Package.pdf" : fileName
        let folder = generatedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let data = combined.dataRepresentation() else { return nil }
        let url = folder.appendingPathComponent(safe)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static var generatedRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Generated-Contractor-Package", isDirectory: true)
    }

    /// Removes every generated package from tmp — call when the presenting screen disappears.
    nonisolated static func cleanUp() {
        try? FileManager.default.removeItem(at: generatedRoot)
    }
}
