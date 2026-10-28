//
//  ViewRenderingTests.swift
//  GLSmallBusinessTests
//
//  Smoke renders for the screens NO dedicated coverage suite hosts. Each screen is put on
//  screen through GLTestHost over the demo dataset (DemoWorld) so its body — and its
//  `.onAppear`/`.task` — evaluates; the assertion is that nothing traps. What hosting can and
//  cannot prove is in GLTestHost's header: this is a crash net, not a content check.
//
//  Anything a coverage suite renders in a richer state was removed from here (suite review
//  2026-09-02): the customers list, every global/per-customer list and the iPad split →
//  ListsAndIPadCoverageTests; invoices, their forms and payment sheets →
//  InvoiceLifecycleCoverageTests; the calendar, jobs, estimates and change orders →
//  CalendarJobsEstimatesCoverageTests; employees and payroll sheets →
//  EmployeePayrollCoverageTests; subcontractors, their sheets and the 1099 →
//  SubcontractorCoverageTests; W-9, year-end tax, compliance docs and the contractor package →
//  ContractorPackageCoverageTests; paywall, Stripe, Gold Life ID sign-in, About →
//  UnrenderedScreensCoverageTests. Check those before adding a screen here — a screen hosted
//  twice is tested once and paid for twice.
//

import Testing
import SwiftUI
import GoldLifeUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct ViewRenderingTests {

    // MARK: - Hubs and settings

    /// The menu, stats, settings and company screens over the demo dataset. The design-snapshot
    /// matrix hosts the first three too, but only with MM_SNAPSHOT_DIR set — in the default
    /// run this is the one place they are rendered.
    @Test func rendersHubsAndSettings() throws {
        let world = try TestStore.demoWorld()
        GLTestHost.render(MenuScreen(), container: world.container)
        GLTestHost.render(StatsScreen(), container: world.container)
        GLTestHost.render(SettingsScreen(), container: world.container)
        GLTestHost.render(MyCompanyDetailScreen(), container: world.container)
        GLTestHost.render(MyCompanyFormScreen(profile: world.profile), container: world.container)
        // The person's screen — Personal merged into Gold Life ID (2026-08-22).
        GLTestHost.render(GoldLifeIDScreen(), container: world.container)
        // The 2026-08-22 restructure's new doors: business documents behind one row, and the
        // document wording living in Settings.
        GLTestHost.render(AllDocumentsScreen(profile: world.profile), container: world.container)
        GLTestHost.render(DocumentSettingsScreen(), container: world.container)
        GLTestHost.render(ZelleConnectScreen(), container: world.container)
        GLTestHost.render(SubcontractorsScreen(isTabRoot: true), container: world.container)
        // Pushed branch (Menu > Documents > Subcontractor 1099s): renders inside the host's stack.
        GLTestHost.render(SubcontractorsScreen(), container: world.container)
        GLTestHost.render(ReceiptsTabScreen(), container: world.container)
    }

    /// The same hubs over an EMPTY store — every "nothing yet" branch.
    @Test func rendersHubsOverAnEmptyStore() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.render(MenuScreen(), container: empty)
        GLTestHost.render(StatsScreen(), container: empty)
        GLTestHost.render(SubcontractorsScreen(isTabRoot: true), container: empty)
    }

    // MARK: - Customers: the detail screens and the form

    @Test func rendersCustomerScreens() throws {
        let world = try TestStore.demoWorld()
        // Every customer, not one: COI present vs absent and the other conditional branches of
        // the hub that a single instance never reaches.
        for customer in world.customers {
            GLTestHost.render(CustomerDetailScreen(customer: customer), container: world.container)
        }
        GLTestHost.render(CustomerDetailsScreen(customer: world.primary), container: world.container)
        GLTestHost.render(CustomerCOIDetailScreen(customer: world.primary), container: world.container)
        GLTestHost.render(CustomerFormScreen(), container: world.container)
        GLTestHost.render(CustomerFormScreen(editing: world.primary), container: world.container)
    }

    // MARK: - Receipts

    @Test func rendersReceiptScreens() throws {
        let world = try TestStore.demoWorld()
        let receipts = try world.context.fetch(FetchDescriptor<Receipt>(
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.vendor)]))
        let receipt = try #require(receipts.first, "the demo world seeds no receipts")
        GLTestHost.render(ReceiptDetailScreen(receipt: receipt), container: world.container)
        GLTestHost.render(ReceiptFormScreen(defaultCustomer: world.primary, scanImage: nil),
                          container: world.container)
    }

    // MARK: - The person's form, the editors, and the document preview

    @Test func rendersPersonalFormAndEditorSheets() throws {
        let world = try TestStore.demoWorld()
        // The personal form is the GoldLifeID package's own (law 48a); the signature editor
        // saves into the Gold Life ID, shown here with and without a saved signature.
        let identity = MBIdentity.shared
        identity.standIn = .demo
        defer { identity.standIn = nil }
        GLTestHost.render(SignatureEditorSheet(), container: world.container)
        identity.standIn?.signatureData = UIImage(systemName: "signature")?.pngData()
        GLTestHost.render(SignatureEditorSheet(), container: world.container)

        let image = UIImage(systemName: "photo") ?? UIImage()
        // The fleet crop screen with My Business's two guides (ImageCropView was retired, F157).
        GLTestHost.render(GLSquarePhotoCropper(image: image, guide: .circle,
                                               outputSide: ImageDownsampler.croppedSide) {} onCropped: { _ in },
                          container: world.container)
        GLTestHost.render(GLSquarePhotoCropper(image: image, guide: .roundedRect, windowBackground: .white,
                                               outputSide: ImageDownsampler.croppedSide,
                                               keepsTransparency: true) {} onCropped: { _ in },
                          container: world.container)

        // A document preview over a temp file (covers the preview / error path).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gl-preview-test.pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        GLTestHost.render(DocumentPreviewSheet(url: url), container: world.container)
    }

    // MARK: - Projects and the work schedule

    @Test func rendersProjectsAndWorkSchedule() throws {
        let world = try TestStore.demoWorld()
        let job = ScheduledJob(customer: world.primary, agreedPrice: 1200)
        let second = ScheduledJob(title: "Backsplash", customer: world.primary, agreedPrice: 800)
        [job, second].forEach(world.context.insert)
        // The grouping sheet, the global list, and a project's roll-up over its jobs.
        GLTestHost.render(AddToProjectSheet(job: job), container: world.container)
        GLTestHost.render(AllProjectsScreen(), container: world.container)
        let project = Project(name: "Kitchen remodel", customer: world.primary)
        world.context.insert(project)
        project.jobs = [job, second]
        GLTestHost.render(ProjectDetailScreen(project: project), container: world.container)

        // The work-schedule editor: the standard week, then with vacations, custom days off and
        // per-date overrides populated (the rows a standard schedule never shows).
        GLTestHost.render(WorkScheduleScreen(), container: world.container)
        var schedule = WorkSchedule.standard
        schedule.vacations = [DateRangeRule(start: .now, end: .now.addingTimeInterval(3 * 86_400))]
        schedule.customDaysOff = [CustomDayOff(date: .now, repeatsYearly: true, label: "Inventory day")]
        schedule.overrides = [DateOverride(date: .now, kind: .blocked),
                              DateOverride(date: .now.addingTimeInterval(86_400),
                                           kind: .customHours(startMinutes: 540, endMinutes: 780))]
        world.profile.workSchedule = schedule
        GLTestHost.render(WorkScheduleScreen(), container: world.container)
    }
}
