//
//  SubcontractorsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Subcontractors tab (iPhone / compact). Each row shows the outstanding "Owed" amount, tinted by
//  owed status; the year-to-date total and 1099 status live on the detail screen's ledger card. iPad
//  drives the same list/detail via IPadRootSplitView. The toolbar's Year-End Report shares the
//  accountant handoff (1099 summary + payment ledger CSVs) for a chosen tax year. Menu > Documents
//  also pushes it (the default, stackless form) as the Subcontractor 1099s year-end door.
//

import SwiftUI
import GoldLifeUI
import SwiftData

extension OwedStatus {
    /// List-row tint: gray when nothing's owed, gold for upcoming, red once it's past due.
    func tint(in colorScheme: ColorScheme) -> Color {
        switch self {
        // Resolved for the scheme the caller asked about. The shared tokens are dynamic
        // colours, so returning one unresolved would silently ignore this parameter -
        // harmless in a live view, wrong for anything that asks for one scheme's value
        // (a PDF, a fixed-ground crop) and wrong as an API contract.
        case .none: GLTheme.resolved(GLTheme.textSecondary, in: colorScheme)
        case .upcoming: GLTheme.resolved(GLTheme.accentFill, in: colorScheme)
        case .pastDue: GLTheme.resolved(GLTheme.statusCritical, in: colorScheme)
        }
    }

    /// The "Owed $X" list subtitle, with a "Past due" suffix so that state isn't signalled by the red
    /// tint alone — it stays legible to VoiceOver and color-blind users (upcoming is the neutral default).
    func owedSubtitle(_ amount: Double) -> String {
        let base = mbLoc("Owed: \(amount.formatted(.money))")
        return self == .pastDue ? "\(base) · \(mbLoc("Past due"))" : base
    }
}

struct SubcontractorsScreen: View {
    /// True only for the Contacts tab pane: wraps its own path-driven NavigationStack and gains the
    /// tab-root chrome (Menu button, Contacts segmented control). Pushed hosts (Menu > Documents >
    /// Subcontractor 1099s) keep the default and render inside the PARENT's stack, because a
    /// NavigationStack inside a pushed destination breaks the bar and its routes. Same contract
    /// and default as AllJobsScreen.isTabRoot, so a bare initializer can never nest a stack.
    var isTabRoot: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @Query(sort: [SortDescriptor(\Subcontractor.lastName), SortDescriptor(\Subcontractor.firstName)])
    private var subs: [Subcontractor]
    @Query private var businessProfiles: [BusinessProfile]

    @State private var showingPaywall = false
    @State private var showingMenu = false
    @State private var path: [Route] = []
    /// The pushed host's single driver, since it has no path of its own.
    @State private var pushedRoute: Route?

    /// A single navigation driver for the stack. Mixing a `path` binding with
    /// `navigationDestination(isPresented:)` corrupts the stack — appending to the path while the
    /// presented add-form dismisses pushes a blank screen — so both the add form and the detail ride
    /// the same path here.
    private enum Route: Hashable {
        case add
        case detail(Subcontractor)
    }
    @State private var exportFiles: [URL] = []
    @State private var showingExportShare = false
    /// The export was allowed but wrote no files — say so rather than do nothing.
    @State private var exportFailed = false
    @State private var searchText = ""
    @State private var pendingDelete: [Subcontractor]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?

    private var gold: Color { GLTheme.accentFill }

    private var yearOptions: [Int] {
        let now = Calendar.current.component(.year, from: .now)
        return Array((now - 4)...now).reversed()
    }

    private var visibleSubs: [Subcontractor] {
        ContactSearch.visible(subs, query: searchText)
    }

    var body: some View {
        if isTabRoot {
            NavigationStack(path: $path) {
                list
                    .navigationDestination(for: Route.self) { destination(for: $0) }
                    .glMinimalBackButtons()
            }
        } else {
            list
                .navigationDestination(item: $pushedRoute) { destination(for: $0) }
        }
    }

