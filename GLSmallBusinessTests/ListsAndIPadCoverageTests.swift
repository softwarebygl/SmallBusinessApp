//
//  ListsAndIPadCoverageTests.swift
//  GLSmallBusinessTests
//
//  State-variant render coverage for the browse/list surfaces and the iPad three-column shell.
//
//  ViewRenderingTests renders each of these screens ONCE, over the demo seed, at phone width, in
//  one color scheme. That leaves the branches that actually differ untouched: the "no records yet"
//  ContentUnavailableViews, the regular-width split (which is a completely different `body` on
//  CustomersScreen), the orphan-record banners (singular vs plural), the ReceiptListView parameter
//  matrix (filters on/off, assignee column, sidebar selection binding, solid background), the
//  balance-due row on a partially-paid invoice, the "Untitled …" fallbacks, the signed +/- change
//  order total, the "No invoice" / "No customer" warning labels, light mode, and accessibility
//  text sizes.
//
//  Hosting goes through GLTestHost (Harness/GLTestHost.swift), using the two extras this area
//  needs: an explicit `horizontalSizeClass` (what the regular-width branches actually key on)
//  and a `probe` that hands back the live hosting controller for the small UIKit pokes below
//  (select a sidebar row, type into the receipts search field) — the only way into private
//  `@State` from a test. Stores come from TestStore, the seeded dataset from DemoWorld.
//
//  Assertions are "renders without trapping" where the view has no return value, and real value
//  checks on the pure logic those rows call. The search predicates behind these lists are pure
//  and live in RecordSearchTests.
//

import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

/// `.serialized` is load-bearing, not tidiness. Forcing a layout pass means pumping the RunLoop,
/// and a nested RunLoop lets OTHER main-actor tests in this suite start running inside this one.
/// When one of them seeds a fresh store, SwiftData posts its save notification while a half-torn-down
/// `@Query` view from the interleaved test is still observing — and SwiftData traps, taking the whole
/// test PROCESS down (every test in the target reports as failed). Running this suite's tests one at
/// a time keeps that window shut.
@Suite(.serialized)
@MainActor
struct ListsAndIPadCoverageTests {

    private static let schemes: [UIUserInterfaceStyle] = [.dark, .light]

    /// Runs `body` for both color schemes — every list screen ships in light and dark.
    private func inBothSchemes(_ body: (UIUserInterfaceStyle) -> Void) {
        for scheme in Self.schemes { body(scheme) }
    }

    // MARK: - Fixtures the demo world does not carry

    /// The seeded receipts, newest first — the order the receipt lists display them in.
    private func sortedReceipts(in world: DemoWorld) throws -> [Receipt] {
        try world.context.fetch(FetchDescriptor<Receipt>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
    }

    /// A customer with nothing attached — the "no estimates / invoices / receipts yet" branches.
    private func barrenCustomer(in ctx: ModelContext) -> Customer {
        let c = Customer(firstName: "Nora", lastName: "Zabriskie", email: "nora@example.com",
                         phoneNumber: "(850) 555-0100")
        ctx.insert(c)
        ctx.saveChanges()
        return c
    }

    // MARK: - UIKit probes (the only way into private @State from a test)

    private func firstCollectionView(in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView { return cv }
        for sub in view.subviews {
            if let found = firstCollectionView(in: sub) { return found }
        }
        return nil
    }

    private func textFields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        if let tf = view as? UITextField { found.append(tf) }
        for sub in view.subviews { found.append(contentsOf: textFields(in: sub)) }
        return found
    }

    /// Selects row `index` of the first list in the hierarchy, driving whatever `@State` selection
    /// that list is bound to. No-ops (rather than failing) when the row isn't there — the point is
    /// extra branch coverage, not a UI contract.
    private func selectRow(_ index: Int, in vc: UIViewController) {
        guard let cv = firstCollectionView(in: vc.view),
              cv.numberOfSections > 0,
              cv.numberOfItems(inSection: 0) > index else { return }
        let path = IndexPath(item: index, section: 0)
        cv.selectItem(at: path, animated: false, scrollPosition: [])
        cv.delegate?.collectionView?(cv, didSelectItemAt: path)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
    }

    /// Types into the first raw TextField (the receipts sticky-header search), pushing the value
    /// through SwiftUI's binding the same way a keystroke does.
    private func type(_ text: String, into vc: UIViewController) {
        guard let field = textFields(in: vc.view).first else { return }
        field.text = text
        field.sendActions(for: .editingChanged)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
    }

