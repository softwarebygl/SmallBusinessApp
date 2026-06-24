//
//  ProjectScreens.swift
//  GLSmallBusiness
//
//  The optional Project grouping UI: add a job to a project (create-or-pick inline), a project detail
//  with rolled-up billing across its jobs + a master agreement, and the global All Projects list.
//  Projects are invisible until a contractor reaches for them via "Add to project" on a job.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Add to project (create-or-pick inline)

struct AddToProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allProjects: [Project]
    let job: ScheduledJob

    @State private var newName = ""

    private var pickableProjects: [Project] {
        allProjects
            .filter { $0.customer == nil || $0.customer?.persistentModelID == job.customer?.persistentModelID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !pickableProjects.isEmpty {
                    Section("Add to an existing project") {
                        ForEach(pickableProjects) { project in
                            Button { assign(project) } label: {
                                HStack {
                                    Text(project.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if job.project?.persistentModelID == project.persistentModelID {
                                        Image(systemName: "checkmark").foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("New project") {
                    TextField("Project name", text: $newName)
                    Button("Create & add") { createAndAssign() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if job.project != nil {
                    Section {
                        Button("Remove from project", role: .destructive) { assign(nil) }
                    }
                }
            }
            .glFormBackground()
            .navigationTitle("Add to Project")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func assign(_ project: Project?) {
        job.project = project
        modelContext.saveChanges()
        dismiss()
    }

    private func createAndAssign() {
        let project = Project(name: newName.trimmingCharacters(in: .whitespacesAndNewlines), customer: job.customer)
        modelContext.insert(project)
        job.project = project
        modelContext.saveChanges()
        dismiss()
    }
}

// MARK: - Project detail (roll-up + jobs + master agreement)

struct ProjectDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allProjects: [Project]
    let project: Project

    @State private var selectedJob: ScheduledJob?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showingAgreementImporter = false
    @State private var agreementUploadFailed = false
    @State private var showingDelete = false

    private var stillExists: Bool {
        allProjects.contains { $0.persistentModelID == project.persistentModelID }
    }
    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCard
                jobsCard
                agreementCard
            }
            .padding()
        }
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .overlay { if !stillExists { DeletedRecordView(noun: "project") { dismiss() } } }
        .navigationTitle(project.displayName)
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedJob) { JobDetailScreen(job: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { draftName = project.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Section {
                        Button(role: .destructive) { showingDelete = true } label: {
                            Label("Delete project", systemImage: "trash")
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .alert("Rename project", isPresented: $renaming) {
            TextField("Project name", text: $draftName)
            Button("Save") {
                project.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                modelContext.saveChanges()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this project? Its jobs are kept.", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                modelContext.delete(project)
                modelContext.saveChanges()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showingAgreementImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            if let data = url.readSecurityScoped() {
                project.masterAgreementData = data
                project.masterAgreementName = url.lastPathComponent
                modelContext.saveChanges()
            } else {
                agreementUploadFailed = true
            }
        }
        .alert("Couldn’t read that file", isPresented: $agreementUploadFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var summaryCard: some View {
        GLCard(title: "Project total") {
            VStack(alignment: .leading, spacing: 10) {
                if let customer = project.customer { infoRow("Customer", customer.listDisplayName) }
                moneyRow("Contracted", project.contractedValue)
                if project.invoicedTotal > 0.005 { moneyRow("Invoiced", project.invoicedTotal) }
                if project.amountPaid > 0.005 { moneyRow("Collected", project.amountPaid) }
                if project.remainingToInvoice > 0.005 { moneyRow("Left to invoice", project.remainingToInvoice) }
                if project.balanceDue > 0.005 { moneyRow("Balance due", project.balanceDue) }
            }
        }
    }

    private var jobsCard: some View {
        GLCard(title: "Jobs") {
            if project.sortedJobs.isEmpty {
                Text("No jobs in this project yet. Add jobs from their detail screen.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(project.sortedJobs) { job in
                        Button { selectedJob = job } label: {
                            HStack(spacing: 10) {
                                Text(job.displayTitle).foregroundStyle(.primary)
                                Spacer()
                                Text(job.contractedValue.formatted(.currency(code: currencyCode)))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var agreementCard: some View {
        GLCard(title: "Master agreement") {
            Button { showingAgreementImporter = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: project.hasMasterAgreement ? "checkmark.seal.fill" : "arrow.up.doc")
                        .frame(width: 24).foregroundStyle(gold)
                    Text(project.hasMasterAgreement
                         ? (project.masterAgreementName.isEmpty ? "Uploaded" : project.masterAgreementName)
                         : "Upload the signed agreement (PDF or image)")
                        .foregroundStyle(project.hasMasterAgreement ? .primary : .secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func moneyRow(_ label: LocalizedStringKey, _ amount: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(amount.formatted(.currency(code: currencyCode)))
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - All projects

struct AllProjectsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Project.createdAt, order: .reverse) private var projects: [Project]
    @State private var selectedProject: Project?

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        List {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Group several jobs into a project from a job’s detail screen.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(projects) { project in
                    Button { selectedProject = project } label: { row(project) }
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
        .navigationTitle("All Projects")
        .toolbarTitleDisplayMode(.large)
        .navigationDestination(item: $selectedProject) { project in
            ProjectDetailScreen(project: project)
        }
    }

    private func row(_ project: Project) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayName).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(project.sortedJobs.count) \(project.sortedJobs.count == 1 ? "job" : "jobs")")
                    if let customer = project.customer { Text("·"); Text(customer.listDisplayName) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(project.contractedValue.formatted(.currency(code: currencyCode))).font(.subheadline)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func delete(at offsets: IndexSet) {
        for project in offsets.map({ projects[$0] }) { modelContext.delete(project) }
        modelContext.saveChanges()
    }
}
