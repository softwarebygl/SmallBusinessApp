//
//  PaginatedPDF.swift
//  GLSmallBusiness
//
//  Forwarding wrapper to GLPaginatedPDF from GoldLifeDocuments (law 87, Zero Duplication),
//  injecting the app's current locale.
//

import SwiftUI
import GoldLifeDocuments

@MainActor
enum PaginatedPDF {
    nonisolated static let pageWidth: CGFloat = GLPaginatedPDF.pageWidth
    nonisolated static let pageHeight: CGFloat = GLPaginatedPDF.pageHeight

    static func render(_ content: some View, width: CGFloat = pageWidth, to url: URL, scale: CGFloat = 2) -> URL? {
        GLPaginatedPDF.render(content, width: width, to: url, locale: MBLocalization.currentLocale, scale: scale)
    }

    static func renderSections(_ sections: [AnyView], width: CGFloat = pageWidth, to url: URL, scale: CGFloat = 2) -> URL? {
        GLPaginatedPDF.renderSections(sections, width: width, to: url, locale: MBLocalization.currentLocale, scale: scale)
    }
}
