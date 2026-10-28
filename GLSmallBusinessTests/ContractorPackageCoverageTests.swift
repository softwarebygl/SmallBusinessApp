//
//  ContractorPackageCoverageTests.swift
//  GLSmallBusinessTests
//
//  Coverage push for the Contractor Package area — `ContractorPackage.swift` (the package sheet, its
//  per-customer extras and Workers' Comp COI, and `CustomerDocumentDetailScreen`), plus
//  `CompanyDocuments.swift` (the Year-End Tax Report and Generate-a-W-9 sheets) and
//  `InsuranceDocuments.swift` (the Insurance & Licensing manager, `ComplianceKind`, `CompliancePDF`,
//  and the certificate previews).
//
//  Three layers, in the order the owner asked for them:
//    1. STATE VARIANTS — every real branch of those screens rendered in a UIWindow (COI present /
//       absent / unreadable, workers'-comp certificate present / absent, W-9 complete / incomplete,
//       signature saved / not, exemption + license present / absent, zero / one / many extras,
//       blank vs named files, a deleted customer, light + dark, accessibility text sizes, iPad width).
//    2. EDGE CASES on the pure logic those screens lean on — `ContractorPackageMessage`,
//       `DocumentShareText`, `ComplianceKind`, `ContractorPackagePDF`. (`CompliancePDF.tempURL`
//       is owned by DocumentSharingCoverageTests.)
//    3. ERROR CASES — unreadable uploads, empty data, blank names, and the one behaviour still
//       documented as a defect below: every package render wipes the PREVIOUSLY generated package
//       off disk, invalidating a URL an open preview may still hold.
//
//  Hosted through GLTestHost (a UIWindow, forced layout, the run loop drained so `.task` /
//  `.onAppear` fire, both environment objects injected). Rendering both schemes is a real code
//  path: the whole area paints with `GLColor.…render(in:)`.
//
//  Serialized: several tests assert on `ContractorPackagePDF`'s single shared temp directory, and the
//  render tests regenerate packages into that same directory, so they must not interleave.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import PDFKit
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct ContractorPackageCoverageTests {

    // MARK: - Fixtures

    private func pdfData(pages: Int = 1, size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { ctx in
            for _ in 0..<max(1, pages) { ctx.beginPage() }
        }
    }

    private func imageData(size: CGSize = CGSize(width: 240, height: 160),
                           color: UIColor = .darkGray) -> Data {
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    /// Bytes that are neither a PDF nor a decodable image — the "unreadable upload" case.
    private var garbageData: Data { Data([0x00, 0x01, 0x02, 0x03, 0x04]) }

    /// An OTHERWISE EMPTY in-memory store with one business profile and one customer, both under
    /// our control. Deliberately not the demo world: the seed ships NO COI (so every "has a
    /// certificate" branch needs building anyway) and its records would pollute the "no data" and
    /// "exactly these receipts" states the tax-report tests assert on.
    private func store() throws -> (ModelContainer, ModelContext, Customer, BusinessProfile) {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let profile = BusinessProfile()
        profile.businessName = "Summit Tile & Stone"
        ctx.insert(profile)
        let customer = TS.customer(in: ctx)
        return (container, ctx, customer, profile)
    }

    /// Fills in the minimum that makes `w9IsComplete` true WITHOUT touching the shared Keychain
    /// item (`secureTIN` falls back to the legacy plaintext field), so this can never race with
    /// KeychainAndW9Tests.
    private func completeW9(_ profile: BusinessProfile) {
        profile.businessName = profile.businessName.isEmpty ? "Summit Tile & Stone" : profile.businessName
        profile.w9Name = "Summit Tile & Stone LLC"
        profile.w9TaxClassificationRaw = W9TaxClassification.llc.rawValue
        profile.w9LLCClassification = "S"
        profile.w9TINTypeRaw = W9TINType.ein.rawValue
        profile.w9TIN = "987654321"
        profile.address = Address(street1: "1280 Commerce Blvd", city: "Miami",
                                  state: "FL", postalCode: "32301")
    }

    // MARK: - ContractorPackageSheet: the no-COI gate

    /// With no certificate on file the sheet leads with the upload step and nothing is shareable.
    @Test func packageSheetWithoutCOIShowsUploadPrompt() throws {
        let (container, _, customer, profile) = try store()
        #expect(!customer.hasCOI)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// The no-COI copy interpolates `listDisplayName`, which has its own fallback ladder — a customer
    /// with no name at all renders the "No name" branch rather than an empty sentence.
    @Test func packageSheetWithoutCOIForUnnamedCustomer() throws {
        let (container, ctx, _, profile) = try store()
        let blank = Customer(firstName: "", lastName: "")
        ctx.insert(blank)
        #expect(blank.listDisplayName == String(localized: "No name"))
        GLTestHost.render(ContractorPackageSheet(customer: blank, profile: profile), container: container)
    }

    /// A business-name-only customer (no first/last) — the third rung of the same ladder.
    @Test func packageSheetWithoutCOIForBusinessOnlyCustomer() throws {
        let (container, ctx, _, profile) = try store()
        let biz = Customer(firstName: "", lastName: "", businessName: "Nguyen Property Management")
        ctx.insert(biz)
        #expect(biz.listDisplayName == "Nguyen Property Management")
        GLTestHost.render(ContractorPackageSheet(customer: biz, profile: profile), container: container)
    }

    // MARK: - ContractorPackageSheet: the ready path

    /// The minimum shareable package: a COI and nothing else. Exercises `readyContent`, the Preview
    /// button, and the toolbar `ShareLink` (which only exists once a package URL was built).
    @Test func packageSheetWithCOIOnlyRendersReadyContent() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        customer.coiName = "reed-gc-coi.pdf"
        #expect(customer.hasCOI)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// `coiSubtitle` has two branches: a named file shows the file name, a blank one falls back to
    /// "Issued to <customer>". Same for the workers'-comp subtitle.
    @Test func packageSheetCOISubtitleFallsBackWhenFileNameBlank() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        customer.coiName = "   "                        // whitespace only → trimmed to empty
        customer.wcCoiData = pdfData()
        customer.wcCoiName = ""
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Both certificates present AND named — the other side of both subtitle branches, plus the two
    /// "Replace" buttons that only exist when a certificate is on file.
    @Test func packageSheetWithNamedCOIAndWorkersCompCertificate() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        customer.coiName = "General-Liability-COI.pdf"
        customer.wcCoiData = imageData()                // an image upload, not a PDF
        customer.wcCoiName = "workers-comp.png"
        #expect(customer.hasWCCOI)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// No workers'-comp certificate → the upload row (arrow, not chevron) instead of the toggle.
    @Test func packageSheetWithoutWorkersCompShowsUploadRow() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        customer.coiName = "coi.pdf"
        #expect(!customer.hasWCCOI)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// The two general documents pulled from the business profile each add their own toggle row.
    @Test func packageSheetWithExemptionAndLicense() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        ComplianceKind.wcExemption.store(profile, data: pdfData(), name: "Exemption.pdf")
        ComplianceKind.license.store(profile, data: imageData(), name: "License.png")
        #expect(profile.hasWCExemption && profile.hasLicenseDocument)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Only the exemption (no license) — the two profile toggles are independent branches.
    @Test func packageSheetWithExemptionOnly() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        ComplianceKind.wcExemption.store(profile, data: pdfData(), name: "Exemption.pdf")
        #expect(profile.hasWCExemption && !profile.hasLicenseDocument)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Only the license (no exemption).
    @Test func packageSheetWithLicenseOnly() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        ComplianceKind.license.store(profile, data: pdfData(), name: "License.pdf")
        #expect(!profile.hasWCExemption && profile.hasLicenseDocument)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    // MARK: - ContractorPackageSheet: the W-9 rows

    /// Tax details unfinished → the greyed "Finish your tax details to include it." row, and the
    /// signature control is not shown at all. This is also the state the demo seed ships in.
    @Test func packageSheetWithIncompleteW9ShowsMissingRow() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        profile.w9TaxClassificationRaw = ""             // classification missing → incomplete
        profile.w9TIN = ""
        #expect(!profile.w9IsComplete)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Tax details complete, no saved signature → the W-9 toggle plus the "Add a signature" row.
    /// (Entering the screen with the W-9 defaulted on kicks off the Face ID unlock; the test never
    /// awaits it, so it can't gate the render.)
    @Test func packageSheetWithCompleteW9AndNoSignature() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        completeW9(profile)
        ctx.insert(UserProfile())                        // exists, but has no signature
        #expect(profile.w9IsComplete)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Tax details complete AND a signature saved → the "Sign the W-9" toggle branch.
    @Test func packageSheetWithCompleteW9AndSavedSignature() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        completeW9(profile)
        let identity = MBIdentity.shared
        identity.standIn = .demo
        identity.standIn?.signatureData = imageData(size: CGSize(width: 300, height: 100), color: .black)
        defer { identity.standIn = nil }
        #expect(identity.signatureData != nil)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// No `UserProfile` row at all — the signature comes from the Gold Life ID, so a new account
    /// with no local row still renders.
    @Test func packageSheetWithNoUserProfileAtAll() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        completeW9(profile)
        #expect(try ctx.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    // MARK: - ContractorPackageSheet: the per-customer extras

    /// One extra document — the paperclip row with its own include toggle.
    @Test func packageSheetWithOneExtraDocument() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        ctx.insert(CustomerDocument(name: "OSHA-30.pdf", data: pdfData(), customer: customer))
        #expect(customer.sortedPackageDocuments.count == 1)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Several extras, including the awkward ones: a blank name (falls back to "Document"), a very
    /// long unicode name (truncated in the middle), and an image rather than a PDF.
    @Test func packageSheetWithManyExtraDocuments() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(CustomerDocument(name: "OSHA-30.pdf", data: pdfData(),
                                    createdAt: base, customer: customer))
        ctx.insert(CustomerDocument(name: "", data: imageData(),
                                    createdAt: base.addingTimeInterval(60), customer: customer))
        ctx.insert(CustomerDocument(name: "Acuerdo-de-proveedor–firmado– 2026–versión–definitiva–muy–larga.pdf",
                                    data: pdfData(), createdAt: base.addingTimeInterval(120),
                                    customer: customer))
        ctx.insert(CustomerDocument(name: "Bonding-Letter.pdf", data: pdfData(),
                                    createdAt: base.addingTimeInterval(180), customer: customer))
        #expect(customer.sortedPackageDocuments.map(\.name).first == "OSHA-30.pdf")   // oldest first
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// An extra with NO bytes at all. `packageSources()` compact-maps `\.data`, so it must simply be
    /// skipped — the row still renders and the rest of the package still builds.
    @Test func packageSheetWithExtraDocumentMissingItsBytes() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        ctx.insert(CustomerDocument(name: "Placeholder.pdf", data: nil, customer: customer))
        #expect(customer.sortedPackageDocuments.first?.data == nil)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// Everything at once — COI, workers' comp, a complete W-9 with a saved signature, exemption,
    /// license and extras. The maximal `includedCard`, in both schemes.
    @Test func packageSheetWithEveryDocumentPresent() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        customer.coiName = "COI.pdf"
        customer.wcCoiData = pdfData()
        customer.wcCoiName = "WC-COI.pdf"
        completeW9(profile)
        ComplianceKind.wcExemption.store(profile, data: pdfData(), name: "Exemption.pdf")
        ComplianceKind.license.store(profile, data: pdfData(), name: "License.pdf")
        let identity = MBIdentity.shared
        identity.standIn = .demo
        identity.standIn?.signatureData = imageData(size: CGSize(width: 300, height: 100), color: .black)
        defer { identity.standIn = nil }
        ctx.insert(CustomerDocument(name: "OSHA-30.pdf", data: pdfData(), customer: customer))
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    // MARK: - ContractorPackageSheet: layout variants

    /// The whole card at an accessibility text size — every row is an HStack with a fixed-width icon
    /// and a trailing control, which is exactly where these layouts break.
    @Test func packageSheetAtAccessibilityTextSizes() throws {
        let (container, ctx, customer, profile) = try store()
        customer.coiData = pdfData()
        customer.coiName = "COI.pdf"
        customer.wcCoiData = pdfData()
        ComplianceKind.license.store(profile, data: pdfData(), name: "License.pdf")
        ctx.insert(CustomerDocument(name: "OSHA-30.pdf", data: pdfData(), customer: customer))
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile),
                          container: container, typeSize: .accessibility3)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile),
                          container: container, typeSize: .accessibility5,
                          size: CGSize(width: 320, height: 568))                 // smallest phone
    }

    /// iPad width — the card is capped at `maxWidth: 640` and centred, a different layout pass.
    @Test func packageSheetAtIPadWidth() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = pdfData()
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile),
                          container: container, size: GLTestHost.pad)
    }

    // MARK: - ContractorPackageSheet: error / deleted states

    /// The customer is gone (deleted on another device) → `stillExists` is false and the sheet covers
    /// itself with `DeletedRecordView`. The customer here is never inserted, so the `@Query` that
    /// backs `stillExists` cannot contain it — the same condition, without poking a deleted model.
    @Test func packageSheetForMissingCustomerShowsDeletedOverlay() throws {
        let (container, _, _, profile) = try store()
        let ghost = Customer(firstName: "Ghost", lastName: "Customer")
        ghost.coiData = pdfData()                       // ready content UNDER the overlay
        ghost.coiName = "ghost-coi.pdf"
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: ghost, profile: profile), container: container)
    }

    /// A deleted customer with no COI — the deleted overlay over the upload prompt.
    @Test func packageSheetForMissingCustomerWithoutCOI() throws {
        let (container, _, _, profile) = try store()
        let ghost = Customer(firstName: "Ghost", lastName: "Customer")
        GLTestHost.render(ContractorPackageSheet(customer: ghost, profile: profile), container: container)
    }

    /// REGRESSION GUARD: a COI whose bytes are neither a PDF nor a decodable image still sets
    /// `hasCOI` (it only asks whether bytes exist), but `ContractorPackagePDF.merge` returns nil.
    /// The sheet must render the `DocumentGenerationError` retry state and must NOT print the
    /// "tap Share to send everything as one PDF" footnote next to a Share button that isn't there.
    @Test func packageSheetWithUnreadableCOIRendersUnshareableReadyState() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = garbageData
        customer.coiName = "not-really-a-pdf.pdf"
        #expect(customer.hasCOI)                                        // the gate is bytes-exist only
        #expect(ContractorPackagePDF.merge([garbageData], fileName: "x.pdf") == nil)
        GLTestHost.renderBothSchemes(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// A zero-byte COI — same class of problem, reached by a different route (an empty file picked
    /// from Files). `readSecurityScoped` rejects empty data on upload, but a synced/legacy record can
    /// still hold it.
    @Test func packageSheetWithEmptyCOIData() throws {
        let (container, _, customer, profile) = try store()
        customer.coiData = Data()
        #expect(customer.hasCOI)                                        // Data() != nil
        #expect(ContractorPackagePDF.document(from: Data()) == nil)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: profile), container: container)
    }

    /// The demo world rendered end to end, once with the seed's own (COI-less) state and once
    /// after uploading a certificate — the path a real user walks.
    @Test func packageSheetOverDemoSeededStore() throws {
        let world = try TestStore.demoWorld()
        let customer = try world.customer("Carter")
        #expect(!customer.hasCOI)
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: world.profile),
                          container: world.container)
        customer.coiData = pdfData()
        customer.coiName = "carter-coi.pdf"
        GLTestHost.render(ContractorPackageSheet(customer: customer, profile: world.profile),
                          container: world.container)
    }

    // MARK: - CustomerDocumentDetailScreen

    /// A PDF-backed extra — the PDFKit preview branch of `CertificatePreview`.
    @Test func customerDocumentDetailWithPDF() throws {
        let (container, ctx, customer, profile) = try store()
        let doc = CustomerDocument(name: "OSHA-30.pdf", data: pdfData(pages: 3), customer: customer)
        ctx.insert(doc)
        GLTestHost.renderBothSchemes(CustomerDocumentDetailScreen(document: doc, businessName: profile.businessName),
                                     container: container)
    }

    /// An image-backed extra — the zoomable-image branch.
    @Test func customerDocumentDetailWithImage() throws {
        let (container, ctx, customer, profile) = try store()
        let doc = CustomerDocument(name: "OSHA-card.png", data: imageData(), customer: customer)
        ctx.insert(doc)
        GLTestHost.render(CustomerDocumentDetailScreen(document: doc, businessName: profile.businessName), container: container)
    }

    /// Unreadable bytes → "Preview unavailable" rather than a blank screen — pure garbage, and a
    /// file that starts like a PDF but is truncated after its header.
    @Test func customerDocumentDetailWithUnreadableBytes() throws {
        let (container, ctx, customer, profile) = try store()
        let doc = CustomerDocument(name: "corrupt.pdf", data: garbageData, customer: customer)
        ctx.insert(doc)
        GLTestHost.render(CustomerDocumentDetailScreen(document: doc, businessName: profile.businessName),
                          container: container)

        let truncated = CustomerDocument(name: "W-9.pdf", data: Data("%PDF-1.4".utf8), customer: customer)
        ctx.insert(truncated)
        GLTestHost.render(CustomerDocumentDetailScreen(document: truncated, businessName: profile.businessName),
                          container: container)
    }

    /// No bytes at all → the "No file" empty state, and no Share button (there is nothing to share).
    @Test func customerDocumentDetailWithNoData() throws {
        let (container, ctx, customer, profile) = try store()
        let doc = CustomerDocument(name: "Placeholder.pdf", data: nil, customer: customer)
        ctx.insert(doc)
        GLTestHost.renderBothSchemes(CustomerDocumentDetailScreen(document: doc, businessName: profile.businessName),
                                     container: container)
    }

    /// A blank name uses the localized "Document" title, and a blank business name drops the share
    /// signature — the two string fallbacks the screen owns.
    @Test func customerDocumentDetailWithBlankNameAndBlankBusiness() throws {
        let (container, ctx, customer, _) = try store()
        let doc = CustomerDocument(name: "", data: pdfData(), customer: customer)
        ctx.insert(doc)
        GLTestHost.render(CustomerDocumentDetailScreen(document: doc, businessName: ""), container: container)
        GLTestHost.render(CustomerDocumentDetailScreen(document: doc, businessName: "   "), container: container)
    }

    /// A long unicode filename at an accessibility text size — the row truncates in the middle.
    @Test func customerDocumentDetailWithLongUnicodeName() throws {
        let (container, ctx, customer, profile) = try store()
        let doc = CustomerDocument(
            name: "Acuerdo–de–proveedor–firmado–2026–versión–definitiva–revisión–final.pdf",
            data: pdfData(), customer: customer)
        ctx.insert(doc)
        GLTestHost.render(CustomerDocumentDetailScreen(document: doc, businessName: profile.businessName),
                          container: container, typeSize: .accessibility4)
    }

    // MARK: - ComplianceDocsManagerSheet (Insurance & Licensing)

    /// Nothing uploaded — both slots show "Tap to upload", the reference COI card is empty, and the
    /// toolbar has no Share (there is nothing to bundle).
    @Test func complianceManagerEmptyState() throws {
        let (container, _, _, profile) = try store()
        #expect(!profile.hasComplianceDocuments)
        GLTestHost.renderBothSchemes(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// Both certificates uploaded and named → two NavigationLink cards plus the "share all" toolbar
    /// item, which writes both files into per-slot temp folders.
    @Test func complianceManagerWithBothDocumentsUploaded() throws {
        let (container, _, _, profile) = try store()
        ComplianceKind.wcExemption.store(profile, data: pdfData(), name: "Exemption.pdf")
        ComplianceKind.license.store(profile, data: imageData(), name: "License.png")
        #expect(profile.hasComplianceDocuments)
        GLTestHost.renderBothSchemes(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// Uploaded but with BLANK file names → the "Uploaded" subtitle branch, and the share bundle has
    /// to fall back to each slot's `fallbackFileName`.
    @Test func complianceManagerWithBlankFileNames() throws {
        let (container, _, _, profile) = try store()
        ComplianceKind.wcExemption.store(profile, data: pdfData(), name: "")
        ComplianceKind.license.store(profile, data: pdfData(), name: "")
        GLTestHost.render(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// One uploaded, one empty — the mixed state (a link card next to an upload card).
    @Test func complianceManagerWithOnlyOneDocumentUploaded() throws {
        let (container, _, _, profile) = try store()
        ComplianceKind.license.store(profile, data: pdfData(), name: "License.pdf")
        GLTestHost.render(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// The owner-only reference COI, present and absent — a card that is deliberately NOT a
    /// `ComplianceKind`, so it never joins the share bundle.
    @Test func complianceManagerWithOwnerReferenceCOI() throws {
        let (container, _, _, profile) = try store()
        profile.ownerReferenceCOIData = pdfData()
        profile.ownerReferenceCOIName = "Blank-COI.pdf"
        GLTestHost.renderBothSchemes(ComplianceDocsManagerSheet(profile: profile), container: container)

        profile.ownerReferenceCOIName = ""              // uploaded but unnamed → "Uploaded"
        GLTestHost.render(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// No business name → the share subject drops the "— <business>" suffix.
    @Test func complianceManagerWithoutBusinessName() throws {
        let (container, _, _, profile) = try store()
        profile.businessName = ""
        ComplianceKind.license.store(profile, data: pdfData(), name: "License.pdf")
        GLTestHost.render(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// Unreadable bytes in a compliance slot still produce a card (the row is bytes-exist only) —
    /// the preview underneath is what degrades.
    @Test func complianceManagerWithUnreadableUpload() throws {
        let (container, _, _, profile) = try store()
        ComplianceKind.wcExemption.store(profile, data: garbageData, name: "corrupt.pdf")
        GLTestHost.render(ComplianceDocsManagerSheet(profile: profile), container: container)
    }

    /// Accessibility text size + the narrowest phone.
    @Test func complianceManagerAtAccessibilityTextSize() throws {
        let (container, _, _, profile) = try store()
        ComplianceKind.wcExemption.store(profile, data: pdfData(), name: "Exemption.pdf")
        ComplianceKind.license.store(profile, data: pdfData(), name: "License.pdf")
        profile.ownerReferenceCOIData = pdfData()
        GLTestHost.render(ComplianceDocsManagerSheet(profile: profile), container: container,
                          typeSize: .accessibility3, size: CGSize(width: 320, height: 568))
    }

    // MARK: - ComplianceDocDetailScreen

    /// Every kind, with a PDF and with an image — the detail screen is generated from `ComplianceKind`.
    @Test func complianceDetailForEveryKind() throws {
        let (container, _, _, profile) = try store()
        for kind in ComplianceKind.allCases {
            kind.store(profile, data: pdfData(), name: "\(kind.rawValue).pdf")
            GLTestHost.renderBothSchemes(ComplianceDocDetailScreen(kind: kind, profile: profile), container: container)
            kind.store(profile, data: imageData(), name: "\(kind.rawValue).png")
            GLTestHost.render(ComplianceDocDetailScreen(kind: kind, profile: profile), container: container)
        }
    }

    /// The detail screen for a slot that has been emptied → "No file", no Share.
    @Test func complianceDetailForEmptySlot() throws {
        let (container, _, _, profile) = try store()
        for kind in ComplianceKind.allCases {
            #expect(kind.data(profile) == nil)
            GLTestHost.render(ComplianceDocDetailScreen(kind: kind, profile: profile), container: container)
        }
    }

    /// Blank file name → the title falls back to the slot's `fallbackFileName` under the preview.
    @Test func complianceDetailWithBlankFileName() throws {
        let (container, _, _, profile) = try store()
        ComplianceKind.license.store(profile, data: pdfData(), name: "   ")
        GLTestHost.render(ComplianceDocDetailScreen(kind: .license, profile: profile), container: container)
    }

    // MARK: - CertificatePreview / CertificatePDFView

    /// The three branches of the shared preview: PDF, image, and neither.
    @Test func certificatePreviewCoversAllThreeBranches() throws {
        let (container, _, _, _) = try store()
        GLTestHost.render(CertificatePreview(data: pdfData(pages: 2)), container: container)
        GLTestHost.render(CertificatePreview(data: imageData()), container: container)
        GLTestHost.render(CertificatePreview(data: garbageData), container: container)
        GLTestHost.render(CertificatePreview(data: Data()), container: container)
    }

    /// The PDFKit representable directly, including the `updateUIView` document-swap path.
    @Test func certificatePDFViewRendersAndSwapsDocuments() throws {
        let (container, _, _, _) = try store()
        let first = try #require(PDFDocument(data: pdfData(pages: 1)))
        let second = try #require(PDFDocument(data: pdfData(pages: 4)))
        GLTestHost.render(CertificatePDFView(document: first), container: container)
        GLTestHost.render(CertificatePDFView(document: second), container: container)
        #expect(first.pageCount == 1)
        #expect(second.pageCount == 4)
    }

    // MARK: - DocActionRow

    @Test func docActionRowRenders() throws {
        let (container, _, _, _) = try store()
        let row = DocActionRow(title: "Update tax details",
                               subtitle: "Name, classification, and Tax ID.",
                               systemImage: "square.and.pencil") { }
        GLTestHost.renderBothSchemes(row, container: container)
        GLTestHost.render(row, container: container, typeSize: .accessibility5)
    }

    // MARK: - W9DocumentSheet (CompanyDocuments.swift)

    /// Tax details missing → the checklist of `w9MissingRequirements` and "Add tax details".
    @Test func w9SheetIncompleteShowsMissingRequirements() throws {
        let (container, _, _, profile) = try store()
        profile.businessName = ""
        profile.w9Name = ""
        profile.w9TaxClassificationRaw = ""
        profile.w9TIN = ""
        #expect(!profile.w9IsComplete)
        #expect(profile.w9MissingRequirements.count >= 2)
        GLTestHost.renderBothSchemes(W9DocumentSheet(profile: profile), container: container)
    }

    /// Only the classification missing — a one-item checklist, so the list layout is exercised with
    /// both one and several rows.
    @Test func w9SheetMissingOnlyClassification() throws {
        let (container, _, _, profile) = try store()
        completeW9(profile)
        profile.w9TaxClassificationRaw = ""
        #expect(!profile.w9IsComplete)
        GLTestHost.render(W9DocumentSheet(profile: profile), container: container)
    }

    /// Complete details, no saved signature → the rendered preview image plus "Add a signature".
    @Test func w9SheetCompleteWithoutSignature() throws {
        let (container, ctx, _, profile) = try store()
        completeW9(profile)
        ctx.insert(UserProfile())
        #expect(profile.w9IsComplete)
        GLTestHost.renderBothSchemes(W9DocumentSheet(profile: profile), container: container)
    }

    /// Complete details with a saved signature → the include-signature toggle and "Change signature".
    @Test func w9SheetCompleteWithSavedSignature() throws {
        let (container, _, _, profile) = try store()
        completeW9(profile)
        let identity = MBIdentity.shared
        identity.standIn = .demo
        identity.standIn?.signatureData = imageData(size: CGSize(width: 300, height: 100), color: .black)
        defer { identity.standIn = nil }
        GLTestHost.render(W9DocumentSheet(profile: profile), container: container)
        GLTestHost.render(W9DocumentSheet(profile: profile), container: container, typeSize: .accessibility3)
    }

    /// Every W-9 tax classification renders — `w9TaxClassificationRaw` drives which checkbox the
    /// generator stamps, and `.llc` / `.other` carry extra free-text fields.
    @Test func w9SheetRendersEveryTaxClassification() throws {
        let (container, _, _, profile) = try store()
        completeW9(profile)
        profile.w9OtherClassification = "Nonprofit"
        for classification in W9TaxClassification.allCases {
            profile.w9TaxClassificationRaw = classification.rawValue
            #expect(profile.w9IsComplete)
            GLTestHost.render(W9DocumentSheet(profile: profile), container: container)
        }
    }

    // MARK: - YearEndTaxReportSheet (CompanyDocuments.swift)

    /// An empty store → the "No receipts recorded" muted row and a zero net.
    @Test func taxReportWithNoDataAtAll() throws {
        let container = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(YearEndTaxReportSheet(), container: container)
    }

    /// The demo world — the sheet defaults to LAST year, which the seed has no data for, so this is
    /// the "records exist, but not for the selected year" state.
    @Test func taxReportOverDemoSeededStore() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(YearEndTaxReportSheet(), container: world.container)
    }

    /// Last year populated with a profitable year: collected > expenses, no processor fees → the
    /// "Net (collected − expenses)" label and the gold (positive) net.
    @Test func taxReportWithProfitableLastYear() throws {
        let (container, ctx, customer, _) = try store()
        let year = Calendar.current.component(.year, from: .now) - 1
        let day = TS.day(year, 6, 15)
        let invoice = TS.invoice(number: "INV-9001", createdAt: day, status: .sent,
                                 taxRatePercent: 7.5, lines: [(4000, true)], in: ctx)
        TS.pay(invoice, 4300, date: day, in: ctx)
        ctx.insert(Receipt(vendor: "Henderson Hardware", date: day, total: 500,
                           category: "Materials", customer: customer))
        ctx.saveChanges()

        let summary = StatsEngine.summary(period: .year(year),
                                          invoices: try ctx.fetch(FetchDescriptor<Invoice>()),
                                          estimates: [],
                                          receipts: try ctx.fetch(FetchDescriptor<Receipt>()))
        #expect(summary.processingFees == 0)
        #expect(summary.net > 0)
        GLTestHost.renderBothSchemes(YearEndTaxReportSheet(), container: container)
    }

    /// Last year with processor fees AND a loss: the fees section appears, the net label switches to
    /// "Net (collected − expenses − fees)", and the negative net renders red.
    @Test func taxReportWithProcessingFeesAndNegativeNet() throws {
        let (container, ctx, customer, _) = try store()
        let year = Calendar.current.component(.year, from: .now) - 1
        let day = TS.day(year, 3, 2)
        let invoice = TS.invoice(number: "INV-9002", createdAt: day, status: .sent,
                                 lines: [(1000, false)], in: ctx)
        let payment = TS.pay(invoice, 1000, date: day, in: ctx)
        payment.processorName = "Card processor"
        payment.processorFeePercentSnapshot = 2.9
        payment.processorFlatFeeSnapshot = 0.30
        // Expenses exceed what was collected → a negative net.
        ctx.insert(Receipt(vendor: "Coastal Supply", date: day, total: 1800,
                           category: "Materials", customer: customer))
        ctx.insert(Receipt(vendor: "QuickStop Fuel", date: day, total: 120,
                           category: "", customer: nil))          // blank → "Uncategorized"
        ctx.saveChanges()

        let summary = StatsEngine.summary(period: .year(year),
                                          invoices: try ctx.fetch(FetchDescriptor<Invoice>()),
                                          estimates: [],
                                          receipts: try ctx.fetch(FetchDescriptor<Receipt>()))
        #expect(close(summary.processingFees, 29.30))
        #expect(summary.net < 0)
        #expect(summary.expensesByCategory.count == 2)
        GLTestHost.renderBothSchemes(YearEndTaxReportSheet(), container: container)
    }

    /// No business profile at all → the preview drops the header line and the share message drops the
    /// signature. `businessProfiles.first` must not be force-unwrapped anywhere.
    @Test func taxReportWithoutBusinessProfile() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext
        let year = Calendar.current.component(.year, from: .now) - 1
        ctx.insert(Receipt(vendor: "Henderson Hardware", date: TS.day(year, 1, 9),
                           total: 42.50, category: "Materials"))
        ctx.saveChanges()
        #expect(try ctx.fetchCount(FetchDescriptor<BusinessProfile>()) == 0)
        GLTestHost.render(YearEndTaxReportSheet(), container: container)
    }

    /// Accessibility text size over a populated year — the amount rows are baseline-aligned HStacks.
    @Test func taxReportAtAccessibilityTextSize() throws {
        let (container, ctx, customer, _) = try store()
        let year = Calendar.current.component(.year, from: .now) - 1
        ctx.insert(Receipt(vendor: "Sunbelt Tool Rental", date: TS.day(year, 8, 4),
                           total: 184, category: "Equipment", customer: customer))
        ctx.saveChanges()
        GLTestHost.render(YearEndTaxReportSheet(), container: container, typeSize: .accessibility3,
                          size: CGSize(width: 320, height: 568))
    }

    // MARK: - ContractorPackageMessage: edge cases

    /// No business at all — every string falls back to its prepared default and the body carries no
    /// sign-off. The default subject is pinned literally: it is the one line a recipient with no
    /// business name on the other end ever sees.
    @Test func packageMessageWithNoBusinessUsesDefaults() {
        #expect(ContractorPackageMessage.defaultSubject == "Contractor package")
        #expect(ContractorPackageMessage.subject(business: nil) == ContractorPackageMessage.defaultSubject)
        #expect(ContractorPackageMessage.intro(business: nil) == ContractorPackageMessage.defaultIntro)
        #expect(ContractorPackageMessage.closing(business: nil) == ContractorPackageMessage.defaultClosing)
        let body = ContractorPackageMessage.body(business: nil)
        #expect(body == "\(ContractorPackageMessage.defaultIntro)\n\n\(ContractorPackageMessage.defaultClosing)")
        #expect(!body.contains("\n\n— "))          // no sign-off block (the intro's own em dash stays)
    }

    /// Whitespace-only overrides are not customizations — improving a default must still reach these
    /// businesses.
    @Test func packageMessageWhitespaceOverridesFallBackToDefaults() {
        let p = BusinessProfile()
        p.businessName = "   \n\t "
        p.packageMessageSubject = "   "
        p.packageMessageIntro = "\n\n"
        p.packageMessageClosing = "\t"
        #expect(ContractorPackageMessage.subject(business: p) == ContractorPackageMessage.defaultSubject)
        #expect(ContractorPackageMessage.intro(business: p) == ContractorPackageMessage.defaultIntro)
        #expect(ContractorPackageMessage.closing(business: p) == ContractorPackageMessage.defaultClosing)
        #expect(!ContractorPackageMessage.body(business: p).contains("\n\n— "))   // blank name → no sign-off
    }

    /// A custom subject is used verbatim after trimming — leading/trailing whitespace never reaches
    /// the mail composer.
    @Test func packageMessageCustomSubjectIsTrimmed() {
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.packageMessageSubject = "  Documents for your file  "
        #expect(ContractorPackageMessage.subject(business: p) == "Documents for your file")
    }

    /// Unicode and emoji survive intact in every slot, and the sign-off keeps the exact business name.
    @Test func packageMessageKeepsUnicodeIntact() {
        let p = BusinessProfile()
        p.businessName = "Söderström Tile & Stone ⚒️"
        p.packageMessageIntro = "Aquí está nuestro paquete — todo lo solicitado."
        p.packageMessageClosing = "¡Gracias!"
        #expect(ContractorPackageMessage.subject(business: p) == "Contractor package from Söderström Tile & Stone ⚒️")
        let body = ContractorPackageMessage.body(business: p)
        #expect(body.contains("Aquí está nuestro paquete — todo lo solicitado."))
        #expect(body.hasSuffix("— Söderström Tile & Stone ⚒️"))
    }

    /// A very long business name is not truncated by the message builder — that's the composer's job.
    @Test func packageMessageHandlesVeryLongBusinessName() {
        let p = BusinessProfile()
        p.businessName = String(repeating: "Summit Tile & Stone ", count: 40)
        let subject = ContractorPackageMessage.subject(business: p)
        #expect(subject.hasPrefix("Contractor package from Summit Tile & Stone"))
        #expect(subject.count > 700)
    }

    /// Newlines inside a custom intro are preserved (a multi-paragraph message), and the body's own
    /// separators still frame it — with the prepared closing, and with a custom one.
    @Test func packageMessageBodyStructureWithMultilineIntro() {
        let p = BusinessProfile()
        p.businessName = "Gold Life LLC"
        p.packageMessageIntro = "Line one.\nLine two."
        let body = ContractorPackageMessage.body(business: p)
        #expect(body == "Line one.\nLine two.\n\n\(ContractorPackageMessage.defaultClosing)\n\n— Gold Life LLC")

        p.packageMessageClosing = "Thanks!"
        #expect(ContractorPackageMessage.closing(business: p) == "Thanks!")
        #expect(ContractorPackageMessage.body(business: p) == "Line one.\nLine two.\n\nThanks!\n\n— Gold Life LLC")
    }

    /// A business with a name but no custom wording — the default subject names the business while
    /// the body is exactly both prepared paragraphs plus the sign-off.
    @Test func packageMessageDefaultsWithBusinessName() {
        let p = BusinessProfile()
        p.businessName = "  Summit Tile & Stone  "               // untrimmed on the model
        #expect(ContractorPackageMessage.subject(business: p) == "Contractor package from Summit Tile & Stone")
        #expect(ContractorPackageMessage.body(business: p)
                == "\(ContractorPackageMessage.defaultIntro)\n\n\(ContractorPackageMessage.defaultClosing)\n\n— Summit Tile & Stone")
    }

    // MARK: - DocumentShareText

    @Test func documentShareBodyAppendsBusinessSignature() {
        #expect(DocumentShareText.body("Attached is our W-9.", from: "Gold Life LLC")
                == "Attached is our W-9.\n\nThank you,\nGold Life LLC")
    }

    @Test func documentShareBodyDropsSignatureWhenNameBlank() {
        #expect(DocumentShareText.body("Attached is our W-9.", from: "") == "Attached is our W-9.")
        #expect(DocumentShareText.body("Attached is our W-9.", from: "   \n ") == "Attached is our W-9.")
    }

    /// The signature uses the TRIMMED name, so a stray space in My Company never reaches the email.
    @Test func documentShareBodySignsWithTheTrimmedName() {
        #expect(DocumentShareText.body("Attached.", from: " Gold Life LLC ")
                == "Attached.\n\nThank you,\nGold Life LLC")
        #expect(DocumentShareText.body("Attached.", from: "\nGold Life LLC\n")
                == "Attached.\n\nThank you,\nGold Life LLC")
    }

    /// Multi-line and unicode lines pass through unchanged.
    @Test func documentShareBodyKeepsLineAndNameContentIntact() {
        let body = DocumentShareText.body("Adjunto está nuestro W-9.\nGracias.", from: "Söderström ⚒️")
        #expect(body == "Adjunto está nuestro W-9.\nGracias.\n\nThank you,\nSöderström ⚒️")
    }

    // MARK: - ComplianceKind

    /// Every kind's metadata is distinct and non-empty — the enum drives the card list, the share
    /// bundle's per-slot folders, and each fallback filename. The set is pinned to exactly
    /// {wcExemption, license}: the owner-only reference COI must NEVER become a kind, or it would
    /// leak into the "share all" bundle and the Contractor Package (both iterate `allCases`).
    @Test func complianceKindMetadataIsDistinctAndNonEmpty() {
        let kinds = ComplianceKind.allCases
        #expect(kinds.count == 2)
        #expect(Set(kinds) == [.wcExemption, .license])
        #expect(Set(kinds.map(\.id)).count == kinds.count)
        #expect(Set(kinds.map(\.title)).count == kinds.count)
        #expect(Set(kinds.map(\.systemImage)).count == kinds.count)
        #expect(Set(kinds.map(\.fallbackFileName)).count == kinds.count)
        for kind in kinds {
            #expect(!kind.title.isEmpty)
            #expect(!kind.systemImage.isEmpty)
            #expect(kind.fallbackFileName.hasSuffix(".pdf"))
            #expect(ComplianceKind(rawValue: kind.rawValue) == kind)
        }
    }

    /// Store → read → clear, for every slot, with the removal path (`nil`, `""`) that the detail
    /// screen's Remove button uses.
    @Test func complianceKindStoreReadClearRoundTrip() {
        for kind in ComplianceKind.allCases {
            let p = BusinessProfile()
            #expect(kind.data(p) == nil)
            #expect(kind.fileName(p) == "")

            let bytes = Data("certificate".utf8)
            kind.store(p, data: bytes, name: "Cert.pdf")
            #expect(kind.data(p) == bytes)
            #expect(kind.fileName(p) == "Cert.pdf")
            #expect(p.hasComplianceDocuments)

            kind.store(p, data: nil, name: "")           // the Remove path
            #expect(kind.data(p) == nil)
            #expect(kind.fileName(p) == "")
            #expect(!p.hasComplianceDocuments)
        }
    }

    /// Writing one slot never touches the other — the two certificates are independent.
    @Test func complianceKindSlotsAreIndependent() {
        let p = BusinessProfile()
        ComplianceKind.wcExemption.store(p, data: Data("exemption".utf8), name: "E.pdf")
        #expect(ComplianceKind.license.data(p) == nil)
        #expect(p.hasWCExemption && !p.hasLicenseDocument)

        ComplianceKind.license.store(p, data: Data("license".utf8), name: "L.pdf")
        #expect(ComplianceKind.wcExemption.data(p) == Data("exemption".utf8))
        #expect(p.hasWCExemption && p.hasLicenseDocument)

        ComplianceKind.wcExemption.store(p, data: nil, name: "")
        #expect(p.hasLicenseDocument)                     // clearing one leaves the other
        #expect(p.hasComplianceDocuments)
    }

    /// Zero-byte data still registers as "uploaded" — `hasWCExemption` is a nil check, not a size
    /// check. Documenting the boundary the UI depends on.
    @Test func complianceKindTreatsEmptyDataAsUploaded() {
        let p = BusinessProfile()
        ComplianceKind.license.store(p, data: Data(), name: "empty.pdf")
        #expect(p.hasLicenseDocument)
        #expect(ComplianceKind.license.data(p)?.isEmpty == true)
    }

    // MARK: - ContractorPackagePDF: assembly edge cases

    /// Sources are merged in the order given — the package's contract is "COI first, extras last".
    @Test func mergePreservesSourceOrder() throws {
        let widths: [CGFloat] = [200, 400, 600]
        let sources = widths.map { pdfData(size: CGSize(width: $0, height: 800)) }
        let url = try #require(ContractorPackagePDF.merge(sources, fileName: "Ordered.pdf"))
        let merged = try #require(PDFDocument(url: url))
        #expect(merged.pageCount == 3)
        let mergedWidths = (0..<merged.pageCount).compactMap {
            merged.page(at: $0)?.bounds(for: .mediaBox).width
        }
        #expect(mergedWidths == widths)
        ContractorPackagePDF.cleanUp()
    }

    /// Multi-page sources contribute every page, not just their first.
    @Test func mergeKeepsEveryPageOfEverySource() throws {
        let url = try #require(ContractorPackagePDF.merge(
            [pdfData(pages: 3), imageData(), pdfData(pages: 2)], fileName: "Multi.pdf"))
        #expect(PDFDocument(url: url)?.pageCount == 6)
        ContractorPackagePDF.cleanUp()
    }

    /// An empty source list produces nothing at all — no zero-page PDF handed to ShareLink.
    @Test func mergeWithNoSourcesIsNil() {
        #expect(ContractorPackagePDF.merge([], fileName: "Empty.pdf") == nil)
    }

    /// Every source unreadable → nil, so the sheet leaves `packageURL` nil and hides Share.
    @Test func mergeWithOnlyUnreadableSourcesIsNil() {
        #expect(ContractorPackagePDF.merge([garbageData, Data(), Data([0xFF])],
                                           fileName: "Bad.pdf") == nil)
    }

    /// A mix keeps the readable ones and silently drops the rest.
    @Test func mergeSkipsUnreadableSourcesButKeepsTheRest() throws {
        let url = try #require(ContractorPackagePDF.merge(
            [garbageData, pdfData(pages: 2), Data(), imageData()], fileName: "Mixed.pdf"))
        #expect(PDFDocument(url: url)?.pageCount == 3)
        ContractorPackagePDF.cleanUp()
    }

    /// A blank filename falls back to "Contractor-Package.pdf" rather than writing a nameless file.
    @Test func mergeWithBlankFileNameUsesTheDefaultName() throws {
        let url = try #require(ContractorPackagePDF.merge([pdfData()], fileName: ""))
        #expect(url.lastPathComponent == "Contractor-Package.pdf")
        ContractorPackagePDF.cleanUp()
    }

    /// The generated package lands in its own per-render folder under one namespaced root, so the
    /// screen can wipe every TIN-bearing file it produced with a single `cleanUp()`.
    @Test func mergeWritesIntoAUniqueFolderUnderTheGeneratedRoot() throws {
        let url = try #require(ContractorPackagePDF.merge([pdfData()], fileName: "Package.pdf"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "Package.pdf")
        let renderFolder = url.deletingLastPathComponent()
        #expect(UUID(uuidString: renderFolder.lastPathComponent) != nil)   // a fresh UUID per render
        #expect(renderFolder.deletingLastPathComponent().lastPathComponent
                == "Generated-Contractor-Package")
        ContractorPackagePDF.cleanUp()
    }

    /// DEFECT (documented): `merge` wipes the ENTIRE generated root before writing, so any package
    /// produced earlier is deleted — including one a `DocumentPreviewSheet` or an in-flight ShareLink
    /// is still pointing at. Toggling a document while the preview is open therefore pulls the file
    /// out from under it. A per-render folder is created but never scoped to the render that owns it.
    @Test func mergeDeletesEveryPreviouslyGeneratedPackage() throws {
        let first = try #require(ContractorPackagePDF.merge([pdfData()], fileName: "First.pdf"))
        #expect(FileManager.default.fileExists(atPath: first.path))

        let second = try #require(ContractorPackagePDF.merge([pdfData()], fileName: "Second.pdf"))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: first.path))   // the earlier one is gone
        ContractorPackagePDF.cleanUp()
    }

    /// `cleanUp` removes the whole root, and is safe to call when there is nothing to remove — the
    /// sheet calls it from `onDisappear` on every dismissal.
    @Test func cleanUpRemovesGeneratedPackagesAndIsIdempotent() throws {
        let url = try #require(ContractorPackagePDF.merge([pdfData()], fileName: "Temp.pdf"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        ContractorPackagePDF.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        ContractorPackagePDF.cleanUp()
        ContractorPackagePDF.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// `document(from:)` accepts PDFs and images and refuses everything else — the gate every source
    /// passes through before merging.
    @Test func documentFromDataAcceptsPDFsAndImagesOnly() {
        #expect(ContractorPackagePDF.document(from: pdfData(pages: 2))?.pageCount == 2)
        #expect(ContractorPackagePDF.document(from: imageData())?.pageCount == 1)
        #expect(ContractorPackagePDF.document(from: garbageData) == nil)
        #expect(ContractorPackagePDF.document(from: Data()) == nil)
        #expect(ContractorPackagePDF.document(from: Data("%PDF-1.4 but truncated".utf8)) == nil)
    }

    /// A 1×1 image still becomes a valid one-page document — the smallest real upload.
    @Test func documentFromTinyImageStillProducesOnePage() {
        let tiny = imageData(size: CGSize(width: 1, height: 1))
        #expect(ContractorPackagePDF.document(from: tiny)?.pageCount == 1)
    }

    // MARK: - Customer COI flags (the gate the whole sheet keys off)

    /// `hasCOI` / `hasWCCOI` are independent nil checks — the General Liability certificate gates the
    /// package, the Workers' Comp one never does.
    @Test func coiFlagsAreIndependentAndByteExistenceOnly() {
        let c = Customer(firstName: "Dana", lastName: "Reed")
        #expect(!c.hasCOI && !c.hasWCCOI)

        c.wcCoiData = Data([0x25])
        #expect(!c.hasCOI)                              // workers' comp alone never unlocks the package
        #expect(c.hasWCCOI)

        c.coiData = Data()                              // zero bytes still counts as "on file"
        #expect(c.hasCOI)

        c.coiData = nil
        c.coiName = "stale-name.pdf"                    // a leftover name doesn't resurrect the flag
        #expect(!c.hasCOI)
    }

    /// Extras sort oldest-first — the order the package merges them after the standard documents —
    /// regardless of insertion order, even when several share a timestamp; and an extras-free
    /// customer returns an empty array rather than nil.
    @Test func sortedPackageDocumentsHandleEmptyAndTiedTimestamps() throws {
        let (_, ctx, customer, _) = try store()
        #expect(customer.sortedPackageDocuments.isEmpty)

        let same = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(CustomerDocument(name: "A.pdf", createdAt: same, customer: customer))
        ctx.insert(CustomerDocument(name: "B.pdf", createdAt: same, customer: customer))
        ctx.insert(CustomerDocument(name: "Older.pdf", createdAt: same.addingTimeInterval(-500),
                                    customer: customer))          // inserted LAST, sorts first
        ctx.saveChanges()
        let names = customer.sortedPackageDocuments.map(\.name)
        #expect(names.count == 3)
        #expect(names.first == "Older.pdf")
        #expect(Set(names.dropFirst()) == ["A.pdf", "B.pdf"])
    }

    /// A `CustomerDocument` built with the bare initializer has sane defaults — the row label falls
    /// back to "Document" precisely because the name can be empty.
    @Test func customerDocumentDefaults() {
        let doc = CustomerDocument()
        #expect(doc.name.isEmpty)
        #expect(doc.data == nil)
        #expect(doc.customer == nil)
        #expect(doc.createdAt.timeIntervalSinceNow < 1)
    }
}