    private var list: some View {
        List {
            if isTabRoot { ContactsSegmentPicker(host: .subcontractors).asListRow }
            GLInListSearchHeader(text: $searchText, prompt: ContactSearch.prompt(for: .subcontractors)).asPlainListRow
            if subs.isEmpty {
                emptyState
            } else {
                ForEach(visibleSubs) { sub in
                    Button { open(.detail(sub)) } label: { row(sub) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { pendingDelete = [sub] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this subcontractor?",
                                 message: "Their payment history is removed too. This can’t be undone.") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Subcontractors"))), for: .scrollContent)   // breathing room below the script title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .contactSearchNoResults(searchText, foundNobody: visibleSubs.isEmpty)
        .navigationTitle(GLScript.padded(mbLoc("Subcontractors")))
        .toolbarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
        .sheet(isPresented: $showingExportShare, onDismiss: cleanUpExport) { ActivityView(items: exportFiles) }
        .alert("Couldn’t create the report. Try again.", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
        .paywallSheet(isPresented: $showingPaywall)
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .add:
            if isTabRoot {
                // On save, replace the add route with the detail so Back returns to the list, not
                // the now-stale form. One path mutation, one driver — no blank push.
                SubcontractorFormScreen { saved in path = [.detail(saved)] }
            } else {
                // Pushed host: same outcome as the tab root. Swapping the single driver's value
                // replaces the form with the new detail in place, so Back returns to the list.
                SubcontractorFormScreen { saved in pushedRoute = .detail(saved) }
            }
        case .detail(let sub):
            SubcontractorDetailScreen(subcontractor: sub)
        }
    }

    /// Push a route on whichever driver this host owns.
    private func open(_ route: Route) {
        if isTabRoot { path.append(route) } else { pushedRoute = route }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Tab root only: pushed from the Menu, it would open a second Menu over the first.
        if isTabRoot {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingMenu = true } label: { MenuButtonLabel() }
                    .accessibilityLabel("Menu")
            }
        }

        // "+" IS PERMANENT — it used to disappear into "…" the moment there was
        // an exportable year, moving the add action after the first success.
        ToolbarItem(placement: .topBarTrailing) {
            Button { addSubcontractor() } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add Subcontractor")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !exportableYears.isEmpty {
                // Law 40: the old outer "…" held only this one item, so the year menu
                // IS the button now (one tap saved; the icon is the share glyph).
                //
                // The export CSV carries every subcontractor's full Tax ID, so gate it behind Face ID
                // (same as "Generate 1099-NEC") rather than a one-tap ShareLink anyone can trigger.
                // The CSVs themselves are only written to disk AFTER Face ID succeeds — never
                // eagerly on view load — so full TINs don't sit in plaintext unauthenticated.
                // A year menu, so a January visit can still export LAST year's filing handoff
                // (when 1099-NECs are actually due) — only years with payments are offered.
                Menu {
                        ForEach(exportableYears, id: \.self) { year in
                            Button {
                                Task {
                                    if await BiometricGate.authenticate(reason: mbLoc("Unlock to export the year-end report.")) {
                                        // A refused export already shows the refusal alert.
                                        guard generateExport(year: year) else { return }
                                        if exportFiles.isEmpty { exportFailed = true } else { showingExportShare = true }
                                    }
                                }
                            } label: {
                                Text(verbatim: String(year))
                            }
                        }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Subcontractor 1099 Report")
            }
        }
    }

    // MARK: - Row

    private func row(_ sub: Subcontractor) -> some View {
        return PersonRowCard(
            name: sub.listDisplayName,
            subtitle: sub.owedStatus.owedSubtitle(sub.outstanding),
            subtitleColor: sub.owedStatus.tint(in: colorScheme)
        ) {
            ProfileAvatar(imageData: sub.profileImageData, initials: sub.initials)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No subcontractors", systemImage: "hammer")
        } description: {
            Text("Tap + to add your first subcontractor.")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    /// Open the new-subcontractor form, or the paywall if a free user is at the subcontractor cap.
    private func addSubcontractor() {
        if AccessGate.attemptCreate(Subcontractor.self, cap: FreeTier.subcontractors, in: modelContext,
                                    subscription: subscription, operation: .saveSubcontractor,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            open(.add)
        }
    }

    private func delete(_ items: [Subcontractor]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteSubcontractor, into: $readOnlyRefusal) else { return }
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.subcontractor), origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }

    /// The tax years (newest first) with anything to hand to the accountant — the choices offered by
    /// the Year-End Report menu, decided without writing any TIN-bearing files to disk.
    private var exportableYears: [Int] {
        yearOptions.filter { year in subs.contains { $0.totalPaid(year: year) > 0 } }
    }

    /// Writes the year-end CSVs (which carry full Tax IDs) to the temp directory. Called ONLY after
    /// Face ID succeeds; the files are marked complete-protection so they're encrypted at rest
    /// whenever the device is locked, and removed again when the share sheet closes.
    /// False when the export was refused (the refusal alert says why); true once it ran.
    @discardableResult
    private func generateExport(year: Int) -> Bool {
        // "NO EXPORT" (owner ruling, 2026-08-25). Refused BEFORE the CSVs are written: these files
        // carry full Tax IDs, so a lapsed app must not put them on disk at all, even briefly.
        guard ReadOnlyGate.allows(.exportSubcontractorPay, into: $readOnlyRefusal) else { return false }
        exportFiles = SubPayExport.files(
            subcontractors: subs,
            year: year,
            business: businessProfiles.first
        )
        // Complete protection is applied where the files are written (SubPayExport).
        return true
    }

    /// Delete the plaintext-TIN CSVs as soon as the share sheet is done with them.
    private func cleanUpExport() {
        SharedTempFiles.remove(exportFiles)
        exportFiles = []
    }
}

#Preview {
    SubcontractorsScreen(isTabRoot: true)
        .modelContainer(for: Subcontractor.self, inMemory: true)
}
