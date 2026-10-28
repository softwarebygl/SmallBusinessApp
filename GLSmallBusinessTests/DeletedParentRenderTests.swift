//
//  DeletedParentRenderTests.swift
//  GLSmallBusinessTests
//
//  F24 (2026-10-03 QA): screens pushed from a customer, employee or subcontractor hold that
//  person and read them while they draw. When the person is deleted while one of those screens
//  is open (iPad: from the middle column; any device: a synced delete from another device),
//  the screen used to keep drawing over the deleted record — reading a deleted @Model traps
//  (Models/LiveRows.swift header) — or stayed up with Save live for someone who is gone.
//
//  Each test opens the screen while the person exists, deletes them the way the app does
//  (DeletionService: the synced delete, saved), lets SwiftUI re-render, and reads the DRAWN
//  pixels: the screen must say "This <customer|employee|subcontractor> was removed".
//
//  `.serialized` is load-bearing: hosted @Query views and RunLoop pumping must not interleave
//  across tests (GLTestHost header, project_swiftdata_test_process_trap).
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct DeletedParentRenderTests {

    // MARK: - Customer children

    @Test func estimatesListSaysTheCustomerWasRemoved() throws {
        // The drawn screen is attached to the result bundle as the proof image.
        expectRemoved(try afterDeletingCustomer(proof: "estimates-deleted-customer") { EstimatesListScreen(customer: $0) },
                      "customer")
    }

    @Test func invoicesListSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { InvoicesListScreen(customer: $0) }, "customer")
    }

    @Test func jobsListSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { JobsListScreen(customer: $0) }, "customer")
    }

    @Test func expensesListSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { ReceiptsListScreen(customer: $0) }, "customer")
    }

    @Test func customerMoreInfoSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { CustomerDetailsScreen(customer: $0) }, "customer")
    }

    @Test func customerChangeOrdersSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { AllChangeOrdersScreen.forLiveCustomer($0) }, "customer")
    }

    @Test func customerEditFormSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { CustomerFormScreen.editingLive($0) }, "customer")
    }

    @Test func customerDetailStillSaysTheCustomerWasRemoved() throws {
        expectRemoved(try afterDeletingCustomer { CustomerDetailScreen(customer: $0) }, "customer")
    }

    // MARK: - Employee children

    @Test func employeeMoreInfoSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { EmployeeDetailsScreen(employee: $0) }, "employee")
    }

    @Test func allHoursSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { AllHoursSheet(employee: $0) }, "employee")
    }

    @Test func allPaychecksSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { AllPaychecksSheet(employee: $0) }, "employee")
    }

    @Test func logHoursSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { LogHoursSheet(employee: $0, existing: nil) }, "employee")
    }

    @Test func logBonusSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { LogBonusSheet(employee: $0, existing: nil) }, "employee")
    }

    @Test func payNowSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { RecordPaycheckSheet(employee: $0, existing: nil) }, "employee")
    }

    @Test func employeeEditFormSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { EmployeeFormScreen.editingLive($0) }, "employee")
    }

    @Test func employeeDetailStillSaysTheEmployeeWasRemoved() throws {
        expectRemoved(try afterDeletingEmployee { EmployeeDetailScreen(employee: $0) }, "employee")
    }

    // MARK: - Subcontractor children

    @Test func subcontractorMoreInfoSaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { SubcontractorDetailsScreen(subcontractor: $0) }, "subcontractor")
    }

    @Test func allActivitySaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { AllActivitySheet(subcontractor: $0) }, "subcontractor")
    }

    @Test func w9SaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { SubcontractorW9DetailScreen(subcontractor: $0) }, "subcontractor")
    }

    @Test func certificateSaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { SubcontractorCOIDetailScreen(subcontractor: $0) }, "subcontractor")
    }

    @Test func form1099SaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { Form1099NECSheet(subcontractor: $0) }, "subcontractor")
    }

    @Test func recordAmountSaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { RecordSubPaymentSheet(subcontractor: $0, existing: nil) },
                      "subcontractor")
    }

    @Test func paySubcontractorSaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { PaySubcontractorSheet(subcontractor: $0) }, "subcontractor")
    }

    @Test func subcontractorEditFormSaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { SubcontractorFormScreen.editingLive($0) }, "subcontractor")
    }

    @Test func subcontractorDetailStillSaysTheSubcontractorWasRemoved() throws {
        expectRemoved(try afterDeletingSubcontractor { SubcontractorDetailScreen(subcontractor: $0) }, "subcontractor")
    }

    // MARK: - Spanish, and the live case

    /// The removed message names the person in the app's language, with the article Spanish
    /// gender needs (F43): "Se eliminó este cliente", never "Se eliminó: customer".
    @Test func removedMessageNamesTheCustomerInSpanish() throws {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        let text = try afterDeletingCustomer(languages: ["es-ES"]) {
            EstimatesListScreen(customer: $0).environment(\.locale, MBLocalization.shared.locale)
        }
        #expect(text.contains("Se eliminó este cliente"), "drew: \(text)")
        #expect(!text.contains("customer"), "an English noun inside the Spanish screen; drew: \(text)")
    }

    /// While the person exists, the screens draw themselves, never the removed message.
    @Test func livePeopleDrawTheirScreens() throws {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let employee = TS.employee(in: context)
        let sub = TS.subcontractor(in: context)
        try context.save()

        let estimates = try DrawnText.screen(EstimatesListScreen(customer: customer), container: container)
        #expect(estimates.contains("Estimates") && !estimates.contains("was removed"), "drew: \(estimates)")
        let edit = try DrawnText.screen(CustomerFormScreen.editingLive(customer), container: container)
        #expect(edit.contains("Marcus") && !edit.contains("was removed"), "drew: \(edit)")
        let logHours = try DrawnText.screen(LogHoursSheet(employee: employee, existing: nil), container: container)
        #expect(!logHours.contains("was removed"), "drew: \(logHours)")
        let activity = try DrawnText.screen(AllActivitySheet(subcontractor: sub), container: container)
        #expect(!activity.contains("was removed"), "drew: \(activity)")
    }

    // MARK: - Helpers

    private func expectRemoved(_ drawn: String, _ noun: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(drawn.contains("This \(noun) was removed"),
                "the screen kept drawing over the deleted \(noun); drew: \(drawn)", sourceLocation: sourceLocation)
    }

    /// A customer with an estimate, saved to an SQLite store (as the app), the screen opened
    /// while they exist, then the customer deleted the way the app deletes (synced, saved).
    private func afterDeletingCustomer<V: View>(languages: [String] = ["en-US"], proof: String? = nil,
                                                _ build: (Customer) -> V) throws -> String {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let customer = TS.customer(in: context)
        let estimate = TS.estimate(number: "EST-DP-0001", in: context)
        estimate.customer = customer
        try context.save()
        _ = customer.listDisplayName
        let screen = build(customer)
        let attach: ((CGImage) -> Void)? = proof.map { name in
            { image in
                if let png = UIImage(cgImage: image).pngData() { Attachment.record(png, named: "\(name).png") }
            }
        }
        return try DrawnText.screen(screen, container: container, size: CGSize(width: 430, height: 600),
                                    languages: languages, drawn: attach, after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.customer(customer)], in: context) }
        })
    }

    private func afterDeletingEmployee<V: View>(_ build: (Employee) -> V) throws -> String {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let employee = TS.employee(in: context)
        TS.logHours(employee, 8, in: context)
        try context.save()
        _ = employee.listDisplayName
        let screen = build(employee)
        return try DrawnText.screen(screen, container: container, size: CGSize(width: 430, height: 600), after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.employee(employee)], in: context) }
        })
    }

    private func afterDeletingSubcontractor<V: View>(_ build: (Subcontractor) -> V) throws -> String {
        let container = try TestStore.makeDiskContainer()
        let context = container.mainContext
        let sub = TS.subcontractor(in: context)
        TS.paySub(sub, 400, in: context)
        try context.save()
        _ = sub.fullName
        let screen = build(sub)
        return try DrawnText.screen(screen, container: container, size: CGSize(width: 430, height: 600), after: {
            _ = try DomainState.subscribed.run { try DeletionService.delete([.subcontractor(sub)], in: context) }
        })
    }
}
