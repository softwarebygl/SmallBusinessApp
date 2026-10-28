//
//  AllJobsScreen.swift
//  GLSmallBusiness
//
//  A global list of every job in the store, across all customers. THREE hosts:
//  the Jobs tab's ROOT (owner decision 2026-08-21 — the tab lands here, with the
//  Calendar one tap away in the toolbar), the Menu → Job Records push, and the
//  iPad split's content column. Mirrors AllInvoicesScreen.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct AllJobsScreen: View {
    /// True only for the Jobs tab root (iPhone): wraps its own NavigationStack and
    /// gains the tab-root chrome — Menu button, the + booking menu (lifted from
    /// CalendarScreen so "open the Jobs tab and tap +" stays true), and the
    /// Calendar toolbar button. Pushed hosts (Menu → All Jobs) and the iPad column
    /// keep the plain list.
    var isTabRoot: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query(sort: \ScheduledJob.startDate, order: .reverse) private var jobs: [ScheduledJob]
    @State private var selectedJob: ScheduledJob?
    @State private var pendingDelete: [ScheduledJob]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal JobService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    // Tab-root chrome state (unused when pushed).
    @State private var showingMenu = false
    @State private var showingCalendar = false
    @State private var pickingSource = false
    @State private var pendingSource: SourceBox?
    @State private var showingNewJob = false
    /// The three root entries added 2026-09-01 for the daily loop (estimate → job →
    /// invoice → receipt). Each pushes the SAME screen its existing door pushes; the
    /// customer is chosen inside, so none of them needs one up front.
    @State private var showingNewEstimate = false
    @State private var showingNewInvoice = false
    @State private var showingScanReceipt = false
    @State private var showingPaywall = false
    #if DEBUG
    @State private var didDemoPush = false   // -demoScreen calendar: shot shows the month grid
    #endif

    private var visibleJobs: [ScheduledJob] {
        guard !searchText.isEmpty else { return jobs }
        return jobs.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        if isTabRoot {
            NavigationStack { content.glMinimalBackButtons() }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No jobs", systemImage: "hammer")
                } description: {
                    Text("Jobs across all your customers will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                // Pushed hosts (All Documents -> All Jobs, the iPad column) search in-list like
                // their sibling record lists; only the Jobs tab root uses the system search
                // behind its toolbar magnifying glass (law 47a; QA 2026-10-03 F129 / L9).
                if !isTabRoot {
                    GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search jobs")).asPlainListRow
                }
                ForEach(visibleJobs) { job in
                    Button { selectedJob = job } label: {
                        JobRow(job: job, mask: workdaysMask, showsCustomer: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .confirmFirstDeleteSwipe { pendingDelete = [job] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this job?") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list field is a plain TextField, so the list puts the keyboard away on scroll
        // or a tap outside it (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(isTabRoot ? mbLoc("Jobs") : mbLoc("All Jobs"))), for: .scrollContent)
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .overlay {
            if !searchText.isEmpty && visibleJobs.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle(GLScript.padded(isTabRoot ? mbLoc("Jobs") : mbLoc("All Jobs")))
        .toolbarTitleDisplayMode(.large)
        .navigationDestination(item: $selectedJob) { job in
            JobDetailScreen(job: job)
        }
        .modifier(TabRootChrome(isTabRoot: isTabRoot,
                                showingMenu: $showingMenu,
                                showingCalendar: $showingCalendar,
                                searchText: $searchText,
                                isSearchPresented: $isSearchPresented,
                                pickingSource: $pickingSource,
                                pendingSource: $pendingSource,
                                showingNewJob: $showingNewJob,
                                showingNewEstimate: $showingNewEstimate,
                                showingNewInvoice: $showingNewInvoice,
                                showingScanReceipt: $showingScanReceipt,
                                showingPaywall: $showingPaywall,
                                newJobFromScratch: newJobFromScratch,
                                newJobFromSource: newJobFromSource,
                                newEstimate: newEstimate,
                                newInvoice: newInvoice,
                                colorScheme: colorScheme))
        #if DEBUG
        .onAppear {
            // The marketing shot named "calendar" must still show the month grid: land
            // on the Jobs root, then push the Calendar (tab bar stays visible).
            if isTabRoot, DemoMode.isActive, DemoMode.screen == "calendar", !didDemoPush {
                didDemoPush = true
                showingCalendar = true
            }
        }
        #endif
    }

    /// Start a job from scratch, or show the paywall if a free user is at the job cap.
    private func newJobFromScratch() {
        if attemptJob() { showingNewJob = true }
    }

    /// Schedule a job from an estimate / invoice, or show the paywall at the cap.
    private func newJobFromSource() {
        if AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                    subscription: subscription, operation: .scheduleJob,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            pickingSource = true
        }
    }

    /// Start an estimate, or show the paywall at the estimate cap. The SAME call
    /// `EstimatesListScreen.newEstimate()` makes: this door pushed straight to the form with no
    /// gate on it at all, so the free caps simply did not apply to estimates started from Jobs.
    private func newEstimate() {
        if AccessGate.attemptCreate(Estimate.self, cap: FreeTier.estimates, in: modelContext,
                                    subscription: subscription, operation: .saveEstimate,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingNewEstimate = true
        }
    }

    /// Start an invoice, or show the paywall at the invoice cap — `InvoicesListScreen.newInvoice()`,
    /// for the same reason as above.
    private func newInvoice() {
        if AccessGate.attemptCreate(Invoice.self, cap: FreeTier.invoices, in: modelContext,
                                    subscription: subscription, operation: .saveInvoice,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            showingNewInvoice = true
        }
    }

    /// One call, one outcome: at the free cap it opens the paywall, lapsed it refuses out loud.
    /// The old `if canAddJob() { … } else { showingPaywall = true }` shape would have shown a
    /// lapsed subscriber BOTH.
    private func attemptJob() -> Bool {
        AccessGate.attemptCreate(ScheduledJob.self, cap: FreeTier.jobs, in: modelContext,
                                 subscription: subscription, operation: .saveJob,
                                 paywall: $showingPaywall, refusal: $readOnlyRefusal)
    }

    private func delete(_ items: [ScheduledJob]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteJob, into: $readOnlyRefusal) else { return }
        // Rows a sync removed while the confirmation was up are skipped, as before; DeletionService
        // refuses a dead row rather than writing it.
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.job),
                                       origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}

/// The Jobs tab-root chrome, applied only when hosting as the tab root: Menu button,
/// Calendar push, and the + booking menu with its full plumbing (same gating and
/// destinations as CalendarScreen's own +; both ride this one stack — each host owns
/// its destination state, never mixing drivers).
private struct TabRootChrome: ViewModifier {
    let isTabRoot: Bool
    @Binding var showingMenu: Bool
    @Binding var showingCalendar: Bool
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool
    @Binding var pickingSource: Bool
    @Binding var pendingSource: SourceBox?
    @Binding var showingNewJob: Bool
    @Binding var showingNewEstimate: Bool
    @Binding var showingNewInvoice: Bool
    @Binding var showingScanReceipt: Bool
    @Binding var showingPaywall: Bool
    let newJobFromScratch: () -> Void
    let newJobFromSource: () -> Void
    /// Gated the same way the job entries are — the menu holds four "new record" doors and every
    /// one of them goes through AccessGate before anything is pushed.
    let newEstimate: () -> Void
    let newInvoice: () -> Void
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if isTabRoot {
            content
                // The tab root's system search, opened by the toolbar magnifying glass; the
                // pushed hosts use the in-list row instead (law 47a).
                .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search jobs")
                .onChange(of: isSearchPresented) { _, presented in
                    if !presented {
                        searchText = ""
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingMenu = true } label: { MenuButtonLabel() }
                            .accessibilityLabel("Menu")
                    }

            if !isSearchPresented {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(GLTheme.accent)
                    }
                    .accessibilityLabel("Search jobs")
                    .accessibilityIdentifier("magnifyingglass")
                }
            }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingCalendar = true } label: {
                            Image(systemName: "calendar")
                        }
                        .accessibilityLabel("Calendar")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { newJobFromScratch() } label: { Label("New job", systemImage: "hammer") }
                            Button { newJobFromSource() } label: {
                                Label("From an estimate or invoice", systemImage: "doc.text")
                            }
                            // Writing an estimate is the app's primary job-to-be-done and
                            // had no root entry at all: it started from a CUSTOMER, so a
                            // contractor standing in someone's kitchen had to think
                            // "contacts" before he could think "estimate".
                            Divider()
                            Button { newEstimate() } label: {
                                Label("New estimate", systemImage: "doc.text.magnifyingglass")
                            }
                            Button { newInvoice() } label: {
                                Label("New invoice", systemImage: "banknote")
                            }
                            // Scanning a materials receipt happens standing at a supply-house
                            // counter with one hand free. It was four taps down Contacts.
                            Divider()
                            Button { showingScanReceipt = true } label: {
                                Label("Scan receipt", systemImage: "doc.viewfinder")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add")
                    }
                }
                .navigationDestination(isPresented: $showingCalendar) {
                    CalendarScreen(showsMenuButton: false, ownsStack: false, primaryBackground: true)
                }
                .navigationDestination(isPresented: $showingNewJob) { JobFormScreen() }
                .navigationDestination(isPresented: $showingNewEstimate) {
                    PickCustomerThenScreen(title: "New estimate") { EstimateFormScreen(customer: $0) }
                }
                .navigationDestination(isPresented: $showingNewInvoice) {
                    PickCustomerThenScreen(title: "New invoice") { InvoiceFormScreen(customer: $0) }
                }
                .navigationDestination(isPresented: $showingScanReceipt) { AllReceiptsScreen(autoScan: true) }
                .sheet(isPresented: $pickingSource) {
                    ScheduleSourcePicker { source in
                        pickingSource = false
                        pendingSource = SourceBox(source: source)
                    }
                    .glAppearance(colorScheme)
                }
                .navigationDestination(item: $pendingSource) { box in
                    ScheduleJobSheet(source: box.source)
                }
                .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
                .paywallSheet(isPresented: $showingPaywall)
        } else {
            content
        }
    }
}
