//
//  ViewRenderingTests.swift
//  GLSmallBusinessTests
//
//  Coverage-focused render tests: each screen is hosted in a UIHostingController backed by an
//  in-memory store seeded with realistic demo data, then laid out so SwiftUI evaluates its `body`.
//  This exercises the view layer (which unit tests structurally can't reach) without the cost and
//  flakiness of a full XCUITest per screen. We assert only that rendering doesn't crash.
//

import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
struct ViewRenderingTests {

    // MARK: - Harness

    private final class Fixtures {
        let container: ModelContainer
        let customer: Customer
        let employee: Employee
        let sub: Subcontractor
        let invoice: Invoice
        let estimate: Estimate
        let receipt: Receipt
        let profile: BusinessProfile
        let userProfile: UserProfile

        init() throws {
            container = try TestStore.makeContainer()
            let ctx = container.mainContext
            DemoSeed.populate(ctx)
            customer = try #require(try ctx.fetch(FetchDescriptor<Customer>()).first)
            employee = try #require(try ctx.fetch(FetchDescriptor<Employee>()).first)
            sub = try #require(try ctx.fetch(FetchDescriptor<Subcontractor>()).first)
            invoice = try #require(try ctx.fetch(FetchDescriptor<Invoice>()).first)
            estimate = try #require(try ctx.fetch(FetchDescriptor<Estimate>()).first)
            receipt = try #require(try ctx.fetch(FetchDescriptor<Receipt>()).first)
            profile = try #require(try ctx.fetch(FetchDescriptor<BusinessProfile>()).first)
            let up = UserProfile()
            up.firstName = "Adrian"; up.lastName = "Gold"; up.email = "adrian@example.com"
            ctx.insert(up)
            userProfile = up
        }
    }

