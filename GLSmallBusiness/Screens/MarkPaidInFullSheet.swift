//
//  MarkPaidInFullSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  One-tap "Mark Paid in Full" confirmation sheet pre-filled with exact balance due
//  and payment method picker (Cash, Zelle, Check, Card, etc.) (Ruling 5).
//

import SwiftUI
import SwiftData
import GoldLifeUI

struct MarkPaidInFullSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let invoice: Invoice
    var onPaid: (() -> Void)? = nil

    @State private var method: PaymentMethod = .check
    @State private var date: Date = .now
    @State private var note: String = ""
    @State private var isSubmitting = false
    @State private var readOnlyRefusal: MBWriteOperation?
    @State private var domainError: DomainError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(invoice.number)
                                .font(.headline)
                            Spacer()
                            Text(invoice.customerDisplayName)
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                        }

                        Divider()

                        HStack {
                            Text(mbLoc("Balance Due:"))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                            Spacer()
                            Text(invoice.balanceDue.formatted(.appMoney))
                                .font(.title2.weight(.bold))
                                .foregroundStyle(GLTheme.statusGood)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(mbLoc("Invoice Summary"))
                }

                Section {
                    Picker(mbLoc("Payment Method"), selection: $method) {
                        ForEach(PaymentMethod.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }

                    DatePicker(mbLoc("Date Received"), selection: $date, displayedComponents: .date)

                    TextField(mbLoc("Note (optional)"), text: $note)
                } header: {
                    Text(mbLoc("Payment Details"))
                } footer: {
                    Text(mbLoc("This will record a payment for the entire remaining balance and mark this invoice as Paid in Full."))
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                }

                Section {
                    Button {
                        confirmPaidInFull()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, GLLayout.rowCardInset)
                            }
                            Image(systemName: "checkmark.circle.fill")
                            Text(mbLoc("Confirm Paid in Full"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || invoice.balanceDue <= 0)
                    .foregroundStyle(.white)
                    .listRowBackground(GLTheme.statusGood)
                }
            }
            .glFormBackground()
            .readOnlyRefusalAlert($readOnlyRefusal)
            .domainErrorAlert($domainError)
            .navigationTitle(GLScript.padded(mbLoc("Mark Paid in Full")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Mark Paid in Full"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mbLoc("Cancel")) { dismiss() }
                }
            }
        }
    }

    private func confirmPaidInFull() {
        guard !isSubmitting else { return }
        guard ReadOnlyGate.allows(.recordPayment, into: $readOnlyRefusal) else { return }
        isSubmitting = true

        let fullBalance = invoice.balanceDue
        do {
            try InvoiceService.recordPayment(
                on: invoice,
                amount: fullBalance,
                date: date,
                method: method,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                stripeLinkId: "",
                origin: .screen,
                in: modelContext
            )
            if invoice.isMarkedPastDue {
                invoice.isMarkedPastDue = false
            }
            modelContext.saveChanges()
            dismiss()
            onPaid?()
        } catch {
            isSubmitting = false
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
