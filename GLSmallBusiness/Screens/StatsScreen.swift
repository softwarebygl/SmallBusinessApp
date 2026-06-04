//
//  StatsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//

import SwiftUI
import SwiftData
import Charts

struct StatsScreen: View {
    /// iPhone tab usage keeps the Menu button + monogram backdrop (matching the other tab landings).
    /// The iPad split passes `showsMenuButton: false, solidBackground: true` so Stats matches the
    /// Customers and Receipts content columns — no menu button (it lives in the sidebar), solid fill.
    var showsMenuButton: Bool = true
    var solidBackground: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Query private var invoices: [Invoice]
    @Query private var estimates: [Estimate]
    @Query private var receipts: [Receipt]
    @Query private var businessProfiles: [BusinessProfile]

    private enum Mode: Hashable { case all, year, month }

    @State private var mode: Mode = .year
    @State private var selectedYear: Int = Calendar.current.component(.year, from: .now)
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: .now)
    @State private var exportFiles: [URL] = []
    @State private var showingMenu = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    private var period: StatsPeriod {
        switch mode {
        case .all: return .all
        case .year: return .year(selectedYear)
        case .month: return .month(year: selectedYear, month: selectedMonth)
        }
    }

    private var summary: StatsSummary {
        StatsEngine.summary(period: period, invoices: invoices, estimates: estimates, receipts: receipts)
    }

    private var pickerYears: [Int] {
        let available = StatsEngine.availableYears(invoices: invoices, estimates: estimates, receipts: receipts)
        let currentYear = Calendar.current.component(.year, from: .now)
        return Array(Set(available + [currentYear, selectedYear])).sorted(by: >)
    }

    private var hasData: Bool { !invoices.isEmpty || !estimates.isEmpty || !receipts.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    periodSelector
                    if hasData {
                        kpiGrid
                        inOutCard
                        expensesCard
                        estimatesInvoicesCard
                        exportButton
                    } else {
                        ContentUnavailableView {
                            Label("No activity yet", systemImage: "chart.bar")
                        } description: {
                            Text("Estimates, invoices, and receipts will show up here as you add them.")
                        }
                        .padding(.top, 40)
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .containerBackground(for: .navigation) {
                if solidBackground {
                    GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
                } else {
                    PrimaryBackground()
                }
            }
            .navigationTitle("Stats")
            // Leading title in the iPad split column (matches Customers); inline on the iPhone tab.
            .navigationBarTitleDisplayMode(solidBackground ? .automatic : .inline)
            .toolbar {
                if showsMenuButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingMenu = true
                        } label: {
                            MenuButtonLabel()
                        }
                        .accessibilityLabel("Menu")
                    }
                }
            }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
            .onAppear { regenerateExport() }
            .onChange(of: period) { _, _ in regenerateExport() }
        }
    }

    // MARK: - Period selector

    private var periodSelector: some View {
        VStack(spacing: 10) {
            Picker("Period", selection: $mode) {
                Text("All time").tag(Mode.all)
                Text("Year").tag(Mode.year)
                Text("Month").tag(Mode.month)
            }
            .pickerStyle(.segmented)

            if mode != .all {
                HStack {
                    Picker("Year", selection: $selectedYear) {
                        ForEach(pickerYears, id: \.self) { Text(String($0)).tag($0) }
                    }
                    if mode == .month {
                        Picker("Month", selection: $selectedMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text(Calendar.current.monthSymbols[month - 1]).tag(month)
                            }
                        }
                    }
                    Spacer()
                }
                .pickerStyle(.menu)
                .tint(gold)
            }
        }
    }

    // MARK: - KPI cards (glass)

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            kpi("Collected", summary.collected, tint: gold)
            kpi("Expenses", summary.expenses)
            kpi("Net", summary.net, tint: summary.net >= 0 ? .green : .red)
            kpi("Outstanding", summary.outstanding, tint: summary.outstanding > 0 ? .orange : .primary)
        }
    }

    private func kpi(_ label: String, _ value: Double, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value.formatted(.currency(code: "USD")))
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 18))
    }

    // MARK: - Money in vs out

    private var inOutCard: some View {
        GLCard(title: "Money In vs Out") {
            Chart {
                ForEach(summary.inOut) { bucket in
                    BarMark(x: .value("Period", bucket.label), y: .value("Amount", bucket.moneyIn))
                        .foregroundStyle(by: .value("Flow", "In"))
                        .position(by: .value("Flow", "In"))
                    BarMark(x: .value("Period", bucket.label), y: .value("Amount", bucket.moneyOut))
                        .foregroundStyle(by: .value("Flow", "Out"))
                        .position(by: .value("Flow", "Out"))
                }
            }
            .chartForegroundStyleScale(["In": gold, "Out": Color.secondary])
            .chartYAxis {
                AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)))
            }
            .frame(height: 200)
        }
    }

    // MARK: - Expenses by category

    @ViewBuilder
    private var expensesCard: some View {
        GLCard(title: "Expenses by category") {
            if summary.expensesByCategory.isEmpty {
                Text("No receipts in this period.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart(summary.expensesByCategory) { category in
                    SectorMark(
                        angle: .value("Amount", category.amount),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Category", category.category))
                    .cornerRadius(3)
                }
                .frame(height: 200)

                VStack(spacing: 6) {
                    ForEach(summary.expensesByCategory) { category in
                        HStack {
                            Text(category.category)
                            Spacer()
                            Text(category.amount.formatted(.currency(code: "USD")))
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Estimates & invoices

    private var estimatesInvoicesCard: some View {
        GLCard(title: "Estimates & Invoices") {
            statRow("Estimates quoted", summary.estimatesQuoted.formatted(.currency(code: "USD")))
            statRow("Accepted / declined", "\(summary.estimatesAccepted) / \(summary.estimatesDeclined)")
            if let winRate = summary.winRate {
                statRow("Win rate", winRate.formatted(.percent.precision(.fractionLength(0))))
            }
            Divider()
            statRow("Invoices", "\(summary.invoiceCount)")
            statRow("Average invoice", summary.invoiceAverage.formatted(.currency(code: "USD")))
            if summary.overdueCount > 0 {
                statRow("Overdue", "\(summary.overdueCount)", valueColor: .orange)
            }
        }
    }

    private func statRow(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(valueColor)
        }
        .font(.subheadline)
    }

    // MARK: - Export

    private var exportButton: some View {
        ShareLink(items: exportFiles) {
            Label("Export for Accountant", systemImage: "square.and.arrow.up")
                .font(.headline)
                .foregroundStyle(gold)
                .frame(maxWidth: .infinity)
                .padding()
                .glCardBackground()
        }
        .disabled(exportFiles.isEmpty)
    }

    private func regenerateExport() {
        exportFiles = StatsExport.files(
            period: period,
            invoices: invoices,
            estimates: estimates,
            receipts: receipts,
            business: businessProfiles.first
        )
    }
}
