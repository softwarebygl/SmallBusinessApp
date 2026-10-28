//
//  AllInvoicesScreen.swift
//  GLSmallBusiness
//
//  A global list of every invoice in the store — across all customers, plus any that have no
//  customer. Normally invoices are browsed per-customer, so a stray "no customer" invoice (left by
//  a past sync hiccup) is invisible there yet still counts in Stats. This screen surfaces them so
//  they can be opened and deleted.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct AllInvoicesScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @State private var selectedInvoice: Invoice?
    @State private var pendingDelete: [Invoice]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal a domain service found that the screen's own checks didn't (DomainErrorAlert).
    @State private var domainError: DomainError?
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift). A paid invoice's money is
    /// settled, so the server refuses to delete it or anything inside it.
    @State private var showingPaidLock = false
    @State private var searchText = ""

    private var orphanCount: Int { invoices.filter { $0.customer == nil }.count }

    private var visibleInvoices: [Invoice] {
        searchText.isEmpty ? invoices : invoices.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        List {
            if invoices.isEmpty {
                ContentUnavailableView {
                    Label("No invoices", systemImage: "banknote")
                } description: {
                    Text("Invoices across all your customers will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                // "What am I owed?" answered at a glance, all-time and never
                // period-scoped — a contractor chasing money does not care which
                // month the work happened in. Equatable on the invoices it sums, so
                // a search keystroke never re-adds every balance (QA F92).
                OwedToYouCard(invoices: invoices).equatable()
                if orphanCount > 0 {
                    Text(orphanCount == 1
                         ? "1 invoice has no customer — it still counts in Stats. Swipe left to delete it."
                         : "\(orphanCount) invoices have no customer — they still count in Stats. Swipe left to delete any you don’t want.")
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                        .padding(.horizontal, GLLayout.rowCardInset)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search invoices")).asPlainListRow
                ForEach(visibleInvoices) { invoice in
                    Button { selectedInvoice = invoice } label: { row(invoice) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { requestDelete([invoice]) }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this invoice?") {
            delete($0)
        }
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("All Invoices"))), for: .scrollContent)   // breathing room below the large title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        
        .overlay {
            if !searchText.isEmpty && visibleInvoices.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle(GLScript.padded(mbLoc("All Invoices")))
        .toolbarTitleDisplayMode(.large)   // force large; .automatic would inherit the inline parent (the Menu)
        .navigationDestination(item: $selectedInvoice) { invoice in
            InvoiceDetailScreen(invoice: invoice)
        }
    }

    private func row(_ invoice: Invoice) -> some View {
        let orphaned = invoice.customer == nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(invoice.jobTitle.isEmpty ? mbLoc("Untitled invoice") : invoice.jobTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(invoice.total.formatted(.money))
                        .font(.headline)
                }
                HStack(spacing: 8) {
                    Text(invoice.number)
                    Text("·")
                    Text(invoice.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale)))
                    Spacer()
                    if orphaned {
                        Label("No customer", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(GLTheme.statusAttention)
                    } else {
                        Text(invoice.customer?.listDisplayName ?? "")
                    }
                }
                .font(.caption)
                .foregroundStyle(GLTheme.textSecondary)
                // Status and balance, the same two things the per-customer list has
                // shown all along (InvoicesListScreen). Without them the ONE list that
                // spans every customer could not answer "who still owes me".
                HStack(spacing: 8) {
                    InvoiceStatusBadge(invoice: invoice)
                    Spacer()
                    if !invoice.isPaid && invoice.balanceDue > 0.005 {
                        Text("Balance \(invoice.balanceDue.formatted(.money))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GLTheme.accentText)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GLTheme.textTertiary)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The swipe only stages the delete for its alert (law 8). Same rule as the per-customer
    /// list: the server refuses to tombstone a paid invoice, so the app must not stage one here
    /// either.
    private func requestDelete(_ swiped: [Invoice]) {
        if swiped.contains(where: \.isMoneyLocked) {
            showingPaidLock = true
        } else {
            pendingDelete = swiped
        }
    }

    private func delete(_ items: [Invoice]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteInvoice, into: $readOnlyRefusal) else { return }
        // DeletionService re-checks the paid lock, deletes and saves.
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.invoice),
                                       origin: .screen, in: modelContext)
        } catch DomainError.paidLocked {
            showingPaidLock = true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}

/// All Invoices' "Owed to you" card. Its body sums every balance, so it must redraw only when
/// that sum can change: SwiftUI skips it while the same invoices come back (a search keystroke
/// redraws the screen around it), and the invoices' own observation redraws it when a payment,
/// line or status changes. Silent when nothing is outstanding, because a permanent $0.00 is
/// just furniture.
struct OwedToYouCard: View, Equatable {
    let invoices: [Invoice]

    static func == (lhs: OwedToYouCard, rhs: OwedToYouCard) -> Bool {
        lhs.invoices.map(\.persistentModelID) == rhs.invoices.map(\.persistentModelID)
    }

    /// Every unpaid balance, across every customer, for all time. A paid invoice's balance is
    /// exactly $0.00 (whole cents, law 60), so summing every balance is the same figure — one
    /// pass, not two.
    static func owedTotal(_ invoices: [Invoice]) -> Double {
        #if DEBUG
        computations += 1
        #endif
        return DomainMoney.roundedSum(invoices.map(\.balanceDue))
    }

    #if DEBUG
    /// How many times `owedTotal` has run (tests: typing in search never runs it).
    static private(set) var computations = 0
    #endif

    var body: some View {
        let owed = Self.owedTotal(invoices)
        if owed > 0.005 {
            HStack {
                Text("Owed to you").font(.subheadline).foregroundStyle(GLTheme.textSecondary)
                Spacer()
                Text(owed.formatted(.money))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(GLTheme.accentText)
            }
            .padding(GLLayout.rowContentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glCardBackground()
            .padding(.horizontal, GLLayout.rowCardInset)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }
}
