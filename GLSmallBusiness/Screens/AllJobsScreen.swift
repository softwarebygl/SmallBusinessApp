//
//  AllJobsScreen.swift
//  GLSmallBusiness
//
//  A global list of every job in the store, across all customers. Reached from Menu → Job Records and
//  from the Calendar tab's "All Jobs" button. Mirrors AllInvoicesScreen.
//

import SwiftUI
import SwiftData

struct AllJobsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SchedulingPrefs.workdaysMaskKey) private var workdaysMask = SchedulingPrefs.defaultWorkdaysMask
    @Query(sort: \ScheduledJob.startDate, order: .reverse) private var jobs: [ScheduledJob]
    @State private var selectedJob: ScheduledJob?
    @State private var searchText = ""

    private var visibleJobs: [ScheduledJob] {
        guard !searchText.isEmpty else { return jobs }
        let query = searchText.lowercased()
        return jobs.filter {
            $0.displayTitle.lowercased().contains(query) || $0.customerName.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Jobs", systemImage: "hammer")
                } description: {
                    Text("Jobs across all your customers will appear here.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleJobs) { job in
                    Button { selectedJob = job } label: {
                        JobRow(job: job, mask: workdaysMask, showsCustomer: true)
                    }
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
        .contentMargins(.top, 10, for: .scrollContent)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .searchable(text: $searchText, prompt: "Search jobs")
        .overlay {
            if !searchText.isEmpty && visibleJobs.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .navigationTitle("All Jobs")
        .toolbarTitleDisplayMode(.large)
        .navigationDestination(item: $selectedJob) { job in
            JobDetailScreen(job: job)
        }
    }

    private func delete(at offsets: IndexSet) {
        for job in offsets.map({ visibleJobs[$0] }) { modelContext.delete(job) }
        modelContext.saveChanges()
    }
}
