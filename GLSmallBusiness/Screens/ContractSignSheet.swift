//
//  ContractSignSheet.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  Contract signing sheet: PencilKit signature canvas, typed name, clear button,
//  and Sign & Confirm saving to contract.signatureData, contract.signedAt,
//  contract.signerName, and setting status to .signed (Ruling 1).
//

import SwiftUI
import SwiftData
import PencilKit
import GoldLifeUI
import GoldLifeDocuments

struct ContractSignSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var contract: Contract

    @State private var signerName: String = ""
    @State private var drawing = PKDrawing()
    @State private var mode: SignatureMode = .draw
    @State private var showingError = false
    @State private var errorMessage = ""

    enum SignatureMode: String, CaseIterable, Identifiable {
        case draw
        case type

        var id: String { rawValue }
        var label: String {
            switch self {
            case .draw: mbLoc("Draw")
            case .type: mbLoc("Type")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(contract.displayTitle)
                            .font(.headline)
                            .foregroundStyle(GLTheme.textPrimary)
                        Text(contract.number)
                            .font(.caption)
                            .foregroundStyle(GLTheme.textSecondary)
                        HStack {
                            Text(mbLoc("Customer:"))
                                .font(.subheadline)
                                .foregroundStyle(GLTheme.textSecondary)
                            Text(contract.displayCustomerName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(GLTheme.textPrimary)
                            Spacer()
                            Text(contract.contractedValue.formatted(.appMoney))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(GLTheme.textPrimary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(mbLoc("Contract Summary"))
                }

                Section {
                    TextField(mbLoc("Signer Full Name"), text: $signerName)
                        .textContentType(.name)
                } header: {
                    HStack {
                        Text(mbLoc("Signer Name"))
                        Spacer()
                        InfoButton(text: "The full legal name of the person signing and authorizing this contract.", topic: "Signer Name")
                    }
                }

                Section {
                    Picker(mbLoc("Method"), selection: $mode) {
                        ForEach(SignatureMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    switch mode {
                    case .draw:
                        VStack(spacing: 10) {
                            ZStack(alignment: .bottom) {
                                SignatureCanvas(drawing: $drawing)
                                    .frame(height: 180)
                                Rectangle()
                                    .fill(Color.black.opacity(0.25))
                                    .frame(height: 1)
                                    .padding(.horizontal, GLLayout.rowContentPadding)
                                    .padding(.bottom, 36)
                            }
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GLTheme.textSecondary.opacity(0.4)))

                            Button(mbLoc("Clear")) {
                                drawing = PKDrawing()
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(GLTheme.accentText)
                        }
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())

                    case .type:
                        VStack(spacing: 12) {
                            if !signerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(signerName)
                                    .font(.custom("SnellRoundhand-Bold", size: 44))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity, minHeight: 90)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                Text(mbLoc("Type your name above to generate signature preview"))
                                    .font(.footnote)
                                    .foregroundStyle(GLTheme.textSecondary)
                                    .frame(maxWidth: .infinity, minHeight: 60)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(mbLoc("Signature"))
                        Spacer()
                        InfoButton(text: "Draw your signature with your finger or Apple Pencil, or type your name for a generated signature.", topic: "Signature")
                    }
                } footer: {
                    Text(mbLoc("By tapping “Sign & Confirm”, you certify that you have reviewed the terms of this contract and agree to be bound by them."))
                        .font(.footnote)
                        .foregroundStyle(GLTheme.textSecondary)
                }
            }
            .glFormBackground()
            .navigationTitle(GLScript.padded(mbLoc("Sign Contract")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Sign Contract"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mbLoc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mbLoc("Sign & Confirm")) {
                        confirmSign()
                    }
                    .disabled(!canConfirm)
                }
            }
            .onAppear {
                if signerName.isEmpty {
                    signerName = contract.displayCustomerName
                }
            }
            .alert(mbLoc("Couldn’t save signature"), isPresented: $showingError) {
                Button(mbLoc("OK"), role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var canConfirm: Bool {
        let trimmedName = signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        switch mode {
        case .draw:
            return !drawing.bounds.isEmpty && drawing.strokes.count > 0
        case .type:
            return true
        }
    }

    private func confirmSign() {
        let signatureData: Data?
        switch mode {
        case .draw:
            signatureData = SignatureRender.png(from: drawing)
        case .type:
            signatureData = SignatureRender.png(typed: signerName)
        }

        guard let signatureData else {
            errorMessage = mbLoc("Please provide a signature before confirming.")
            showingError = true
            return
        }

        contract.signatureData = signatureData
        contract.signerName = signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        contract.signedAt = Date.now
        if contract.status == .draft {
            contract.status = .signed
        }
        modelContext.saveChanges()
        dismiss()
    }
}
