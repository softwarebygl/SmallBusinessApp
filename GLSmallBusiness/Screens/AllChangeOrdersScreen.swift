//
//  AllChangeOrdersScreen.swift
//  GLSmallBusiness
//
//  A global list of every change order across all invoices, for the Records section. Change orders
//  are normally reached through their invoice's ••• menu; this surfaces them all in one place.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct AllChangeOrdersScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \ChangeOrder.createdAt, order: .reverse) private var allChangeOrders: [ChangeOrder]
    /// Non-nil when opened from a customer, so their paper trail is one place.
    var customer: Customer? = nil

    /// Scoped to the customer when there is one. Filtered in memory rather than in the
    /// @Query, matching how the other per-customer lists on CustomerDetailScreen work.
    private var changeOrders: [ChangeOrder] {
        guard let customer else { return allChangeOrders }
        return allChangeOrders.filter {
            $0.invoice?.customer?.persistentModelID == customer.persistentModelID ||
            $0.contract?.customer?.persistentModelID == customer.persistentModelID
        }
    }
    @State private var selectedChangeOrder: ChangeOrder?
    @State private var pendingDelete: [ChangeOrder]?
    @State private var manualRemovalNotice = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// The paid-invoice lock explanation (PaidInvoiceLock.swift): deleting an APPLIED order
    /// deletes its billed group off the invoice, which the server refuses once that invoice is
    /// paid. Unapplied orders own nothing on the invoice and stay deletable.
    @State private var showingPaidLock = false
    @State private var searchText = ""
    /// A refusal ChangeOrderService threw that the list did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var visibleChangeOrders: [ChangeOrder] {
        searchText.isEmpty ? changeOrders : changeOrders.filter { $0.matchesSearch(searchText) }
    }

    private var gold: Color { GLTheme.accentFill }

    var body: some View {
        List {
            if changeOrders.isEmpty {
                ContentUnavailableView {
                    Label(mbLoc("No change orders"), systemImage: "pencil.and.list.clipboard")
                } description: {
                    Text(mbLoc("Change orders you add to an invoice or contract will appear here."))
                }
                .listRowBackground(Color.clear)
            } else {
                GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search change orders")).asPlainListRow
                ForEach(visibleChangeOrders) { changeOrder in
                    Button { selectedChangeOrder = changeOrder } label: { row(changeOrder) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .confirmFirstDeleteSwipe { requestDelete([changeOrder]) }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this change order?",
                                 message: deleteMessage) {
            delete($0)
        }
        .paidInvoiceLockAlert(isPresented: $showingPaidLock)
        .domainErrorAlert($domainError)
        .alert("Remove items by hand", isPresented: $manualRemovalNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A deleted change order’s items couldn’t be matched on its invoice, so they’re still on it. Remove them from the invoice’s line items by hand.")
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        // The in-list search is a plain TextField: put the keyboard away on scroll or a tap outside (law 9).
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("All Change Orders"))), for: .scrollContent)   // breathing room below the large title's descenders
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        
        .overlay {
            if !searchText.isEmpty && visibleChangeOrders.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle(GLScript.padded(mbLoc("All Change Orders")))
        .toolbarTitleDisplayMode(.large)   // force large; .automatic would inherit the inline parent (the Menu)
        .navigationDestination(item: $selectedChangeOrder) { changeOrder in
            ChangeOrderDetailSheet(changeOrder: changeOrder)
        }
    }

    private func row(_ changeOrder: ChangeOrder) -> some View {
        let signedTotal = (changeOrder.total >= 0 ? "+" : "") + changeOrder.total.formatted(.money)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(changeOrder.title.isEmpty ? changeOrder.number : changeOrder.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(signedTotal).font(.headline)
                }
                HStack(spacing: 8) {
                    Text(changeOrder.number)
                    Text("·")
                    Text(changeOrder.status.label)
                    if changeOrder.appliedToInvoice { Text("· added") }
                    Spacer()
                    if let invoiceNumber = changeOrder.invoice?.number, !invoiceNumber.isEmpty {
                        Text(invoiceNumber)
                    } else if let contractNumber = changeOrder.contract?.number, !contractNumber.isEmpty {
                        Text(contractNumber)
                    } else {
                        Label(mbLoc("No invoice"), systemImage: "doc.badge.ellipsis")
                            .foregroundStyle(GLTheme.statusAttention)
                    }
                }
                .font(.caption)
                .foregroundStyle(GLTheme.textSecondary)
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

    /// Warn that an applied order's billed items come off the invoice with it.
    private var deleteMessage: LocalizedStringKey {
        (pendingDelete ?? []).contains(where: \.appliedToInvoice)
            ? "Its items come off the invoice too. This can’t be undone."
            : "This can’t be undone."
    }

    /// The swipe only stages the delete for its alert (law 8); a change order billed to a
    /// paid invoice is locked, so the lock is explained instead.
    private func requestDelete(_ swiped: [ChangeOrder]) {
        if swiped.contains(where: \.isBilledToLockedInvoice) {
            showingPaidLock = true
        } else {
            pendingDelete = swiped
        }
    }

    private func delete(_ items: [ChangeOrder]) {
        // Deleting a record is a write, so a lapsed app refuses it like any other.
        guard ReadOnlyGate.allows(.deleteChangeOrder, into: $readOnlyRefusal) else { return }
        // DeletionService pulls billed items off the invoice first (covering pre-link legacy
        // applies the group cascade can't find), then deletes and saves — always, here; items it
        // couldn't match stay on the invoice and the notice below says so.
        do {
            if case .deleted(let report) = try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.changeOrder),
                                                                       evenIfItemsUnmatched: true, origin: .screen, in: modelContext),
               report.itemsLeftOnInvoice {
                manualRemovalNotice = true
            }
        } catch DomainError.paidLocked {
            showingPaidLock = true
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
