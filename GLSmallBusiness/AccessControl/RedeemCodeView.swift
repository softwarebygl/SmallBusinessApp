//
//  RedeemCodeView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import SwiftUI

/// Settings → "Enter Access Code". Redeems a GL code into an unlock flag.
struct RedeemCodeView: View {
    @Environment(AccessManager.self) private var access
    @State private var group1 = ""
    @State private var group2 = ""
    @State private var result: RedeemResult?

    private var isComplete: Bool { group1.count == 4 && group2.count == 4 }

    var body: some View {
        Form {
            if access.isEnabled(AccessFlag.unlimitedLifeAccess) {
                Section {
                    Label("Unlimited access is active on this device.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                GLCodeField(group1: $group1, group2: $group2, onComplete: redeem)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Enter your GL access code to unlock full access on this device.")
            }

            if let result {
                Section { resultRow(result) }
            }

            Section {
                Button("Redeem", action: redeem).disabled(!isComplete)
            }
        }
        .glFormBackground()
        .navigationTitle("Access Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func resultRow(_ result: RedeemResult) -> some View {
        switch result {
        case .success(_, let expires):
            let detail = expires.map { String(localized: "Active until \($0.formatted(date: .abbreviated, time: .omitted))") }
                ?? String(localized: "Lifetime access — enjoy!")
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Access unlocked").fontWeight(.semibold)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        case .expired:
            Label("That code has expired.", systemImage: "clock.badge.xmark")
                .foregroundStyle(.orange)
        case .invalid:
            Label("That code isn’t valid.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func redeem() {
        guard isComplete else { return }
        let outcome = access.redeem("GL-\(group1)-\(group2)")
        withAnimation { result = outcome }
        if case .success = outcome { group1 = ""; group2 = "" }
    }
}

#Preview {
    NavigationStack { RedeemCodeView() }
        .environment(AccessManager.shared)
}
