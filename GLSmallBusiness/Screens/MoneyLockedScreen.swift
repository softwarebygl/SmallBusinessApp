//
//  MoneyLockedScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//

import SwiftUI
import StoreKit
import GoldLifeUI

/// The locked state presented when a free or non-subscribed user navigates to the Money tab.
/// Explains the value of Connected Banks & Money and provides an immediate upgrade path
/// via PaywallSheet, with restore purchases functionality.
struct MoneyLockedScreen: View {
    var ownsStack: Bool = true
    var onMenuTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingPaywall = false
    @State private var restoring = false
    @State private var restoreAlert: RestoreAlert?

    private struct RestoreAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        if ownsStack {
            NavigationStack {
                content
                    .toolbar {
                        if let onMenuTap {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: onMenuTap) {
                                    MenuButtonLabel()
                                }
                                .accessibilityLabel(mbLoc("Menu"))
                            }
                        }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Top Hero / Lockup Bento Card
                VStack(spacing: 20) {
                    // Jewel Pro Pip
                    HStack(spacing: 6) {
                        Circle()
                            .fill(GLTheme.accent)
                            .frame(width: 6, height: 6)
                        Text("PRO FEATURE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(GLTheme.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(GLTheme.accent.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(GLTheme.accent.opacity(0.3), lineWidth: 1))

                    // Gold Icon Lockup
                    ZStack {
                        Circle()
                            .fill(RadialGradient(
                                colors: [GLTheme.accent.opacity(0.25), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 50
                            ))
                            .frame(width: 100, height: 100)

                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(GLTheme.accent)
                    }

                    VStack(spacing: 8) {
                        Text(mbLoc("Connected Banks & Money"))
                            .font(.title3.weight(.bold))
                            .minimumScaleFactor(0.8)
                            .lineLimit(2)
                            .foregroundStyle(GLTheme.textPrimary)
                            .multilineTextAlignment(.center)

                        Text(mbLoc("Automate your cash flow with live bank sync, automatic expense classification, and recurring subscription tracking."))
                            .font(.subheadline)
                            .foregroundStyle(GLTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.vertical, 22)
                .padding(.horizontal, GLLayout.rowContentPadding)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(GLTheme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(GLTheme.accent.opacity(0.22), lineWidth: 1)
                        )
                )

                // Feature Highlights Bento Cards
                VStack(spacing: 12) {
                    featureRow(
                        icon: "building.columns.fill",
                        title: mbLoc("Live Bank Connections"),
                        detail: mbLoc("Securely link 10,000+ financial institutions via Plaid to stream real-time account balances and transactions.")
                    )

                    featureRow(
                        icon: "chart.line.uptrend.xyaxis",
                        title: mbLoc("Smart Categorization"),
                        detail: mbLoc("Automatic income and expense tagging linked directly to your customer jobs, contracts, and taxes.")
                    )

                    featureRow(
                        icon: "repeat.circle.fill",
                        title: mbLoc("Subscription Management"),
                        detail: mbLoc("Detect active recurring vendor charges and identify unneeded subscriptions to reduce overhead.")
                    )
                }

                // Call to action buttons
                VStack(spacing: 12) {
                    Button {
                        showingPaywall = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "crown.fill")
                                .font(.subheadline)
                            Text(mbLoc("Unlock Money — Upgrade to Pro"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(GLTheme.accent))
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    Button {
                        restore()
                    } label: {
                        HStack(spacing: 6) {
                            if restoring {
                                ProgressView()
                                    .tint(GLTheme.textSecondary)
                            }
                            Text(mbLoc("Restore Purchases"))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(GLTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(restoring)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background { PrimaryBackground() }
        .navigationTitle(GLScript.padded(mbLoc("Connected Banks & Money")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Connected Banks & Money"))), for: .scrollContent)
        .paywallSheet(isPresented: $showingPaywall, context: .money)
        .alert(restoreAlert?.title ?? "", isPresented: Binding(
            get: { restoreAlert != nil },
            set: { if !$0 { restoreAlert = nil } }
        ), presenting: restoreAlert) { _ in
            Button("OK", role: .cancel) { restoreAlert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(GLTheme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(GLTheme.accent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GLTheme.textPrimary)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(GLTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(GLTheme.accent.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func restore() {
        restoring = true
        Task {
            defer { restoring = false }
            do {
                try await AppStore.sync()
                await SubscriptionManager.shared.refreshServerEntitlement()
                restoreAlert = RestoreAlert(
                    title: mbLoc("Purchases Restored"),
                    message: mbLoc("Your subscriptions and purchases have been refreshed.")
                )
            } catch {
                restoreAlert = RestoreAlert(
                    title: mbLoc("Couldn’t Restore Purchases"),
                    message: error.localizedDescription
                )
            }
        }
    }
}