    /// Types into one specific field (when a screen has several, e.g. the iPad split's columns).
    private func type(_ text: String, into field: UITextField, in vc: UIViewController) {
        field.text = text
        field.sendActions(for: .editingChanged)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    /// The list (collection view) a view sits in.
    private func enclosingCollectionView(of view: UIView) -> UICollectionView? {
        var current = view.superview
        while let v = current {
            if let cv = v as? UICollectionView { return cv }
            current = v.superview
        }
        return nil
    }

    /// Every row the list holds, across its sections.
    private func itemCount(_ list: UICollectionView) -> Int {
        (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    }

    // MARK: - CustomersScreen — empty vs populated, compact vs regular, both schemes

    @Test func customersScreenEmptyStateRendersInBothSchemes() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(CustomersScreen(), container: empty)
    }

    @Test func customersScreenPopulatedRendersInBothSchemes() throws {
        let w = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(CustomersScreen(), container: w.container)
    }

    /// The regular-width branch is a whole different `body` (NavigationSplitView + `selectFirstOnIPad`,
    /// the searchable sidebar, and the iPad toolbar) that phone-width rendering never touches.
    @Test func customersScreenAtRegularWidthRendersSplitAndSelectsFirst() throws {
        let w = try TestStore.demoWorld()
        inBothSchemes {
            GLTestHost.render(CustomersScreen(), container: w.container, scheme: $0,
                              size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false)
        }
    }

    /// Regular width with an empty store: the sidebar shows the empty state and the detail column
    /// stays on "Select a Customer" (no first row for `selectFirstOnIPad` to pick).
    @Test func customersScreenAtRegularWidthWithNoCustomers() throws {
        let empty = try TestStore.makeContainer()
        inBothSchemes {
            GLTestHost.render(CustomersScreen(), container: empty, scheme: $0,
                              size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false)
        }
    }

    /// Accessibility text sizes reflow every row card — exercise the largest one on both states.
    @Test func customersScreenAtAccessibilityTextSize() throws {
        let w = try TestStore.demoWorld()
        let empty = try TestStore.makeContainer()
        GLTestHost.render(CustomersScreen(), container: w.container, typeSize: .accessibility3)
        GLTestHost.render(CustomersScreen(), container: empty, typeSize: .accessibility5)
        GLTestHost.render(CustomersScreen(), container: w.container, typeSize: .accessibility3,
                          size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false)
    }

    /// The customer row's owed/paid subrow: red when they still owe, secondary when square.
    @Test func customerFinancialsSubrowOwedVersusSettled() throws {
        let w = try TestStore.demoWorld()
        for customer in w.customers {
            inBothSchemes {
                GLTestHost.render(CustomerFinancialsSubrow(customer: customer), container: w.container,
                                  scheme: $0, inNavigationStack: false)
            }
        }
        // A customer with no invoices at all — both values are exactly zero (the `else` tint).
        let barren = barrenCustomer(in: w.context)
        #expect(barren.outstanding == 0)
        #expect(barren.totalPaidToUs == 0)
        GLTestHost.render(CustomerFinancialsSubrow(customer: barren), container: w.container,
                          inNavigationStack: false)
    }

    // MARK: - IPadRootSplitView — the three-column shell

    @Test func iPadRootSplitViewRendersAtRegularWidthInBothSchemes() throws {
        let w = try TestStore.demoWorld()
        inBothSchemes {
            GLTestHost.render(IPadRootSplitView(), container: w.container, scheme: $0,
                              size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false,
                              settle: 0.05)
        }
    }

    /// Empty store → the customers column's "No Customers" ContentUnavailableView plus the detail
    /// column's BrandPlaceholder, neither of which the seeded render reaches.
    @Test func iPadRootSplitViewWithEmptyStoreShowsPlaceholders() throws {
        let empty = try TestStore.makeContainer()
        inBothSchemes {
            GLTestHost.render(IPadRootSplitView(), container: empty, scheme: $0,
                              size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false,
                              settle: 0.05)
        }
    }

    /// Walk the sidebar: each section swaps the content column (customers → employees →
    /// subcontractors → calendar) and the detail column's placeholder with it. Section state is
    /// private `@State`, so the only way in is selecting the row through the backing list.
    @Test func iPadRootSplitViewSectionSwitchingDrivesEveryColumn() throws {
        let w = try TestStore.demoWorld()
        GLTestHost.render(IPadRootSplitView(), container: w.container,
                          size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false,
                          settle: 0.05) { vc in
            for index in 0..<4 { selectRow(index, in: vc) }
        }
        // Same walk over an empty store → the employees / subcontractors empty states.
        let empty = try TestStore.makeContainer()
        GLTestHost.render(IPadRootSplitView(), container: empty,
                          size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false,
                          settle: 0.05) { vc in
            for index in 0..<4 { selectRow(index, in: vc) }
        }
    }

    /// Compact width: the split collapses to a single stack. iPad multitasking narrows into this,
    /// and the app deliberately keeps the split shell rather than swapping to the tab bar.
    @Test func iPadRootSplitViewCollapsesAtCompactWidth() throws {
        let w = try TestStore.demoWorld()
        GLTestHost.render(IPadRootSplitView(), container: w.container,
                          size: GLTestHost.phone, sizeClass: .compact, inNavigationStack: false)
    }

    /// F52 (QA 2026-10-03): every iPad Contacts column (Customers, Employees, Subcontractors)
    /// carries the iPhone list's in-list search row under the Contacts picker, and typing in it
    /// filters that column's rows the way the iPhone list does. Before the fix the columns drew
    /// the picker and the rows only: no search field at all.
    @Test func iPadContactsColumnsSearchAndFilterTheirRows() throws {
        let w = try TestStore.demoWorld()
        let cases: [(kind: String, prompt: String, query: String, total: Int, found: Int)] = [
            ("customers", "Search customers", "car",
             w.customers.count, w.customers.filter { $0.matchesSearch("car") }.count),
            ("employees", "Search employees", "ca",
             w.employees.count, w.employees.filter { $0.matchesSearch("ca") }.count),
            ("subcontractors", "Search subcontractors", "boyd",
             w.subcontractors.count, w.subcontractors.filter { $0.matchesSearch("boyd") }.count),
        ]
        for c in cases {
            // The query must narrow the seeded list, or the row count below proves nothing.
            #expect(c.found > 0 && c.found < c.total, "\(c.kind): '\(c.query)' should match some rows, not all.")
            var fieldFound = false
            var rowsBefore = -1
            var rowsAfter = -1
            GLTestHost.render(IPadRootSplitView().environment(AppRouter(demoScreen: c.kind)),
                              container: w.container, size: GLTestHost.pad, sizeClass: .regular,
                              inNavigationStack: false, settle: 0.05) { vc in
                guard let field = textFields(in: vc.view).first(where: { $0.placeholder == c.prompt }),
                      let list = enclosingCollectionView(of: field) else { return }
                fieldFound = true
                rowsBefore = itemCount(list)
                type(c.query, into: field, in: vc)
                rowsAfter = itemCount(list)
                type("", into: field, in: vc)
            }
            #expect(fieldFound, "The iPad \(c.kind) column should show '\(c.prompt)' under the Contacts picker.")
            #expect(rowsBefore - rowsAfter == c.total - c.found,
                    "Typing '\(c.query)' should leave \(c.found) of \(c.total) \(c.kind) (rows \(rowsBefore) -> \(rowsAfter)).")
        }
    }

