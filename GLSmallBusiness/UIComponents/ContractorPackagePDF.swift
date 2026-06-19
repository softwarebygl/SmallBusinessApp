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
        let safe = fileName.isEmpty ? "Contractor-Package.pdf" : fileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        return combined.write(to: url) ? url : nil
    }
}
