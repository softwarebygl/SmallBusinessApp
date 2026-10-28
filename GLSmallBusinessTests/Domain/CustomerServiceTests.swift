//
//  CustomerServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The one customer save path: what the Customer form, the detail screen's photo and certificate
//  controls, and the assistant all call.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct CustomerServiceTests {

    private let draft = CustomerDraft(
        firstName: "  Jane ", middleName: "", lastName: "Lopez ", businessName: "  ",
        email: " jane@example.com ", phoneNumber: "(850) 555-0100", officePhone: "",
        address: Address(street1: " 12 Oak St ", street2: "  ", city: "Miami ",
                         state: "FL", postalCode: "32301"))

    // MARK: Create

    @Test func createTrimsNormalizesSavesAndStampsASyncID() throws {
        let context = try DomainFixtures.context()
        let photo = Data([1, 2, 3])
        let customer = try DomainState.subscribed.run {
            try CustomerService.create(draft, photo: photo, in: context)
        }
        #expect(customer.firstName == "Jane" && customer.lastName == "Lopez")
        #expect(customer.email == "jane@example.com")
        #expect(customer.businessName == nil, "an empty business name stores as nil")
        #expect(customer.addressStreet1 == "12 Oak St" && customer.addressCity == "Miami")
        #expect(customer.addressStreet2 == "", "an empty Apt/Suite stays empty")
        #expect(customer.profileImageData == photo)
        #expect(customer.syncID != nil, "saveChanges ran — the new customer is identified NOW, not next launch")
        #expect(customer.updatedAt != nil)
        #expect(!context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 1)
    }

    @Test func aBusinessAloneIsEnoughAndNoNameIsRefused() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            let business = try CustomerService.create(CustomerDraft(businessName: " Reed GC "), in: context)
            #expect(business.businessName == "Reed GC")
            #expect(domainError { try CustomerService.create(CustomerDraft(email: "x@y.z"), in: context) }
                    == .nameRequired)
        }
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 1, "a refused create writes nothing")
    }

    @Test func createIsRefusedAtTheFreeCapAndWhileReadOnly() throws {
        let context = try DomainFixtures.context()
        for i in 0..<FreeTier.customers { context.insert(Customer(firstName: "C\(i)")) }
        try context.save()

        #expect(DomainState.neverSubscribed.run { domainError { try CustomerService.create(draft, in: context) } }
                == .freeLimitReached(operation: "saveCustomer"))
        #expect(DomainState.lapsed.run { domainError { try CustomerService.create(draft, in: context) } }
                == .readOnly(operation: "saveCustomer", lapsed: true))
        #expect(DomainState.offline.run { domainError { try CustomerService.create(draft, in: context) } }
                == .readOnly(operation: "saveCustomer", lapsed: false))
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == FreeTier.customers)

        // Subscribed lifts the cap; sample mode is never capped nor read-only.
        try DomainState.subscribed.run { _ = try CustomerService.create(draft, in: context) }
        try DomainState.sampleOffline.run { _ = try CustomerService.create(draft, in: context) }
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == FreeTier.customers + 2)
    }

    // MARK: Update

    @Test func updateWritesOnlyWhatChangedAndSaves() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()
        let stamp = try #require(customer.updatedAt)

        // Same values → no SwiftData change at all (no history row, no outbox op).
        try DomainState.subscribed.run {
            try CustomerService.update(customer, with: CustomerDraft(customer), in: context)
        }
        #expect(customer.updatedAt == stamp, "an unchanged edit is not a write")

        var edit = CustomerDraft(customer)
        edit.phoneNumber = "(850) 555-0199"
        edit.address.street2 = "Suite 4"
        try DomainState.subscribed.run { try CustomerService.update(customer, with: edit, in: context) }
        #expect(customer.phoneNumber == "(850) 555-0199")
        #expect(customer.address.street2 == "Suite 4")
        #expect(customer.businessName == "Reed General Contracting")
        #expect(customer.updatedAt != stamp)
        #expect(!context.hasChanges)
    }

    @Test func updateKeepsThePhotoUnlessOneIsGiven() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        customer.profileImageData = Data([9])
        context.saveChanges()
        try DomainState.subscribed.run {
            try CustomerService.update(customer, with: CustomerDraft(customer), in: context)
            #expect(customer.profileImageData == Data([9]))
            try CustomerService.update(customer, with: CustomerDraft(customer), photo: Data([7]), in: context)
            #expect(customer.profileImageData == Data([7]))
        }
    }

    @Test func updateRefusals() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        context.saveChanges()
        var blank = CustomerDraft(customer)
        blank.firstName = ""; blank.lastName = ""; blank.businessName = " "
        #expect(DomainState.subscribed.run { domainError { try CustomerService.update(customer, with: blank, in: context) } }
                == .nameRequired)
        #expect(DomainState.lapsed.run {
            domainError { try CustomerService.update(customer, with: CustomerDraft(firstName: "X"), in: context) }
        } == .readOnly(operation: "saveCustomer", lapsed: true))
        #expect(customer.firstName == "Marcus", "a refused edit touches nothing")

        context.deleteSynced(customer)
        context.saveChanges()
        #expect(DomainState.subscribed.run {
            domainError { try CustomerService.update(customer, with: CustomerDraft(firstName: "X"), in: context) }
        } == .recordNotFound)
    }

    // MARK: Photo and certificates

    @Test func photoSetAndRemove() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        try DomainState.subscribed.run {
            try CustomerService.setPhoto(Data([1]), for: customer, in: context)
            #expect(customer.profileImageData == Data([1]))
            #expect(customer.syncID != nil && !context.hasChanges)
            try CustomerService.setPhoto(nil, for: customer, in: context)
            #expect(customer.profileImageData == nil)
        }
        #expect(DomainState.offline.run { domainError { try CustomerService.setPhoto(Data([2]), for: customer, in: context) } }
                == .readOnly(operation: "saveCustomer", lapsed: false))
        #expect(customer.profileImageData == nil)
    }

    @Test func certificatesUploadReplaceRemoveAndExpiry() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        let june = TS.day(2027, 6, 30)
        try DomainState.subscribed.run {
            try DocumentService.set(.customerCertificate(customer, .generalLiability), data: Data([1]), name: "gl.pdf", in: context)
            try DocumentService.set(.customerCertificate(customer, .workersComp), data: Data([2]), name: "wc.pdf", in: context)
            try DocumentService.setExpiry(.customerCertificate(customer, .generalLiability), june, in: context)
            try DocumentService.setExpiry(.customerCertificate(customer, .workersComp), june, in: context)
        }
        #expect(customer.coiData == Data([1]) && customer.coiName == "gl.pdf")
        #expect(customer.wcCoiData == Data([2]) && customer.wcCoiName == "wc.pdf")
        #expect(customer.coiExpiresOn == june && customer.wcCoiExpiresOn == june)
        #expect(!context.hasChanges)

        try DomainState.subscribed.run {
            try DocumentService.set(.customerCertificate(customer, .generalLiability), data: Data([3]), name: "gl2.pdf", in: context)
            try DocumentService.set(.customerCertificate(customer, .workersComp), data: nil, name: "ignored", in: context)
            try DocumentService.setExpiry(.customerCertificate(customer, .generalLiability), nil, in: context)
        }
        #expect(customer.coiData == Data([3]) && customer.coiName == "gl2.pdf")
        #expect(customer.wcCoiData == nil && customer.wcCoiName == "", "removing clears the file name")
        #expect(customer.wcCoiExpiresOn == june, "removing the file leaves its expiry, as the screen always has")
        #expect(customer.coiExpiresOn == nil)
    }

    /// Upload is a save, removal a delete, and the expiry — ungated until 2026-09-21 — a save.
    @Test func certificateWritesUseTheirOwnOperations() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        DomainState.lapsed.run {
            #expect(domainError { try DocumentService.set(.customerCertificate(customer, .generalLiability), data: Data([1]), name: "a", in: context) }
                    == .readOnly(operation: "saveDocument", lapsed: true))
            #expect(domainError { try DocumentService.set(.customerCertificate(customer, .generalLiability), data: nil, name: "", in: context) }
                    == .readOnly(operation: "deleteDocument", lapsed: true))
            #expect(domainError { try DocumentService.setExpiry(.customerCertificate(customer, .workersComp), .now, in: context) }
                    == .readOnly(operation: "saveDocument", lapsed: true))
        }
        #expect(customer.coiData == nil && customer.wcCoiExpiresOn == nil)
    }

    /// Owner ruling 2026-09-26: the New Customer form saves any name — including real clients
    /// whose first or last name is "Mi", "Me" or "Yo" — and only the assistant refuses a name
    /// that is WHOLLY a phrase like "for me" (MBCustomerTool, tested in MBCustomerEstimateToolTests).
    @Test func theFormSavesRealNamesThatLookLikePronouns() throws {
        let context = try DomainFixtures.context()
        DomainState.subscribed.run {
            let real = [
                CustomerDraft(firstName: "Mi", lastName: "Nguyen"),
                CustomerDraft(firstName: "Anna", lastName: "Me"),
                CustomerDraft(firstName: "Yo", lastName: "Tanaka"),
                CustomerDraft(businessName: "Mi Casa Tile")
            ]
            for draft in real {
                #expect(domainError { try CustomerService.create(draft, in: context) } == nil,
                        "\(draft) is a real client and must save")
            }
        }
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 4)
    }

    @Test func onlyAWholeNameThatIsAPhraseIsReserved() {
        let phrases: [(String, String, String?)] = [
            ("for", "me", nil), ("me", "for", nil), ("for, me", "", nil), ("me", "", nil),
            ("myself", "", nil), ("self", "", nil), ("para mi", "", nil), ("Para", "Mí", nil),
            ("yo", "", nil), ("", "", "me"), ("  ME ", "", nil)
        ]
        for (first, last, business) in phrases {
            #expect(CustomerService.isReservedPronounName(first: first, last: last, business: business),
                    "'\(first) \(last) \(business ?? "")' is a phrase, not a client")
        }
        let real: [(String, String, String?)] = [
            ("Mi", "Nguyen", nil), ("Anna", "Me", nil), ("Yo", "Tanaka", nil),
            ("", "", "Mi Casa Tile"), ("Ana", "", "me"), ("", "", nil)
        ]
        for (first, last, business) in real {
            #expect(!CustomerService.isReservedPronounName(first: first, last: last, business: business),
                    "'\(first) \(last) \(business ?? "")' must not be refused")
        }
    }
}
