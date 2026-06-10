//
//  RedeemCodeView.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import SwiftUI

/// Settings → "Enter Access Code". Redeems a code into an unlock flag.
struct RedeemCodeView: View {
    @Environment(AccessManager.self) private var access
    @State private var code = ""
    @State private var result: RedeemResult?

    var body: some View {
        Form {
            if access.isEnabled(AccessFlag.unlimitedLifeAccess) {
                Section {
                    Label("Unlimited access is active on this device.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                TextField("Access code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(redeem)
            } footer: {
                Text("Have an access code? Enter it to unlock full access on this device.")
            }

            if let result {
                Section { resultRow(result) }
            }

            Section {
                Button("Redeem", action: redeem)
                    .disabled(AccessCodes.normalize(code).isEmpty)
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
            let detail = expires.map { "Active until \($0.formatted(date: .abbreviated, time: .omitted))" }
                ?? "Lifetime access — enjoy!"
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
        let outcome = access.redeem(code)
        withAnimation { result = outcome }
        if case .success = outcome { code = "" }
    }
}

#Preview {
    NavigationStack { RedeemCodeView() }
        .environment(AccessManager.shared)
}
