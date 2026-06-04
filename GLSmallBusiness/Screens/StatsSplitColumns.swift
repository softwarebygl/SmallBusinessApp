//
//  StatsSplitColumns.swift
//  GLSmallBusiness
//
//  PROTOTYPE — branch: prototype/ipad-single-splitview
//
//  Stats laid out natively for the iPad split: the period controls + KPI cards live in the
//  content column, the charts + export live in the wide detail column. Both share one observable
//  period selection, so changing the period in the content column updates the dashboard.
//
//  iPhone keeps the single-scroll StatsScreen untouched. (The card/chart bodies here are copied
//  from StatsScreen rather than shared — a prototype shortcut; productionizing would extract the
//  cards into reusable views used by both.)
//

import SwiftUI
import SwiftData
import Charts

/// Period mode for the split Stats layout (separate from StatsScreen's private Mode).
enum StatsMode: Hashable { case all, year, month }

/// Shared period selection so the controls column and the dashboard detail stay in sync.
@Observable final class StatsSelection {
    var mode: StatsMode = .year
    var year: Int
    var month: Int

    init() {
        let cal = Calendar.current
        self.year = cal.component(.year, from: .now)
        self.month = cal.component(.month, from: .now)
    }

    var period: StatsPeriod {
        switch mode {
        case .all: return .all
        case .year: return .year(year)
        case .month: return .month(year: year, month: month)
        }
    }
}

// MARK: - Content column: period controls + KPIs

struct StatsControlsColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var invoices: [Invoice]
    @Query private var estimates: [Estimate]
    @Query private var receipts: [Receipt]
    @Bindable var selection: StatsSelection

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var summary: StatsSummary {
        StatsEngine.summary(period: selection.period, invoices: invoices, estimates: estimates, receipts: receipts)
    }
    private var pickerYears: [Int] {
        let available = StatsEngine.availableYears(invoices: invoices, estimates: estimates, receipts: receipts)
        let currentYear = Calendar.current.component(.year, from: .now)
        return Array(Set(available + [currentYear, selection.year])).sorted(by: >)
    }
    private var hasData: Bool { !invoices.isEmpty || !estimates.isEmpty || !receipts.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                periodSelector
                if hasData { kpiGrid }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .containerBackground(for: .navigation) {
            GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea()
        }
        .navigationTitle("Stats")
    }

    private var periodSelector: some View {
        VStack(spacing: 10) {
            Picker("Period", selection: $selection.mode) {
                Text("All time").tag(StatsMode.all)
                Text("Year").tag(StatsMode.year)
                Text("Month").tag(StatsMode.month)
            }
            .pickerStyle(.segmented)

            if selection.mode != .all {
                HStack {
                    Picker("Year", selection: $selection.year) {
                        ForEach(pickerYears, id: \.self) { Text(String($0)).tag($0) }
                    }
                    if selection.mode == .month {
                        Picker("Month", selection: $selection.month) {
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
}

// MARK: - Detail column: charts + export

struct StatsDashboard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query private var invoices: [Invoice]
    @Query private var estimates: [Estimate]
    @Query private var receipts: [Receipt]
    @Query private var businessProfiles: [BusinessProfile]
    var selection: StatsSelection

    @State private var exportFiles: [URL] = []

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var summary: StatsSummary {
        StatsEngine.summary(period: selection.period, invoices: invoices, estimates: estimates, receipts: receipts)
    }
    private var hasData: Bool { !invoices.isEmpty || !estimates.isEmpty || !receipts.isEmpty }

    private var periodTitle: String {
        switch selection.mode {
        case .all: return "All time"
        case .year: return String(selection.year)
        case .month: return "\(Calendar.current.monthSymbols[selection.month - 1]) \(selection.year)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if hasData {
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
                    .padding(.top, 60)
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(periodTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { regenerateExport() }
        .onChange(of: selection.period) { _, _ in regenerateExport() }
    }

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
            .frame(height: 220)
        }
    }

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
                .frame(height: 220)

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
            period: selection.period,
            invoices: invoices,
            estimates: estimates,
            receipts: receipts,
            business: businessProfiles.first
        )
    }
}