    /// Host a view and force a layout pass so its body (and onAppear) evaluate.
    private func render<V: View>(_ view: V, _ container: ModelContainer, size: CGSize = CGSize(width: 393, height: 852)) {
        let host = UIHostingController(
            rootView: NavigationStack { view }
                .modelContainer(container)
                .environment(SubscriptionManager.shared)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Browse + detail screens

    @Test func rendersBrowseAndDetailScreens() throws {
        let f = try Fixtures()
        render(CustomersScreen(), f.container)
        render(EmployeesScreen(), f.container)
        render(SubcontractorsScreen(), f.container)
        render(CalendarScreen(), f.container)
        render(MenuScreen(), f.container)
        render(StatsScreen(), f.container)
        render(ReceiptsTabScreen(), f.container)
        render(SettingsScreen(), f.container)
        render(MyCompanyDetailScreen(), f.container)
        render(MyPersonalInfoScreen(), f.container)

        render(CustomerDetailScreen(customer: f.customer), f.container)
        render(EmployeeDetailScreen(employee: f.employee), f.container)
        render(SubcontractorDetailScreen(subcontractor: f.sub), f.container)
        render(InvoiceDetailScreen(invoice: f.invoice), f.container)
        render(EstimateDetailScreen(estimate: f.estimate), f.container)
        render(ReceiptDetailScreen(receipt: f.receipt), f.container)
    }

    // MARK: - "More Info" detail screens + the global / per-customer lists

    @Test func rendersDetailsAndLists() throws {
        let f = try Fixtures()
        render(CustomerDetailsScreen(customer: f.customer), f.container)
        render(EmployeeDetailsScreen(employee: f.employee), f.container)
        render(SubcontractorDetailsScreen(subcontractor: f.sub), f.container)
        render(CompanyDetailsScreen(profile: f.profile), f.container)
        render(PersonalDetailsScreen(profile: f.userProfile), f.container)
        render(CustomerCOIDetailScreen(customer: f.customer), f.container)

        render(AllEstimatesScreen(), f.container)
        render(AllInvoicesScreen(), f.container)
        render(AllChangeOrdersScreen(), f.container)
        render(AllReceiptsScreen(), f.container)
        render(EstimatesListScreen(customer: f.customer), f.container)
        render(InvoicesListScreen(customer: f.customer), f.container)
        render(ReceiptsListScreen(customer: f.customer), f.container)
        render(ReceiptListView(receipts: f.customer.receipts ?? [], defaultCustomer: f.customer), f.container)
    }

    // MARK: - Forms (new + edit branches)

    @Test func rendersForms() throws {
        let f = try Fixtures()
        render(CustomerFormScreen(), f.container)
        render(CustomerFormScreen(editing: f.customer), f.container)
        render(EmployeeFormScreen(), f.container)
        render(EmployeeFormScreen(editing: f.employee), f.container)
        render(SubcontractorFormScreen(), f.container)
        render(SubcontractorFormScreen(editing: f.sub), f.container)
        render(EstimateFormScreen(customer: f.customer), f.container)
        render(EstimateFormScreen(editing: f.estimate), f.container)
        render(InvoiceFormScreen(customer: f.customer), f.container)
        render(InvoiceFormScreen(editing: f.invoice), f.container)
        render(ReceiptFormScreen(defaultCustomer: f.customer, scanImage: nil), f.container)
        render(ChangeOrderFormScreen(invoice: f.invoice), f.container)
        render(MyCompanyFormScreen(profile: f.profile), f.container)
        render(MyPersonalInfoFormScreen(profile: f.userProfile), f.container)
    }

    // MARK: - iPad layout, empty states, and data-variant branches

    @Test func rendersIPadAndEmptyAndVariantStates() throws {
        let f = try Fixtures()

        // The iPad three-column split (and its private list columns) renders only at regular width.
        render(IPadRootSplitView(), f.container, size: CGSize(width: 1024, height: 1366))

        // A salaried employee exercises the salary branch (the first employee is hourly).
        let ctx = f.container.mainContext
        if let salaried = try ctx.fetch(FetchDescriptor<Employee>()).first(where: { $0.payType == .salary }) {
            render(EmployeeDetailScreen(employee: salaried), f.container)
        }

        // Empty store → every "no data yet" branch on the browse / list screens.
        let empty = try TestStore.makeContainer()
        render(CustomersScreen(), empty)
        render(EmployeesScreen(), empty)
        render(SubcontractorsScreen(), empty)
        render(CalendarScreen(), empty)
        render(MenuScreen(), empty)
        render(StatsScreen(), empty)
        render(AllEstimatesScreen(), empty)
        render(AllInvoicesScreen(), empty)
        render(AllChangeOrdersScreen(), empty)
        render(AllReceiptsScreen(), empty)
    }

    // MARK: - The record/payment sheets (presented from the hubs)

    @Test func rendersSheets() throws {
        let f = try Fixtures()
        let timeEntry = f.employee.timeEntries?.first
        let paycheck = f.employee.paychecks?.first
        let subPayment = f.sub.payments?.first
        let invoicePayment = f.invoice.payments?.first

        render(LogHoursSheet(employee: f.employee, existing: nil), f.container)
        render(LogHoursSheet(employee: f.employee, existing: timeEntry), f.container)
        render(RecordPaycheckSheet(employee: f.employee, existing: nil), f.container)
        render(RecordPaycheckSheet(employee: f.employee, existing: paycheck), f.container)
        render(AllHoursSheet(employee: f.employee), f.container)
        render(AllPaychecksSheet(employee: f.employee), f.container)

        render(RecordSubPaymentSheet(subcontractor: f.sub, existing: nil), f.container)
        render(RecordSubPaymentSheet(subcontractor: f.sub, existing: subPayment), f.container)
        render(AllActivitySheet(subcontractor: f.sub), f.container)

        render(RecordPaymentSheet(invoice: f.invoice), f.container)
        render(SetAmountDueSheet(invoice: f.invoice), f.container)
        if let invoicePayment {
            render(PaymentReceiptSheet(invoice: f.invoice, payment: invoicePayment), f.container)
        }
    }

    // MARK: - Document-generation sheets (W-9, 1099, package, insurance, tax report)

    @Test func rendersDocumentSheets() throws {
        let f = try Fixtures()
        render(W9DocumentSheet(profile: f.profile), f.container)
        render(YearEndTaxReportSheet(), f.container)
        render(ComplianceDocsManagerSheet(profile: f.profile), f.container)
        render(ContractorPackageSheet(customer: f.customer, profile: f.profile), f.container)
        render(Form1099NECSheet(subcontractor: f.sub), f.container)
    }

    // MARK: - Editor / utility sheets

    @Test func rendersEditorSheets() throws {
        let f = try Fixtures()
        render(SignatureEditorSheet(profile: f.userProfile), f.container)
        render(AddressSearchSheet { _ in }, f.container)

        let image = UIImage(systemName: "photo") ?? UIImage()
        render(ImageCropView(image: image, guide: .circle) {} onCrop: { _ in }, f.container)
        render(ImageCropView(image: image, guide: .roundedRect) {} onCrop: { _ in }, f.container)

        // A change order on the invoice → its detail sheet.
        let co = ChangeOrder(number: "CO-0001", title: "Add second coat", taxRatePercent: 7.5)
        co.invoice = f.invoice
        f.container.mainContext.insert(co)
        render(ChangeOrderDetailSheet(changeOrder: co), f.container)

        // A document preview over a temp file (covers the preview / error path).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gl-preview-test.pdf")
        try? Data("%PDF-1.4".utf8).write(to: url)
        render(DocumentPreviewSheet(url: url), f.container)
    }

    // MARK: - Final variant branches

    @Test func rendersFinalVariants() throws {
        let f = try Fixtures()
        let ctx = f.container.mainContext

        // The scheduling "View gaps" sheet + the schedule-a-job sheet from each source.
        let jobs = try ctx.fetch(FetchDescriptor<ScheduledJob>())
        render(GapsList(jobs: jobs, schedule: .standard), f.container)
        render(ScheduleJobSheet(source: .invoice(f.invoice)), f.container)
        render(ScheduleJobSheet(source: .estimate(f.estimate)), f.container)
        render(WorkScheduleScreen(), f.container)
        // Job detail (incl. the billing card) + creating an invoice that bills a job.
        let billingJob = ScheduledJob(customer: f.customer, agreedPrice: 1200)
        render(JobDetailScreen(job: billingJob), f.container)
        render(InvoiceFormScreen(customer: f.customer, job: billingJob), f.container)
        for job in jobs { render(JobDetailScreen(job: job), f.container) }
        // Projects: the grouping sheet, the detail roll-up, and the global list.
        render(AddToProjectSheet(job: billingJob), f.container)
        render(AllProjectsScreen(), f.container)

        // The Calendar itself (phone + iPad-column layouts) — banner, grid, agenda over the demo data.
        render(CalendarScreen(), f.container)
        render(CalendarScreen(showsMenuButton: false), f.container)

        // Job lists.
        render(JobsListScreen(customer: f.customer), f.container)
        render(AllJobsScreen(), f.container)

        // Every JobFormScreen entry point + the all-day / timed / recurrence branches of its body.
        render(JobFormScreen(customer: f.customer), f.container)                       // fixed customer, all-day
        render(JobFormScreen(), f.container)                                           // from-scratch + customer picker
        render(JobFormScreen(prefillStart: .now, prefillDays: 3), f.container)         // all-day prefill
        render(JobFormScreen(prefillStart: .now,
                             prefillWindow: DateInterval(start: .now, duration: 3600)), f.container)   // timed prefill
        let timedRecurring = ScheduledJob(customer: f.customer)
        timedRecurring.isAllDay = false
        timedRecurring.startTime = .now
        timedRecurring.durationMinutes = 90
        timedRecurring.recurrenceFrequencyRaw = RecurrenceFrequency.weekly.rawValue
        timedRecurring.recurrenceWeekdayMask = (1 << 1) | (1 << 3)
        timedRecurring.recurrenceEndDate = Date.now.addingTimeInterval(60 * 86_400)
        render(JobFormScreen(editing: timedRecurring), f.container)                    // timed + recurrence + weekday chips

        // A project with jobs, and the work-schedule editor with its custom-day / override rows populated.
        let populatedProject = Project(name: "Kitchen remodel", customer: f.customer)
        populatedProject.jobs = [billingJob, timedRecurring]
        render(ProjectDetailScreen(project: populatedProject), f.container)
        var schedule = WorkSchedule.standard
        schedule.vacations = [DateRangeRule(start: .now, end: .now.addingTimeInterval(3 * 86_400))]
        schedule.customDaysOff = [CustomDayOff(date: .now, repeatsYearly: true, label: "Inventory day")]
        schedule.overrides = [DateOverride(date: .now, kind: .blocked),
                              DateOverride(date: .now.addingTimeInterval(86_400),
                                           kind: .customHours(startMinutes: 540, endMinutes: 780))]
        f.profile.workSchedule = schedule
        render(WorkScheduleScreen(), f.container)

        // Render every subcontractor + customer (1099-due vs not, COI present vs not — the
        // conditional branches in those hubs that a single instance doesn't reach).
        for sub in try ctx.fetch(FetchDescriptor<Subcontractor>()) {
            render(SubcontractorDetailScreen(subcontractor: sub), f.container)
        }
        for customer in try ctx.fetch(FetchDescriptor<Customer>()) {
            render(CustomerDetailScreen(customer: customer), f.container)
        }
    }
}
