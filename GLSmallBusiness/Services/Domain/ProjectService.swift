//
//  ProjectService.swift
//  GLSmallBusiness
//
//  Every project write: Add to Project (create-and-add, pick, remove) and rename — for the project
//  screens and (later) the assistant's tools. The master agreement is `DocumentService`'s, delete
//  is `DeletionService`'s (jobs are kept). Projects have no
//  free-tier cap. A job may only join a project with no customer or its own customer, the same
//  set the Add to Project sheet offers.
//

import Foundation
import SwiftData

@MainActor
enum ProjectService {

    /// Creates a project for the job's customer and adds the job to it (gated as a project save,
    /// as the sheet always has). The name is trimmed and must not be empty.
    @discardableResult
    static func createAndAssign(name: String, to job: ScheduledJob, in context: ModelContext,
                                subscription: SubscriptionManager? = nil) throws -> Project {
        try DomainGate.requireCanCreate(Project.self, cap: nil, operation: .saveProject,
                                        in: context, subscription)
        try DomainGate.requireLive(job, .saveProject)
        let trimmed = try validName(name)
        let project = Project(name: trimmed, customer: job.customer)
        context.insert(project)
        job.project = project
        context.saveChanges()
        return project
    }

    /// Adds `job` to `project`, or takes it out of its project with `nil`.
    static func assign(_ job: ScheduledJob, to project: Project?, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.assignJobToProject, subscription)
        try DomainGate.requireLive(job, .assignJobToProject)
        if let project {
            try DomainGate.requireLive(project, .assignJobToProject)
            if let owner = project.customer,
               owner.persistentModelID != job.customer?.persistentModelID {
                throw DomainGate.refusal(.projectBelongsToAnotherCustomer, .assignJobToProject)
            }
        }
        setIfChanged(job, \.project, project)
        context.saveChanges()
    }

    /// Renames a project. The name is trimmed and must not be empty.
    static func rename(_ project: Project, to name: String, in context: ModelContext,
                       subscription: SubscriptionManager? = nil) throws {
        try DomainGate.requireWritable(.saveProject, subscription)
        try DomainGate.requireLive(project, .saveProject)
        let trimmed = try validName(name)
        setIfChanged(project, \.name, trimmed)
        context.saveChanges()
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DomainGate.refusal(.projectNameRequired, .saveProject) }
        return trimmed
    }
}
