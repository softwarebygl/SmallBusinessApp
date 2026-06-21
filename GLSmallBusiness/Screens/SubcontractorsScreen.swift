//
//  SubcontractorsScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  The Subcontractors tab (iPhone / compact). A 1099 summary header shows how much went out this
//  year and how many subs cross the $600 threshold; each row shows the year-to-date total and a 1099
//  badge. iPad drives the same list/detail via IPadRootSplitView. The toolbar's Year-End Report
//  shares the accountant handoff (1099 summary + payment ledger CSVs).
//

import SwiftUI
import SwiftData

struct SubcontractorsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Subcontractor.lastName), SortDescriptor(\Subcontractor.firstName)])
    private var subs: [Subcontractor]
    @Query private var businessProfiles: [BusinessProfile]

    @State private var showingAdd = false
    @State private var showingMenu = false
    @State private var path: [Subcontractor] = []
    @State private var exportFiles: [URL] = []

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if subs.isEmpty {
                    emptyState
                } else {
                    summaryHeader(Subcontractor1099Summary.forYear(subs))
                    ForEach(subs) { sub in
                        Button { path.append(sub) } label: { row(sub) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                    .onDelete(perform: delete)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .containerBackground(for: .navigation) { PrimaryBackground() }
            .navigationTitle("Subcontractors")
            .navigationDestination(for: Subcontractor.self) { SubcontractorDetailScreen(subcontractor: $0) }
            .toolbar { toolbar }
            .sheet(isPresented: $showingAdd) {
                SubcontractorFormScreen { saved in path.append(saved) }.glAppearance(colorScheme)
            }
            .sheet(isPresented: $showingMenu) { MenuScreen().glAppearance(colorScheme) }
            .onAppear { regenerateExport() }
            .onChange(of: subs.map(\.persistentModelID)) { _, _ in regenerateExport() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingMenu = true } label: { MenuButtonLabel() }
                .accessibilityLabel("Menu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingAdd = true } label: { Label("New subcontractor", systemImage: "plus") }
                if !exportFiles.isEmpty {
                    ShareLink(items: exportFiles) {
                        Label("Year-End Report", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: - Header

    private func summaryHeader(_ totals: Subcontractor1099Summary.YearTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAID THIS YEAR")
                .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(totals.totalPaid.formatted(.currency(code: "USD")))
                .font(.title3.weight(.semibold))
            Text(totals.count1099 == 0
                 ? "No subs over the $600 1099 threshold yet."
                 : "\(totals.count1099) \(totals.count1099 == 1 ? "sub needs" : "subs need") a 1099-NEC.")
                .font(.subheadline).foregroundStyle(gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.top, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Row

    private func row(_ sub: Subcontractor) -> some View {
        let total = sub.totalPaid()
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(gold.opacity(0.18))
                Text(sub.initials).font(.subheadline.weight(.semibold)).foregroundStyle(gold)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(sub.listDisplayName).lineLimit(1)
                if sub.requires1099() {
                    Text("1099-NEC due").font(.caption.weight(.medium)).foregroundStyle(gold)
                } else {
                    Text("This year").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if total > 0 {
                Text(total.formatted(.currency(code: "USD")))
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .padding(.horizontal, GLLayout.rowContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Subcontractors", systemImage: "hammer")
        } description: {
            Text("Tap + to add your first subcontractor.")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            subs[index].clearSecureTIN()   // don't leave the TIN behind in the Keychain
            modelContext.delete(subs[index])
        }
        try? modelContext.save()
    }

    private func regenerateExport() {
        exportFiles = SubPayExport.files(
            subcontractors: subs,
            year: Calendar.current.component(.year, from: .now),
            business: businessProfiles.first
        )
    }
}

#Preview {
    SubcontractorsScreen()
        .modelContainer(for: Subcontractor.self, inMemory: true)
}
