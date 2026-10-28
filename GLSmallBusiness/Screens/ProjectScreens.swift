//
//  ProjectScreens.swift
//  GLSmallBusiness
//
//  The optional Project grouping UI: add a job to a project (create-or-pick inline), a project detail
//  with rolled-up billing across its jobs + a master agreement, and the global All Projects list.
//  Projects are invisible until a contractor reaches for them via "Add to project" on a job.
//

import SwiftUI
import GoldLifeUI
import GoldLifeAI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Add to project (create-or-pick inline)

/// A picker opened from an edit screen (law 63; audit 2026-10-03 F135): tapping a project only
/// selects it (the selection circle moves), Done applies the choice, and Close keeps the old one.
/// "Create & add" and "Remove from project" are actions, not choices, and act on tap.
struct AddToProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allProjects: [Project]
    let job: ScheduledJob

    /// The project the circle is on; starts on the job's current project. An id, not the model,
    /// so a project deleted elsewhere just stops matching.
    @State private var selectedID: PersistentIdentifier?
    @State private var newName = ""
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal ProjectService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

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
                            let isSelected = selectedID == project.persistentModelID
                            Button { selectedID = project.persistentModelID } label: {
                                HStack {
                                    Text(project.displayName).foregroundStyle(GLTheme.textPrimary)
                                    Spacer()
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? GLTheme.accentFill : GLTheme.textSecondary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            .readOnlyRefusalAlert($readOnlyRefusal)
            .domainErrorAlert($domainError)
            .navigationTitle(GLScript.padded(mbLoc("Add to Project")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Add to Project"))), for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applySelection() }
                        // Something listed must be chosen (a project deleted meanwhile drops out).
                        .disabled(!pickableProjects.contains { $0.persistentModelID == selectedID })
                }
            }
            .onAppear {
                if selectedID == nil { selectedID = job.project?.persistentModelID }
            }
        }
    }

    /// What Done does: nothing when the choice is unchanged (or the chosen project is gone), else
    /// the chosen project. Pure, so the rule is tested without a screen.
    static func projectToApply(selectedID: PersistentIdentifier?, currentID: PersistentIdentifier?,
                               in projects: [Project]) -> Project? {
        guard let selectedID, selectedID != currentID else { return nil }
        return projects.first { $0.persistentModelID == selectedID }
    }

    /// Done: applies the selected project, then closes.
    private func applySelection() {
        guard let project = Self.projectToApply(selectedID: selectedID,
                                                currentID: job.project?.persistentModelID,
                                                in: pickableProjects) else {
            dismiss()
            return
        }
        assign(project)
    }

    private func assign(_ project: Project?) {
        guard ReadOnlyGate.allows(.assignJobToProject, into: $readOnlyRefusal) else { return }
        do {
            try ProjectService.assign(job, to: project, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
        dismiss()
    }

    private func createAndAssign() {
        guard ReadOnlyGate.allows(.saveProject, into: $readOnlyRefusal) else { return }
        do {
            try ProjectService.createAndAssign(name: newName, to: job, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            return
        }
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

    /// The sparkles button (law 58, dual entry points). Off for a record the assistant itself
    /// pushed, so the assistant can never open inside the assistant.
    var showsAssistantButton = true

    /// What the model is told is on screen when the sparkles sheet opens.
    private var assistantRecord: GLAIOnScreen? {
        GLAIOnScreen(.project, project, label: project.displayName, in: modelContext)
    }

    @State private var selectedJob: ScheduledJob?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showingAgreementImporter = false
    /// Why a picked file wasn't added (unreadable, or over the backup's 25 MB) — the shared alert.
    @State private var importFailure: FileImportFailure?
    @State private var showingDelete = false
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal ProjectService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var stillExists: Bool {
        allProjects.contains { $0.persistentModelID == project.persistentModelID }
    }
    private var gold: Color { GLTheme.accentFill }
    private var currencyCode: String { "USD" }   // US-only at launch — match every other money surface

    var body: some View {
        // BRANCH, not overlay (CRUD audit 2026-09-02): an overlay still evaluates the body
        // against the deleted record — property reads on a dead @Model trap uncatchably.
        if stillExists { aliveBody } else { DeletedRecordView(title: mbLoc("Project"), noun: "this project") { dismiss() } }
    }

    @ViewBuilder private var aliveBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCard
                jobsCard
                agreementCard
            }
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical)
            // One column with the banners above (QA 2026-10-03 F50): capped at 640 pt, the gutter inside it.
            .glReadableWidth()
        }
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(project.displayName))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(project.displayName)), for: .scrollContent)
        .navigationDestination(item: $selectedJob) { JobDetailScreen(job: $0) }
        .toolbar {
            // A pure check: the id is minted in the button's action, never in this builder.
            if showsAssistantButton, project.canBeNamedToAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    MBAssistantButton { assistantRecord }
                }
            }
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
                guard ReadOnlyGate.allows(.saveProject, into: $readOnlyRefusal) else { return }
                do {
                    try ProjectService.rename(project, to: draftName, in: modelContext)
                } catch {
                    DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete this project? Its jobs are kept.", isPresented: $showingDelete) {
            Button("Delete project", role: .destructive) {
                guard ReadOnlyGate.allows(.deleteProject, into: $readOnlyRefusal) else { return }
                do {
                    try DeletionService.delete([.project(project)], origin: .screen, in: modelContext)
                } catch {
                    DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                    return
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showingAgreementImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            guard ReadOnlyGate.allows(.saveDocument, into: $readOnlyRefusal) else { return }
            // Size-checked first, then read off the main thread (F124).
            Task {
                switch await FileImport.read(url) {
                case .success(let data):
                    do {
                        try DocumentService.set(.masterAgreement(project), data: data, name: url.lastPathComponent,
                                                in: modelContext)
                    } catch {
                        DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
                    }
                case .failure(let failure):
                    importFailure = failure
                }
            }
        }
        .fileImportFailureAlert($importFailure)
    }

    private var summaryCard: some View {
        MBTitledCard(title: "Project total") {
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
        MBTitledCard(title: "Jobs") {
            if project.sortedJobs.isEmpty {
                Text("No jobs in this project yet. Add jobs from their detail screen.")
                    .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(project.sortedJobs) { job in
                        Button { selectedJob = job } label: {
                            HStack(spacing: 10) {
                                Text(job.displayTitle).foregroundStyle(GLTheme.textPrimary)
                                Spacer()
                                Text(job.contractedValue.formatted(.money(code: currencyCode)))
                                    .font(.subheadline).foregroundStyle(GLTheme.textSecondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var agreementCard: some View {
        MBTitledCard(title: "Master agreement") {
            Button { showingAgreementImporter = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: project.hasMasterAgreement ? "checkmark.seal.fill" : "arrow.up.doc")
                        .frame(width: 24).foregroundStyle(gold)
                    Text(project.hasMasterAgreement
                         ? (project.masterAgreementName.isEmpty ? mbLoc("Uploaded") : project.masterAgreementName)
                         : mbLoc("Upload the signed agreement (PDF or image)"))
                        .foregroundStyle(project.hasMasterAgreement ? GLTheme.textPrimary : GLTheme.textSecondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func moneyRow(_ label: LocalizedStringKey, _ amount: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(amount.formatted(.money(code: currencyCode)))
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(GLTheme.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).copyable(value)
        }
    }
}

// MARK: - All projects

struct AllProjectsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Project.createdAt, order: .reverse) private var projects: [Project]
    @State private var selectedProject: Project?
    @State private var pendingDelete: [Project]?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal ProjectService threw that the screen did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    private var currencyCode: String { "USD" }   // US-only at launch — match every other money surface

    var body: some View {
        List {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No projects", systemImage: "folder")
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
                        .confirmFirstDeleteSwipe { pendingDelete = [project] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this project?",
                                 message: "Its jobs are kept. This can’t be undone.") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("All Projects"))), for: .scrollContent)
        .mbSystemBanners()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .containerBackground(for: .navigation) { PrimaryBackground() }
        .navigationTitle(GLScript.padded(mbLoc("All Projects")))
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
                    Text("\(project.sortedJobs.count) jobs")
                    if let customer = project.customer { Text("·"); Text(customer.listDisplayName) }
                }
                .font(.caption).foregroundStyle(GLTheme.textSecondary)
            }
            Spacer()
            Text(project.contractedValue.formatted(.money(code: currencyCode))).font(.subheadline)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(GLTheme.textTertiary)
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, GLLayout.rowContentVerticalPadding)
        .frame(maxWidth: .infinity)
        .glCardBackground()
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func delete(_ items: [Project]) {
        guard ReadOnlyGate.allows(.deleteProject, into: $readOnlyRefusal) else { return }
        do {
            try DeletionService.delete(items.filter { $0.modelContext != nil && !$0.isDeleted }.map(DeletionService.Target.project), origin: .screen, in: modelContext)
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
        }
    }
}