    /// The one people filter every Contacts list uses (iPhone, pushed, iPad): a blank field keeps
    /// everyone in list order, a query keeps the matches in list order, and each kind gets its
    /// own prompt.
    @Test func contactSearchFilterAndPromptsAreShared() throws {
        let w = try TestStore.demoWorld()
        #expect(ContactSearch.visible(w.customers, query: "") == w.customers)
        #expect(ContactSearch.visible(w.customers, query: "car").map(\.lastName) == ["Carter"])
        #expect(ContactSearch.visible(w.employees, query: "zzz-nobody").isEmpty)
        #expect(ContactSearch.visible(w.subcontractors, query: "boyd")
                == w.subcontractors.filter { $0.matchesSearch("boyd") })
        #expect(ContactSearch.prompt(for: .customers) == "Search customers")
        #expect(ContactSearch.prompt(for: .employees) == "Search employees")
        #expect(ContactSearch.prompt(for: .subcontractors) == "Search subcontractors")
    }

    // MARK: - Per-customer lists — EstimatesListScreen

    @Test func estimatesListScreenEmptyAndPopulated() throws {
        let w = try TestStore.demoWorld()
        let barren = barrenCustomer(in: w.context)
        #expect((barren.estimates ?? []).isEmpty)
        GLTestHost.renderBothSchemes(EstimatesListScreen(customer: barren), container: w.container)

        // Every seeded customer — some have estimates, some don't.
        for customer in w.customers {
            GLTestHost.renderBothSchemes(EstimatesListScreen(customer: customer), container: w.container)
        }
    }

    /// An estimate with no job title falls back to "Untitled estimate"; the status badge covers
    /// every EstimateStatus case.
    @Test func estimatesListScreenTitleFallbackAndEveryStatus() throws {
        let w = try TestStore.demoWorld()
        let customer = barrenCustomer(in: w.context)
        for (i, status) in EstimateStatus.allCases.enumerated() {
            let est = Estimate(number: "EST-90\(i)", jobTitle: i == 0 ? "" : "Job \(i)",
                               createdAt: .now.addingTimeInterval(Double(-i) * 3600),
                               status: status, customer: customer)
            w.context.insert(est)
        }
        w.context.saveChanges()
        #expect((customer.estimates ?? []).count == EstimateStatus.allCases.count)
        GLTestHost.renderBothSchemes(EstimatesListScreen(customer: customer), container: w.container)
        GLTestHost.render(EstimatesListScreen(customer: customer), container: w.container,
                          typeSize: .accessibility3)
    }

    // MARK: - Per-customer lists — InvoicesListScreen

    @Test func invoicesListScreenEmptyAndPopulated() throws {
        let w = try TestStore.demoWorld()
        let barren = barrenCustomer(in: w.context)
        #expect((barren.invoices ?? []).isEmpty)
        GLTestHost.renderBothSchemes(InvoicesListScreen(customer: barren), container: w.container)
        for customer in w.customers {
            GLTestHost.renderBothSchemes(InvoicesListScreen(customer: customer), container: w.container)
        }
    }

    /// The row's "Balance …" line only renders when `amountPaid > 0 && !isPaid` — so this needs a
    /// partially-paid invoice next to an unpaid one, a fully-paid one, and an untitled one.
    @Test func invoicesListScreenBalanceRowAndTitleFallback() throws {
        let w = try TestStore.demoWorld()
        let customer = barrenCustomer(in: w.context)

        let untitled = TS.invoice(number: "INV-9000", lines: [], in: w.context)
        untitled.jobTitle = ""
        let unpaid = TS.invoice(number: "INV-9001", status: .sent, lines: [], in: w.context)
        unpaid.jobTitle = "Unpaid work"
        let partial = TS.invoice(number: "INV-9002", status: .sent, lines: [(1000, false)], in: w.context)
        partial.jobTitle = "Half paid"
        let settled = TS.invoice(number: "INV-9003", status: .sent, lines: [(500, false)], in: w.context)
        settled.jobTitle = "Paid in full"
        for inv in [untitled, unpaid, partial, settled] { inv.customer = customer }
        TS.pay(partial, 400, in: w.context)
        TS.pay(settled, 500, method: .card, in: w.context)
        w.context.saveChanges()

        #expect(partial.amountPaid == 400)
        #expect(!partial.isPaid)            // the balance row's condition
        #expect(settled.isPaid)             // suppresses the balance row
        #expect(unpaid.amountPaid == 0)

        GLTestHost.renderBothSchemes(InvoicesListScreen(customer: customer), container: w.container)
        GLTestHost.render(InvoicesListScreen(customer: customer), container: w.container,
                          typeSize: .accessibility3)
    }

    // MARK: - Per-customer lists — ReceiptsListScreen / ReceiptListView

    @Test func receiptsListScreenEmptyAndPopulated() throws {
        let w = try TestStore.demoWorld()
        let barren = barrenCustomer(in: w.context)
        #expect((barren.receipts ?? []).isEmpty)
        GLTestHost.renderBothSchemes(ReceiptsListScreen(customer: barren), container: w.container)
        for customer in w.customers {
            GLTestHost.renderBothSchemes(ReceiptsListScreen(customer: customer), container: w.container)
        }
        GLTestHost.render(ReceiptsListScreen(customer: w.primary), container: w.container,
                          typeSize: .accessibility3)
    }

    /// ReceiptListView is the one view in this area with a real parameter matrix — every flag flips
    /// a branch (sticky header on/off, assignee vs category subline, chevron vs selection stroke,
    /// monogram vs solid background, menu button). Cover the combinations, empty and populated.
    @Test func receiptListViewParameterMatrix() throws {
        let w = try TestStore.demoWorld()
        let receipts = try sortedReceipts(in: w)
        #expect(!receipts.isEmpty)
        let selected: Binding<PersistentIdentifier?> = .constant(receipts[0].persistentModelID)
        let unselected: Binding<PersistentIdentifier?> = .constant(nil)

        // Scoped list (no filters, no header) — the per-customer / per-job shape.
        GLTestHost.render(ReceiptListView(receipts: receipts, defaultCustomer: w.primary), container: w.container)
        // Universal list with filters + assignee column + menu button — the Receipts tab shape.
        GLTestHost.render(ReceiptListView(receipts: receipts, defaultCustomer: nil,
                                          showsAssignee: true, enablesFilters: true,
                                          title: "Receipts", showsMenuButton: true), container: w.container)
        // iPad sidebar shape: selection binding (row highlight instead of a push) + solid background.
        GLTestHost.render(ReceiptListView(receipts: receipts, defaultCustomer: nil,
                                          showsAssignee: true, enablesFilters: true,
                                          title: "All Receipts", selectionID: selected,
                                          showsMenuButton: false, solidBackground: true), container: w.container)
        GLTestHost.render(ReceiptListView(receipts: receipts, defaultCustomer: nil,
                                          enablesFilters: false, selectionID: unselected,
                                          solidBackground: true), container: w.container)
        // Empty, in both shapes — the two different "No Receipts" descriptions.
        GLTestHost.render(ReceiptListView(receipts: [], defaultCustomer: nil), container: w.container)
        GLTestHost.render(ReceiptListView(receipts: [], defaultCustomer: nil, enablesFilters: true),
                          container: w.container)
        // A job-scoped list (new scans attach to the job).
        let job = ScheduledJob(title: "Backsplash", customerName: w.primary.listDisplayName,
                               customer: w.primary, agreedPrice: 900)
        w.context.insert(job)
        w.context.saveChanges()
        GLTestHost.render(ReceiptListView(receipts: receipts, defaultCustomer: w.primary, defaultJob: job),
                          container: w.container)
    }

    /// Row variants: a receipt with a real scan (thumbnail decode path), one with none (placeholder),
    /// a business receipt (no customer → "Business"), a blank vendor (→ "Receipt"), and no category.
    @Test func receiptListViewRowVariants() throws {
        let w = try TestStore.demoWorld()
        let png = Self.solidPNG()
        let scanned = Receipt(vendor: "Coastal Supply", date: .now, total: 1234.56,
                              category: "Materials", notes: "LVP", scanData: png, customer: w.primary)
        let business = Receipt(vendor: "QuickStop Fuel", date: .now, total: 62.15,
                               category: "Fuel", customer: nil)
        let blankVendor = Receipt(vendor: "   ", date: .now, total: 0, category: "")
        let negative = Receipt(vendor: "Returned tile", date: .now, total: -250, category: "Materials")
        for r in [scanned, business, blankVendor, negative] { w.context.insert(r) }
        w.context.saveChanges()

        #expect(blankVendor.displayVendor == "Receipt")
        let rows = [scanned, business, blankVendor, negative]
        inBothSchemes {
            GLTestHost.render(ReceiptListView(receipts: rows, defaultCustomer: nil,
                                              showsAssignee: true, enablesFilters: true),
                              container: w.container, scheme: $0)
            GLTestHost.render(ReceiptListView(receipts: rows, defaultCustomer: w.primary,
                                              showsAssignee: false),
                              container: w.container, scheme: $0)
        }
        GLTestHost.render(ReceiptListView(receipts: rows, defaultCustomer: nil, enablesFilters: true),
                          container: w.container, typeSize: .accessibility3)
    }

    /// Drive the sticky-header search field for real: a matching query narrows the list and the
    /// running total, a non-matching one hits the "No receipts match your search or filter." copy.
    @Test func receiptListViewSearchNarrowsAndEmptiesTheList() throws {
        let w = try TestStore.demoWorld()
        let receipts = try sortedReceipts(in: w)
        GLTestHost.render(ReceiptListView(receipts: receipts, defaultCustomer: nil,
                                          showsAssignee: true, enablesFilters: true),
                          container: w.container) { vc in
            type("henderson", into: vc)                // matches a seeded vendor
            type("zzzz-no-such-receipt", into: vc)     // matches nothing → the filtered empty state
            type("", into: vc)                         // clears back to the full list
        }
    }

    // MARK: - Records section — AllInvoicesScreen

    @Test func allInvoicesScreenEmptyAndPopulated() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(AllInvoicesScreen(), container: empty)
        let w = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(AllInvoicesScreen(), container: w.container)
        GLTestHost.render(AllInvoicesScreen(), container: w.container, typeSize: .accessibility3)
    }

    /// The orphan banner has singular and plural copy and the row swaps the customer name for an
    /// orange "No customer" label — none of which the demo seed (zero orphans) reaches.
    @Test func allInvoicesScreenOrphanBannerSingularThenPlural() throws {
        let w = try TestStore.demoWorld()
        let orphan = Invoice(number: "INV-8001", jobTitle: "Stray from a sync hiccup",
                             createdAt: .now, status: .sent, customer: nil)
        w.context.insert(orphan)
        w.context.saveChanges()
        #expect(orphan.customer == nil)
        GLTestHost.renderBothSchemes(AllInvoicesScreen(), container: w.container)   // singular copy

        let second = Invoice(number: "INV-8002", jobTitle: "", createdAt: .now,
                             status: .draft, customer: nil)                          // also "Untitled invoice"
        w.context.insert(second)
        w.context.saveChanges()
        GLTestHost.renderBothSchemes(AllInvoicesScreen(), container: w.container)   // plural copy
        GLTestHost.render(AllInvoicesScreen(), container: w.container, typeSize: .accessibility3)
    }

    // MARK: - Records section — AllEstimatesScreen

    @Test func allEstimatesScreenEmptyAndPopulated() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(AllEstimatesScreen(), container: empty)
        let w = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(AllEstimatesScreen(), container: w.container)
        GLTestHost.render(AllEstimatesScreen(), container: w.container, typeSize: .accessibility3)
    }

    @Test func allEstimatesScreenOrphanBannerSingularThenPlural() throws {
        let w = try TestStore.demoWorld()
        let orphan = Estimate(number: "EST-8001", jobTitle: "Stray estimate",
                              createdAt: .now, status: .sent, customer: nil)
        w.context.insert(orphan)
        w.context.saveChanges()
        GLTestHost.renderBothSchemes(AllEstimatesScreen(), container: w.container)   // singular copy

        let second = Estimate(number: "EST-8002", jobTitle: "", createdAt: .now,
                              status: .declined, customer: nil)                       // "Untitled estimate"
        w.context.insert(second)
        w.context.saveChanges()
        GLTestHost.renderBothSchemes(AllEstimatesScreen(), container: w.container)   // plural copy
    }

    // MARK: - Records section — AllChangeOrdersScreen

    /// The demo seed has NO change orders, so the shipped render test only ever saw the empty state.
    @Test func allChangeOrdersScreenEmptyState() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(AllChangeOrdersScreen(), container: empty)
        let seededNoCOs = try TestStore.demoWorld()
        #expect(try seededNoCOs.context.fetch(FetchDescriptor<ChangeOrder>()).isEmpty)
        GLTestHost.renderBothSchemes(AllChangeOrdersScreen(), container: seededNoCOs.container)
    }

    /// Populated: a positive pending order, an APPLIED one ("· added"), a NEGATIVE one (the row's
    /// sign prefix flips), an untitled one (falls back to its number), and one with no invoice
    /// (the orange "No invoice" label).
    @Test func allChangeOrdersScreenRowVariants() throws {
        let w = try TestStore.demoWorld()
        let ctx = w.context
        let invoice = try w.invoice("INV-0001")

        let pending = TS.changeOrder(invoice, number: "CO-0001", lines: [(250, false)], in: ctx)
        pending.title = "Add second coat"
        let applied = TS.changeOrder(invoice, number: "CO-0002", status: .approved, applied: true,
                                     lines: [(180, false)], in: ctx)
        applied.title = "Extra outlet"
        let credit = TS.changeOrder(invoice, number: "CO-0003", status: .approved,
                                    lines: [(-400, false)], in: ctx)
        credit.title = "Removed shelving"
        let untitled = TS.changeOrder(invoice, number: "CO-0004", status: .declined,
                                      lines: [(75, false)], in: ctx)
        untitled.title = ""
        // No parent invoice — the builder always attaches one, so this one is wired by hand.
        let orphan = ChangeOrder(number: "CO-0005", title: "Lost its invoice", taxRatePercent: 0)
        let orphanLine = ChangeOrderLineItem(name: "Line", quantity: 1, unit: .job,
                                             unitPrice: 60, isTaxable: false, sortIndex: 0)
        orphanLine.changeOrder = orphan
        orphan.lineItems = [orphanLine]
        ctx.insert(orphan)
        ctx.insert(orphanLine)
        ctx.saveChanges()

        #expect(pending.total > 0)
        #expect(credit.total < 0)                       // the "-" prefix branch
        #expect(applied.appliedToInvoice)               // the "· added" branch
        #expect(untitled.title.isEmpty)                 // falls back to the number
        #expect(orphan.invoice == nil)                  // the "No invoice" label
        #expect(try ctx.fetch(FetchDescriptor<ChangeOrder>()).count == 5)

        GLTestHost.renderBothSchemes(AllChangeOrdersScreen(), container: w.container)
        GLTestHost.render(AllChangeOrdersScreen(), container: w.container, typeSize: .accessibility3)
        GLTestHost.render(AllChangeOrdersScreen(), container: w.container,
                          size: GLTestHost.pad, sizeClass: .regular)
    }

    // MARK: - Records section — AllJobsScreen

    @Test func allJobsScreenEmptyAndPopulated() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(AllJobsScreen(), container: empty)
        let w = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(AllJobsScreen(), container: w.container)
        GLTestHost.render(AllJobsScreen(), container: w.container, typeSize: .accessibility3)
        // AllJobsScreen is also the iPad split's detail pane for the Calendar section.
        GLTestHost.render(AllJobsScreen(), container: w.container, size: GLTestHost.pad, sizeClass: .regular)
    }

    /// Row variants the seed doesn't produce: an untitled job (→ "Job"), a job with no customer
    /// name (the subtitle disappears), and every JobStatus.
    @Test func allJobsScreenRowVariants() throws {
        let w = try TestStore.demoWorld()
        let untitled = ScheduledJob(title: "   ", customerName: "", startDate: .now,
                                    durationDays: 1, status: .inProgress)
        let multiDay = ScheduledJob(title: "Whole-house LVP", customerName: w.primary.listDisplayName,
                                    startDate: .now, durationDays: 9,
                                    customer: w.primary, status: .scheduled)
        let done = ScheduledJob(title: "Punch list", customerName: w.primary.listDisplayName,
                                startDate: .now.addingTimeInterval(-20 * 86_400), durationDays: 1,
                                customer: w.primary, status: .completed)
        for job in [untitled, multiDay, done] { w.context.insert(job) }
        w.context.saveChanges()

        #expect(untitled.displayTitle == "Job")          // whitespace-only title falls back
        #expect(multiDay.durationDays == 9)
        GLTestHost.renderBothSchemes(AllJobsScreen(), container: w.container)
    }

    // MARK: - Records section — AllReceiptsScreen

    @Test func allReceiptsScreenEmptyAndPopulated() throws {
        let empty = try TestStore.makeContainer()
        GLTestHost.renderBothSchemes(AllReceiptsScreen(), container: empty)
        let w = try TestStore.demoWorld()
        GLTestHost.renderBothSchemes(AllReceiptsScreen(), container: w.container)
        GLTestHost.render(AllReceiptsScreen(), container: w.container, typeSize: .accessibility3)
        GLTestHost.render(AllReceiptsScreen(), container: w.container, size: GLTestHost.pad, sizeClass: .regular)
    }

    // MARK: - The row components these lists are built from

    @Test func personRowCardCoversEverySlot() throws {
        let w = try TestStore.demoWorld()
        let customer = w.primary
        inBothSchemes { scheme in
            GLTestHost.render(PersonRowCard(name: customer.listDisplayName, showsChevron: true) {
                ProfileAvatar(imageData: nil, initials: customer.initials)
            }, container: w.container, scheme: scheme, inNavigationStack: false)
            GLTestHost.render(PersonRowCard(name: customer.listDisplayName, subtitle: "Owes $1,200",
                                            subtitleColor: .red, showsChevron: false, isSelected: true) {
                ProfileAvatar(imageData: nil, initials: customer.initials)
            }, container: w.container, scheme: scheme, inNavigationStack: false)
            GLTestHost.render(PersonRowCard(name: customer.listDisplayName, trailing: "$2,400",
                                            trailingTint: .green, showsChevron: false, selectionMark: true) {
                ProfileAvatar(imageData: nil, initials: customer.initials)
            }, container: w.container, scheme: scheme, inNavigationStack: false)
            GLTestHost.render(PersonRowCard(name: customer.listDisplayName, selectionMark: false) {
                ProfileAvatar(imageData: nil, initials: customer.initials)
            }, container: w.container, scheme: scheme, inNavigationStack: false)
            GLTestHost.render(PersonRowCard(name: "A very long customer name that has to truncate somewhere",
                                            subtitleView: AnyView(CustomerFinancialsSubrow(customer: customer))) {
                ProfileAvatar(imageData: nil, initials: customer.initials)
            }, container: w.container, scheme: scheme, inNavigationStack: false)
        }
        GLTestHost.render(PersonRowCard(name: customer.listDisplayName, subtitle: "Paid up") {
            ProfileAvatar(imageData: nil, initials: customer.initials)
        }, container: w.container, typeSize: .accessibility4, inNavigationStack: false)
    }

    @Test func profileAvatarPhotoMonogramAndBadge() throws {
        let w = try TestStore.demoWorld()
        let png = Self.solidPNG()
        inBothSchemes { scheme in
            GLTestHost.render(ProfileAvatar(imageData: png, initials: "MR"), container: w.container,
                              scheme: scheme, inNavigationStack: false)
            GLTestHost.render(ProfileAvatar(imageData: nil, initials: "MR"), container: w.container,
                              scheme: scheme, inNavigationStack: false)
            GLTestHost.render(ProfileAvatar(imageData: nil, initials: "?", size: 96, showsCameraBadge: true),
                              container: w.container, scheme: scheme, inNavigationStack: false)
            // Malformed image data must fall back to the monogram, not crash.
            GLTestHost.render(ProfileAvatar(imageData: Data([0x00, 0x01, 0x02]), initials: "ZZ"),
                              container: w.container, scheme: scheme, inNavigationStack: false)
        }
    }

    @Test func scanThumbnailDecodesOrFallsBack() throws {
        let w = try TestStore.demoWorld()
        inBothSchemes { scheme in
            GLTestHost.render(ScanThumbnail(data: Self.solidPNG(), size: 44), container: w.container,
                              scheme: scheme, inNavigationStack: false)
            GLTestHost.render(ScanThumbnail(data: nil, size: 44), container: w.container,
                              scheme: scheme, inNavigationStack: false)
            // Garbage bytes: the async downsample returns nil and the placeholder stays.
            GLTestHost.render(ScanThumbnail(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), size: 60),
                              container: w.container, scheme: scheme, inNavigationStack: false)
            GLTestHost.render(ScanThumbnail(data: Data(), size: 44), container: w.container,
                              scheme: scheme, inNavigationStack: false)
        }
    }

    @Test func jobRowAndStatusBadgeCoverEveryStatus() throws {
        let w = try TestStore.demoWorld()
        let mask = SchedulingPrefs.defaultWorkdaysMask
        for status in JobStatus.allCases {
            let job = ScheduledJob(title: "Job \(status.rawValue)", customerName: w.primary.listDisplayName,
                                   startDate: .now, durationDays: 3, customer: w.primary, status: status)
            w.context.insert(job)
            inBothSchemes { scheme in
                GLTestHost.render(JobRow(job: job, mask: mask, showsCustomer: true), container: w.container,
                                  scheme: scheme, inNavigationStack: false)
                GLTestHost.render(JobRow(job: job, mask: mask, showsCustomer: false), container: w.container,
                                  scheme: scheme, inNavigationStack: false)
                GLTestHost.render(JobStatusBadge(status: status), container: w.container,
                                  scheme: scheme, inNavigationStack: false)
            }
        }
        // A timed (not all-day) job takes the "date · time" branch of the row's subtitle.
        let timed = ScheduledJob(title: "2-hour cleaning", customerName: w.primary.listDisplayName,
                                 startDate: .now, customer: w.primary)
        timed.isAllDay = false
        timed.startTime = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: .now)
        timed.durationMinutes = 120
        w.context.insert(timed)
        w.context.saveChanges()
        GLTestHost.render(JobRow(job: timed, mask: mask, showsCustomer: true), container: w.container,
                          inNavigationStack: false)
        // Single-day vs multi-day date range.
        let oneDay = ScheduledJob(title: "One day", customerName: "", startDate: .now, durationDays: 1)
        w.context.insert(oneDay)
        GLTestHost.render(JobRow(job: oneDay, mask: mask, showsCustomer: true), container: w.container,
                          inNavigationStack: false)
    }

    // MARK: - Name / avatar edge cases the people rows have to survive

    /// Rows whose data doesn't look like "First Last": a saved photo (the avatar's image branch),
    /// a business-only customer, a nameless one ("No name" / "?"), and a non-ASCII name.
    @Test func customersScreenRowsWithPhotosBusinessOnlyAndUnicodeNames() throws {
        let w = try TestStore.demoWorld()
        let withPhoto = Customer(firstName: "Marcus", lastName: "Reed")
        withPhoto.profileImageData = Self.solidPNG()
        let businessOnly = Customer(businessName: "Nguyen Property Management")
        let nameless = Customer()
        let unicode = Customer(firstName: "José", lastName: "Núñez",
                               businessName: "Núñez Obras y Azulejos")
        for c in [withPhoto, businessOnly, nameless, unicode] { w.context.insert(c) }
        w.context.saveChanges()

        #expect(businessOnly.listDisplayName == "Nguyen Property Management")
        #expect(nameless.listDisplayName == "No name")
        #expect(nameless.initials == "?")
        #expect(unicode.initials == "JN")

        GLTestHost.renderBothSchemes(CustomersScreen(), container: w.container)
        GLTestHost.render(CustomersScreen(), container: w.container,
                          size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false)
        for c in [withPhoto, businessOnly, nameless, unicode] {
            GLTestHost.render(PersonRowCard(name: c.listDisplayName, showsChevron: true) {
                ProfileAvatar(imageData: c.profileImageData, initials: c.initials)
            }, container: w.container, inNavigationStack: false)
        }
    }

    /// The iPad shell at an accessibility text size — the sidebar labels and the bottom Menu button
    /// reflow, which is where a fixed-height row would clip.
    @Test func iPadRootSplitViewAtAccessibilityTextSize() throws {
        let w = try TestStore.demoWorld()
        GLTestHost.render(IPadRootSplitView(), container: w.container, typeSize: .accessibility3,
                          size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false,
                          settle: 0.05)
        let empty = try TestStore.makeContainer()
        GLTestHost.render(IPadRootSplitView(), container: empty, typeSize: .accessibility5,
                          size: GLTestHost.pad, sizeClass: .regular, inNavigationStack: false,
                          settle: 0.05)
    }

    /// A store with many records — the lists' ForEach bodies at scale, not just the 1–4 rows the
    /// demo seed produces.
    @Test func recordListsRenderWithManyRows() throws {
        let w = try TestStore.demoWorld()
        let customer = barrenCustomer(in: w.context)
        for i in 0..<30 {
            let day = Date.now.addingTimeInterval(Double(-i) * 86_400)
            let inv = Invoice(number: String(format: "INV-5%03d", i), jobTitle: "Bulk job \(i)",
                              createdAt: day, status: i.isMultiple(of: 2) ? .sent : .draft,
                              customer: customer)
            let est = Estimate(number: String(format: "EST-5%03d", i), jobTitle: "Bulk quote \(i)",
                               createdAt: day, status: .sent, customer: customer)
            let receipt = Receipt(vendor: "Vendor \(i % 7)", date: day, total: Double(i) * 13.37,
                                  category: i.isMultiple(of: 3) ? "Materials" : "Fuel",
                                  customer: i.isMultiple(of: 5) ? nil : customer)
            let job = ScheduledJob(title: "Bulk install \(i)", customerName: customer.listDisplayName,
                                   startDate: day, durationDays: (i % 4) + 1, customer: customer)
            w.context.insert(inv)
            w.context.insert(est)
            w.context.insert(receipt)
            w.context.insert(job)
        }
        w.context.saveChanges()
        #expect((customer.invoices ?? []).count == 30)
        #expect((customer.estimates ?? []).count == 30)

        GLTestHost.render(AllInvoicesScreen(), container: w.container)
        GLTestHost.render(AllEstimatesScreen(), container: w.container)
        GLTestHost.render(AllReceiptsScreen(), container: w.container)
        GLTestHost.render(AllJobsScreen(), container: w.container)
        GLTestHost.render(InvoicesListScreen(customer: customer), container: w.container)
        GLTestHost.render(EstimatesListScreen(customer: customer), container: w.container)
        GLTestHost.render(ReceiptsListScreen(customer: customer), container: w.container)
        GLTestHost.render(CustomersScreen(), container: w.container)
    }

    // MARK: - The receipts filter enum (drives the tab's filter menu + active-filter chip)

    @Test func receiptFilterEqualityAndHashing() throws {
        let w = try TestStore.demoWorld()
        let a = w.customers[0].persistentModelID
        let b = w.customers[1].persistentModelID
        #expect(ReceiptFilter.all == .all)
        #expect(ReceiptFilter.business != .all)
        #expect(ReceiptFilter.customer(a) == .customer(a))
        #expect(ReceiptFilter.customer(a) != .customer(b))
        #expect(ReceiptFilter.store("Coastal Supply") == .store("Coastal Supply"))
        // Store filters are compared by exact string here (the row match itself is case-insensitive).
        #expect(ReceiptFilter.store("coastal supply") != .store("Coastal Supply"))
        #expect(Set<ReceiptFilter>([.all, .all, .business, .customer(a), .customer(a)]).count == 3)
    }

    // MARK: - Financial roll-ups the customer rows display

    @Test func customerRollupsHandleNoInvoicesAndOverpayment() throws {
        let w = try TestStore.demoWorld()
        let customer = barrenCustomer(in: w.context)
        #expect(customer.outstanding == 0)
        #expect(customer.totalPaidToUs == 0)

        let inv = TS.invoice(number: "INV-6001", status: .sent, lines: [(100, false)], in: w.context)
        inv.jobTitle = "Small repair"
        inv.customer = customer
        // Overpaid by $50. `balanceDue` is `max(0, total - amountPaid)`, so the roll-up clamps at
        // zero rather than going negative — the row shows the secondary tint, never a negative
        // "Owed". The overpayment DOES stay in the paid figure, so "Paid" can exceed the invoice
        // total; that's the documented behavior, not a rounding artifact.
        TS.pay(inv, 150, method: .cash, in: w.context)
        w.context.saveChanges()

        #expect(close(customer.totalPaidToUs, 150))
        #expect(close(inv.total, 100))
        #expect(customer.outstanding == 0)         // clamped, not -50
        #expect(!(customer.outstanding > 0.005))   // renders in the secondary tint, not red
        #expect(inv.isPaid)
        GLTestHost.render(CustomerFinancialsSubrow(customer: customer), container: w.container,
                          inNavigationStack: false)
        GLTestHost.render(CustomersScreen(), container: w.container)
    }

    // MARK: - Helpers

    /// A tiny real PNG — enough for UIImage(data:) to succeed in the avatar / thumbnail paths.
    private static func solidPNG() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
            .image { ctx in
                UIColor.systemTeal.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            }
        return image.pngData() ?? Data()
    }
}
