//
//  StatsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/29/26.
//
//  The business Income & Expenses screen (law 22: named like its Menu row, Menu → Reports →
//  Income & Expenses; My Business Details links it too) — no longer a top-level tab — so it renders inside the parent NavigationStack and carries no
//  Menu button of its own. The Year-End Tax Report lives solely on the Business screen now, so
//  this screen no longer duplicates that export.
//

import SwiftUI
import GoldLifeUI
import SwiftData
import Charts

struct StatsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var invoices: [Invoice]
    @Query private var estimates: [Estimate]
    @Query private var receipts: [Receipt]

    private enum Mode: Hashable { case all, year, month }

    @State private var mode: Mode = .year
    @State private var selectedYear: Int = Calendar.current.component(.year, from: .now)
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: .now)

    private var gold: Color { GLTheme.accentFill }

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

    /// Open on the most recent year that has activity, so a January (or seasonal) visit doesn't land on
    /// an all-zeros current year and read as "the app lost my numbers".
    private func selectMostRecentActiveYear() {
        let years = StatsEngine.availableYears(invoices: invoices, estimates: estimates, receipts: receipts)
        if let mostRecent = years.max(), !years.contains(selectedYear) {
            selectedYear = mostRecent
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                periodSelector
                if hasData {
                    // Compute the summary ONCE per render — it scans the whole store, and the
                    // cards below would otherwise each re-trigger it (a dozen full scans/render).
                    let summary = self.summary
                    kpiGrid(summary)
                    inOutCard(summary)
                    expensesCard(summary)
                    estimatesInvoicesCard(summary)
                } else {
                    ContentUnavailableView {
                        Label("No activity yet", systemImage: "chart.bar")
                    } description: {
                        Text("Estimates, invoices, and receipts will show up here as you add them.")
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .mbSystemBanners(capsContent: false)
        .containerBackground(for: .navigation) {
            GLTheme.background.ignoresSafeArea()
        }
        // A REAL collapsing nav-bar script title (parity ruling 5), as a resolved
        // String so an in-app language switch re-renders the bar.
        .navigationTitle(GLScript.padded(mbLoc("Income & Expenses")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Income & Expenses"))), for: .scrollContent)   // breathing room below the large title's descenders
        .onAppear { selectMostRecentActiveYear() }
    }

    // MARK: - Period selector

    private var periodSelector: some View {
        VStack(spacing: 10) {
            // Segmented at normal sizes; a menu at accessibility sizes, where the three
            // segments truncate. The two styles are different types, so the branch is at
            // the view level, not a ternary.
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Period", selection: $mode) {
                        Text("All time").tag(Mode.all)
                        Text("Year").tag(Mode.year)
                        Text("Month").tag(Mode.month)
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("Period", selection: $mode) {
                        Text("All time").tag(Mode.all)
                        Text("Year").tag(Mode.year)
                        Text("Month").tag(Mode.month)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if mode != .all {
                HStack {
                    Picker("Year", selection: $selectedYear) {
                        ForEach(pickerYears, id: \.self) { Text(String($0)).tag($0) }
                    }
                    if mode == .month {
                        Picker("Month", selection: $selectedMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text(localizedMonthSymbols[month - 1]).tag(month)
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

    /// Month names in the app's chosen language, not the device locale (law 25).
    private var localizedMonthSymbols: [String] { Calendar.appLanguage.monthSymbols }

    // MARK: - KPI tiles (the fleet MMStat contract: surface card, sentence-case label,
    // value in textPrimary — never a status tint)

    private func kpiGrid(_ summary: StatsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            kpi(mbLoc("Collected"), summary.collected)
            kpi(mbLoc("Expenses"), summary.expenses)
            if summary.processingFees > 0 {
                kpi(mbLoc("Processing fees"), summary.processingFees)
            }
            kpi(mbLoc("Net"), summary.net)
            kpi(mbLoc("Outstanding"), summary.outstanding)
        }
    }

    private func kpi(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.glCaption)
                .foregroundStyle(GLTheme.textSecondary)
            Text(value.formatted(.appMoney))
                .font(.title3.weight(.semibold))
                .foregroundStyle(GLTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(GLTheme.surface, in: .rect(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Money in vs out

    private func inOutCard(_ summary: StatsSummary) -> some View {
        MBTitledCard(title: "Money In vs Out") {
            let inL = mbLoc("In")
            let outL = mbLoc("Out")
            Chart {
                ForEach(summary.inOut) { bucket in
                    BarMark(x: .value("Period", bucket.label), y: .value("Amount", bucket.moneyIn))
                        .foregroundStyle(by: .value("Flow", inL))
                        .position(by: .value("Flow", inL))
                    BarMark(x: .value("Period", bucket.label), y: .value("Amount", bucket.moneyOut))
                        .foregroundStyle(by: .value("Flow", outL))
                        .position(by: .value("Flow", outL))
                }
            }
            .chartForegroundStyleScale([inL: gold, outL: GLTheme.categoryShade(rank: 2)])
            .chartYAxis {
                AxisMarks(format: .appMoney.precision(.fractionLength(0)))
            }
            .frame(height: 200)
        }
    }

    // MARK: - Expenses by category

    @ViewBuilder
    private func expensesCard(_ summary: StatsSummary) -> some View {
        MBTitledCard(title: "Expenses by category") {
            if summary.expensesByCategory.isEmpty {
                Text("No receipts in this period.")
                    .font(.subheadline)
                    .foregroundStyle(GLTheme.textSecondary)
            } else {
                // Categories shade by rank on the gold ramp (fleet chart rule) — the
                // rows below carry the matching dot, so no framework legend.
                Chart {
                    ForEach(Array(summary.expensesByCategory.enumerated()), id: \.element.id) { rank, category in
                        SectorMark(
                            angle: .value("Amount", category.amount),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .foregroundStyle(GLTheme.categoryShade(rank: rank))
                        .cornerRadius(3)
                    }
                }
                .frame(height: 200)

                VStack(spacing: 6) {
                    ForEach(Array(summary.expensesByCategory.enumerated()), id: \.element.id) { rank, category in
                        HStack {
                            Circle()
                                .fill(GLTheme.categoryShade(rank: rank))
                                .frame(width: 10, height: 10)
                            Text(category.category)
                            Spacer()
                            Text(category.amount.formatted(.appMoney))
                                .foregroundStyle(GLTheme.textSecondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Estimates & invoices

    private func estimatesInvoicesCard(_ summary: StatsSummary) -> some View {
        MBTitledCard(title: "Estimates & Invoices") {
            statRow("Estimates quoted", summary.estimatesQuoted.formatted(.appMoney))
            statRow("Accepted / declined", "\(summary.estimatesAccepted) / \(summary.estimatesDeclined)")
            if let winRate = summary.winRate {
                statRow("Win rate", winRate.formatted(.percent.precision(.fractionLength(0)).locale(MBLocalization.currentLocale)))
            }
            Divider()
            statRow("Invoices", "\(summary.invoiceCount)")
            statRow("Average invoice", summary.invoiceAverage.formatted(.appMoney))
            if summary.overdueCount > 0 {
                statRow("Overdue", "\(summary.overdueCount)", valueColor: GLTheme.statusAttention)
            }
        }
    }

    private func statRow(_ label: LocalizedStringKey, _ value: String, valueColor: Color = GLTheme.textPrimary) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(valueColor)
        }
        .font(.subheadline)
    }
}
