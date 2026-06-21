//
//  DemoScreenshots.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  DEBUG-only deep-linking for App Store screenshot capture. Launch with
//  `-demoMode -demoScreen <name>` to land directly on a screen, so localized screenshots
//  can be captured deterministically from the command line. Never compiled into release.
//

#if DEBUG
import SwiftUI
import SwiftData

extension DemoMode {
    /// Screenshot target from `-demoScreen <name>`:
    /// customers | employees | subcontractors | invoice | estimate | company
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// True when the target is a single document to present full-screen.
    static var wantsDocument: Bool {
        screen == "invoice" || screen == "estimate" || screen == "company" || screen == "1099"
    }
}

/// Presents a single seeded document (invoice or estimate) full-screen for a clean marketing shot.
struct DemoDocumentScreenshot: View {
    @Query(sort: \Invoice.createdAt) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt) private var estimates: [Estimate]
    @Query private var profiles: [BusinessProfile]
    @Query private var subcontractors: [Subcontractor]

    var body: some View {
        if DemoMode.screen == "1099" {
            // Render the real 1099-NEC Copy B for the first sub over the $600 threshold.
            let year = Calendar.current.component(.year, from: .now)
            if let profile = profiles.first,
               let sub = subcontractors.first(where: { $0.requires1099() }),
               let url = Form1099NECPDF.render(payer: profile, recipient: sub, amount: sub.totalPaid(year: year), year: year),
               let image = Form1099NECPDF.pageImage(from: url) {
                ScrollView { Image(uiImage: image).resizable().scaledToFit().padding() }
                    .background(Color(white: 0.85))
            } else {
                ProgressView()
            }
        } else if DemoMode.screen == "company" {
            // MyCompanyFormScreen brings its own NavigationStack, so present it directly.
            if let profile = profiles.first {
                MyCompanyFormScreen(profile: profile)
            } else {
                ProgressView()
            }
        } else {
            NavigationStack {
                if DemoMode.screen == "estimate" {
                    let estimate = estimates.first { $0.number == "EST-0001" } ?? estimates.first
                    if let estimate { EstimateDetailScreen(estimate: estimate) } else { ProgressView() }
                } else {
                    let invoice = invoices.first { $0.number == "INV-0001" } ?? invoices.first
                    if let invoice { InvoiceDetailScreen(invoice: invoice) } else { ProgressView() }
                }
            }
        }
    }
}
#endif
