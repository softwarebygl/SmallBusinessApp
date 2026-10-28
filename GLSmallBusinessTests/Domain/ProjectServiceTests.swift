//
//  ProjectServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The project save path shared by Add to Project, the project detail screen, All Projects and the
//  assistant.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct ProjectServiceTests {

    @Test func createAndAssignUsesTheJobsCustomerAndIsNeverCapped() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = TS.job("Kitchen", start: TS.day(2026, 9, 1), customer: customer, in: context)
        let project = try DomainState.neverSubscribed.run {
            try ProjectService.createAndAssign(name: "  Remodel ", to: job, in: context)
        }
        #expect(project.name == "Remodel" && project.customer === customer)
        #expect(job.project === project)
        #expect(project.syncID != nil && !context.hasChanges)

        #expect(DomainState.subscribed.run { domainError { try ProjectService.createAndAssign(name: "   ", to: job, in: context) } }
                == .projectNameRequired)
        #expect(DomainState.lapsed.run { domainError { try ProjectService.createAndAssign(name: "B", to: job, in: context) } }
                == .readOnly(operation: "saveProject", lapsed: true))
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
    }

    @Test func assignAndRemove() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let job = TS.job("Bath", start: TS.day(2026, 9, 1), customer: customer, in: context)
        let open = Project(name: "Open")                     // no customer: anyone's job may join
        let theirs = Project(name: "Theirs", customer: customer)
        let someoneElses = Project(name: "Other", customer: TS.customer(first: "Ann", in: context))
        [open, theirs, someoneElses].forEach(context.insert)
        context.saveChanges()

        try DomainState.subscribed.run {
            try ProjectService.assign(job, to: open, in: context)
            #expect(job.project === open)
            try ProjectService.assign(job, to: theirs, in: context)
            #expect(job.project === theirs)
            #expect(domainError { try ProjectService.assign(job, to: someoneElses, in: context) }
                    == .projectBelongsToAnotherCustomer)
            #expect(job.project === theirs)
            try ProjectService.assign(job, to: nil, in: context)
            #expect(job.project == nil)
        }
        #expect(!context.hasChanges)
        #expect(DomainState.offline.run { domainError { try ProjectService.assign(job, to: open, in: context) } }
                == .readOnly(operation: "assignJobToProject", lapsed: false))
    }

    @Test func renameRejectsAnEmptyName() throws {
        let context = try DomainFixtures.context()
        let project = Project(name: "Phase 1")
        context.insert(project)
        context.saveChanges()
        try DomainState.subscribed.run {
            try ProjectService.rename(project, to: " Phase 2 ", in: context)
            #expect(project.name == "Phase 2")
            #expect(domainError { try ProjectService.rename(project, to: "  ", in: context) } == .projectNameRequired)
        }
        #expect(project.name == "Phase 2")
    }

    @Test func masterAgreementUploadAndRemove() throws {
        let context = try DomainFixtures.context()
        let project = Project(name: "P")
        context.insert(project)
        try DomainState.subscribed.run {
            try DocumentService.set(.masterAgreement(project), data: Data([1]), name: "msa.pdf", in: context)
            #expect(project.hasMasterAgreement && project.masterAgreementName == "msa.pdf")
            try DocumentService.set(.masterAgreement(project), data: nil, name: "msa.pdf", in: context)
            #expect(!project.hasMasterAgreement && project.masterAgreementName == "")
        }
        #expect(DomainState.lapsed.run { domainError { try DocumentService.set(.masterAgreement(project), data: Data([2]), name: "x", in: context) } }
                == .readOnly(operation: "saveDocument", lapsed: true))
    }

    /// Jobs survive their project; a batch with a project already gone refuses as a whole.
    @Test func deleteKeepsTheJobs() throws {
        let context = try DomainFixtures.context()
        let job = TS.job("Deck", start: TS.day(2026, 9, 1), in: context)
        let a = Project(name: "A"), b = Project(name: "B")
        [a, b].forEach(context.insert)
        job.project = a
        context.saveChanges()

        #expect(DomainState.lapsed.run { domainError { try DeletionService.delete([.project(a)], in: context) } }
                == .readOnly(operation: "deleteProject", lapsed: true))
        _ = try DomainState.subscribed.run { try DeletionService.delete([.project(a)], in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ScheduledJob>()) == 1)
        #expect(job.project == nil)
        #expect(!context.hasChanges, "the delete and its outbox row are saved")

        #expect(DomainState.subscribed.run { domainError { try DeletionService.delete([.project(b), .project(a)], in: context) } }
                == .recordNotFound)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1, "nothing in a refused batch is deleted")
    }
}
