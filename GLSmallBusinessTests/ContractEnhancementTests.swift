//
//  ContractEnhancementTests.swift
//  GLSmallBusinessTests
//
//  Tests for Contract PDF rendering, Contract message formatting, physical vs status
//  signature distinction, and change order incorporation into contract value.
//

import Testing
import Foundation
import SwiftData
@testable import GLSmallBusiness

@MainActor
struct ContractEnhancementTests {

    @Test func contractPDFRendersSuccessfully() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let profile = BusinessProfile()
        profile.businessName = "Acme Remodeling"
        profile.email = "contact@acme.test"
        profile.phone = "(555) 123-4567"
        ctx.insert(profile)

        let customer = Customer(firstName: "Jason", lastName: "Garcia", businessName: "The Designery")
        customer.email = "jason@designery.test"
        customer.phoneNumber = "8505242206"
        customer.serviceAddress = Address(street1: "1833 Log Ridge Trail", city: "Miami", state: "FL", postalCode: "32312")
        ctx.insert(customer)

        let contract = Contract(
            number: "CON-0002",
            title: "Eppes Kitchen Remodel",
            customerName: customer.listDisplayName,
            customerEmail: customer.email,
            customerPhone: customer.phoneNumber,
            startDate: .now,
            durationDays: 5,
            notes: "Please call before arrival.",
            terms: "Payment due within 14 days of invoice.",
            serviceAddress: customer.serviceAddress,
            status: .draft,
            customer: customer
        )
        contract.agreedPrice = 5000.00
        ctx.insert(contract)

        let group = ContractGroup(name: "Demo & Prep", note: "Cabinet removal", sortIndex: 0)
        group.contract = contract
        ctx.insert(group)

        let item = ContractLineItem(name: "Cabinet Demo", details: "Remove existing upper and lower", quantity: 1, unit: .job, unitPrice: 2000.00, kind: .labor, isTaxable: false, sortIndex: 0)
        item.group = group
        ctx.insert(item)

        // Add approved change order
        let changeOrder = ChangeOrder(number: "CO-0001", title: "Additional electrical box")
        changeOrder.contract = contract
        changeOrder.status = .approved
        ctx.insert(changeOrder)

        let coItem = ChangeOrderLineItem(name: "Add 20A outlet", quantity: 1, unit: .job, unitPrice: 350.00)
        coItem.changeOrder = changeOrder
        ctx.insert(coItem)

        ctx.saveChanges()

        let pdfURL = ContractPDF.render(contract, business: profile)
        #expect(pdfURL != nil)
        if let pdfURL {
            #expect(FileManager.default.fileExists(atPath: pdfURL.path))
            let attr = try? FileManager.default.attributesOfItem(atPath: pdfURL.path)
            let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
            #expect(size > 500)
        }
    }

    @Test func contractMessageFormattingAndSendPreparer() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let profile = BusinessProfile()
        profile.businessName = "Acme Construction"
        profile.email = "info@acme.test"
        profile.phone = "5551234567"
        ctx.insert(profile)

        let customer = Customer(firstName: "Jane", lastName: "Doe")
        customer.email = "jane@example.com"
        customer.phoneNumber = "5559876543"
        ctx.insert(customer)

        let contract = Contract(
            number: "CON-0005",
            title: "Master Bath Renovation",
            customerName: "Jane Doe",
            customerEmail: "jane@example.com",
            customerPhone: "5559876543",
            customer: customer
        )
        contract.agreedPrice = 8500.00
        ctx.insert(contract)
        ctx.saveChanges()

        let subject = ContractMessage.subject(contract: contract, business: profile)
        #expect(subject.contains("Contract CON-0005"))
        #expect(subject.contains("Acme Construction"))

        let plain = ContractMessage.plainBody(contract: contract, business: profile)
        #expect(plain.contains("Jane"))
        #expect(plain.contains("CON-0005"))
        #expect(plain.contains("$8,500.00"))

        let html = ContractMessage.htmlBody(contract: contract, business: profile)
        #expect(html.contains("Jane"))
        #expect(html.contains("CON-0005"))
        #expect(html.contains("Master Bath Renovation"))

        let compose = SendPreparer.contract(contract, business: profile, pdfURL: nil)
        #expect(compose.emailRecipients == ["jane@example.com"])
        #expect(compose.textRecipients == ["5559876543"])
        #expect(compose.subject == subject)
    }

    @Test func physicalVsStatusSignatureDistinction() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let contract = Contract(number: "CON-0010", title: "Roofing Job")
        ctx.insert(contract)

        // Fresh draft
        #expect(!contract.isSigned)
        #expect(!contract.hasPhysicalSignature)

        // Status changed to .signed without signatureData
        contract.status = .signed
        #expect(contract.isSigned, "status is signed")
        #expect(!contract.hasPhysicalSignature, "has no physical signature bitmap or date")

        // Physically signed
        contract.signatureData = Data([0x89, 0x50, 0x4E, 0x47]) // dummy png header
        contract.signedAt = .now
        contract.signerName = "John Client"
        #expect(contract.hasPhysicalSignature)
        #expect(contract.isSigned)
    }

    @Test func changeOrderIncorporationIntoContractValue() throws {
        let container = try TestStore.makeContainer()
        let ctx = container.mainContext

        let contract = Contract(number: "CON-0020", title: "Deck Build")
        contract.agreedPrice = 10000.00
        ctx.insert(contract)

        #expect(contract.contractedValue == 10000.00)

        // Pending change order should NOT increase contractedValue
        let pendingCO = ChangeOrder(number: "CO-0001", title: "Composite decking upgrade")
        pendingCO.contract = contract
        pendingCO.status = .pending
        ctx.insert(pendingCO)

        let i1 = ChangeOrderLineItem(name: "Trex upgrade", quantity: 1, unit: .job, unitPrice: 2500.00)
        i1.changeOrder = pendingCO
        ctx.insert(i1)
        ctx.saveChanges()

        #expect(contract.contractedValue == 10000.00, "Pending change order does not increase contract value")

        // Once approved, contractedValue immediately reflects the change order
        pendingCO.status = .approved
        ctx.saveChanges()

        #expect(contract.contractedValue == 12500.00, "Approved change order is added to contract value")
    }
}
