//
//  PickCustomerThenScreen.swift — choose a customer, then continue.
//
//  Added 2026-09-01. Writing an estimate is this app's primary job-to-be-done and had
//  NO root entry: EstimateFormScreen and InvoiceFormScreen both require a customer at
//  init, so the only way in was Contacts ▸ a customer ▸ Records ▸ Estimates ▸ +. A
//  contractor standing in someone's kitchen has to think "contacts" before he can think
//  "estimate", which is backwards — the customer is a detail of the estimate, not the
//  other way round.
//
//  This is the missing step, not a new form: pick (or create) the customer, then push
//  the real screen unchanged. Mirrors JobFormScreen's inline picker rather than
//  inventing a second way to choose a customer.
//
//  A step flow, so law 63 (select, then Continue; audit 2026-10-03 F135): tapping a
//  customer only selects it (the selection circle moves, the screen stays put), and the
//  always-visible Continue pinned to the bottom (GoldLifeUI's `GLStickyPreviewFooter`) is
//  the only way forward, disabled until a customer is chosen.
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct PickCustomerThenScreen<Destination: View>: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SubscriptionManager.self) private var subscription
    @Query(sort: [SortDescriptor(\Customer.lastName), SortDescriptor(\Customer.firstName)])
    private var customers: [Customer]

    let title: String.LocalizationValue
    /// Built once a customer is chosen — the unchanged destination form.
    @ViewBuilder let destination: (Customer) -> Destination

    /// The customer the circle is on. An id, not the model: a customer deleted elsewhere (sync)
    /// simply stops matching, and nothing reads a dead model.
    @State private var selectedID: PersistentIdentifier?
    /// Set by Continue: the customer whose form is pushed.
    @State private var picked: Customer?
    @State private var creatingCustomer = false
    @State private var showingPaywall = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?

    var body: some View {
        Form {
            if customers.isEmpty {
                Section {
                    Text("You have no customers yet. Add one and you can start right away.")
                        .font(.subheadline)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            } else {
                Section("Customer") {
                    ForEach(customers) { customer in
                        let isSelected = selectedID == customer.persistentModelID
                        Button { selectedID = customer.persistentModelID } label: {
                            HStack {
                                Text(customer.listDisplayName)
                                    .foregroundStyle(GLTheme.textPrimary)
                                Spacer()
                                // A choice row wears a selection circle, never a chevron (law 63).
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? GLTheme.accentFill : GLTheme.textSecondary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            // Inline, so "this is for someone new" never means backing out and
            // starting over — the case a contractor hits most on a first estimate.
            Section {
                Button { newCustomer() } label: {
                    Label("New customer…", systemImage: "person.badge.plus")
                }
            }
        }
        .glFormBackground()
        .safeAreaInset(edge: .bottom) {
            GLStickyPreviewFooter("Continue", systemImage: nil) {
                picked = Self.continueTarget(selectedID: selectedID, in: customers)
            }
            .disabled(Self.continueTarget(selectedID: selectedID, in: customers) == nil)
        }
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc(title))), for: .scrollContent)   // script descenders need breathing room (ScriptTitleClearanceTests)
        .navigationTitle(GLScript.padded(mbLoc(title)))
        .toolbarTitleDisplayMode(.large)   // law 57: large even when pushed from an inline parent
        .navigationDestination(item: $picked) { destination($0) }
        .navigationDestination(isPresented: $creatingCustomer) { CustomerFormScreen() }
        .paywallSheet(isPresented: $showingPaywall)
        .readOnlyRefusalAlert($readOnlyRefusal)
    }

    /// The customer Continue opens the form for: the selected one, while it is still in the list.
    /// Nil (Continue disabled) before a choice, or once the chosen customer is gone.
    static func continueTarget(selectedID: PersistentIdentifier?, in customers: [Customer]) -> Customer? {
        guard let selectedID else { return nil }
        return customers.first { $0.persistentModelID == selectedID }
    }

    /// Open the new-customer form, or the paywall if a free user is at the customer cap —
    /// `CustomersScreen.addCustomer()`, verbatim apart from where it pushes. This door bypassed
    /// AccessGate entirely, so the customer cap simply did not exist on the estimate/invoice route:
    /// a free user at 10 customers could add an eleventh from here.
    private func newCustomer() {
        if AccessGate.attemptCreate(Customer.self, cap: FreeTier.customers, in: modelContext,
                                    subscription: subscription, operation: .saveCustomer,
                                    paywall: $showingPaywall, refusal: $readOnlyRefusal) {
            creatingCustomer = true
        }
    }
}
