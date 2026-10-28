//
//  MBPickCommit.swift
//  GLSmallBusiness — AI
//
//  Where a picked photo, file, scan or phone contact is SAVED — through the same services the
//  screens' own importers call, so an upload the assistant asked for and one the person tapped in
//  land identically (law 58, Zero Duplication).
//
//  The model never sees what was picked: every outcome here says what kind of thing landed and
//  where, and nothing about its contents.
//

import Foundation
import SwiftData
import Contacts
import UIKit
import UniformTypeIdentifiers
import GoldLifeAI

@MainActor
enum MBPickCommit {

    // MARK: Photos

    /// Picked photos, ALREADY downsampled to JPEG off the main thread by the host
    /// (`ImageDownsampler.intakeJPEG`, 1024 px) — nothing here decodes or redraws an image.
    static func photos(_ photos: [Data], plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        guard let first = photos.first else { return .cancelled(message: "The user didn't pick a photo.") }
        switch plan.target {
        case .jobPhotos, .invoicePhotos:
            guard let owner = attachmentOwner(plan, in: store) else { return .failed(MBHandoffFailure.notAvailable) }
            do {
                let added = try DocumentService.attachPhotos(photos, to: owner, in: store,
                                                             subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": .number(Double(added.count))],
                            MBWriteStrings.photoAdded, detail: nil, plan: plan)
            } catch {
                return failed(error)
            }
        case .customerPhoto, .employeePhoto, .subcontractorPhoto:
            return setPhoto(first, plan: plan, in: store)
        case .businessLogo, .businessLogoDark:
            // Never stored uncropped: the host sends a logo through the crop step, then `logo`.
            return .failed(MBHandoffFailure.documentFailed)
        default:
            // Everything else takes one image as a stored document (the certificate screens' own
            // importers accept an image the same way).
            return file(first, name: "Photo.jpg", plan: plan, in: store)
        }
    }

    /// A logo that came through the crop step (the same `ImageCropView` as My Business
    /// Details), as PNG.
    static func logo(_ png: Data, plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        guard plan.target.isLogo else { return .failed(MBHandoffFailure.notAvailable) }
        do {
            try BusinessProfileService.setLogo(png, dark: plan.target == .businessLogoDark, in: store,
                                               subscription: SubscriptionManager.shared)
            return done(["ok": true, "added": true], MBWriteStrings.logoAdded, detail: nil, plan: plan)
        } catch {
            return failed(error)
        }
    }

    // MARK: Files

    static func file(_ data: Data, name: String, plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        switch plan.target {
        case .newReceipt:
            return newReceipt(data, recognizedText: "", plan: plan, in: store)
        case .receipt:
            guard let receipt = record(.receipt, plan, store, Receipt.self) else {
                return .failed(MBHandoffFailure.notAvailable)
            }
            do {
                try ReceiptService.setScan(data, for: receipt, in: store,
                                           subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.photoAdded,
                            detail: receipt.displayVendor, plan: plan)
            } catch {
                return failed(error)
            }
        case .jobPhotos, .invoicePhotos:
            guard let owner = attachmentOwner(plan, in: store) else { return .failed(MBHandoffFailure.notAvailable) }
            do {
                _ = try DocumentService.attachPhotos([data], to: owner, in: store,
                                                     subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.photoAdded, detail: nil, plan: plan)
            } catch {
                return failed(error)
            }
        case .jobDocuments, .invoiceDocuments:
            guard let owner = attachmentOwner(plan, in: store) else { return .failed(MBHandoffFailure.notAvailable) }
            do {
                _ = try DocumentService.attachDocument(data, name: name, to: owner, in: store,
                                                       subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.fileAdded, detail: name, plan: plan)
            } catch {
                return failed(error)
            }
        case .packageDocuments:
            guard let customer = record(.customer, plan, store, Customer.self) else {
                return .failed(MBHandoffFailure.notAvailable)
            }
            do {
                _ = try DocumentService.addPackageExtra(data, name: name, to: customer, in: store,
                                                        subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.fileAdded, detail: name, plan: plan)
            } catch {
                return failed(error)
            }
        case .customerPhoto, .employeePhoto, .subcontractorPhoto:
            return setPhoto(data, plan: plan, in: store)
        case .businessLogo, .businessLogoDark:
            // Never stored uncropped: a logo file goes through the host's crop step, then `logo`.
            return .failed(MBHandoffFailure.documentFailed)
        case .customerCOI, .customerWCCOI, .subcontractorCOI, .wcExemption, .license, .referenceCOI,
             .projectAgreement:
            guard let slot = documentSlot(plan, in: store) else { return .failed(MBHandoffFailure.notAvailable) }
            do {
                try DocumentService.set(slot, data: data, name: name, in: store,
                                        subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.fileAdded, detail: name, plan: plan)
            } catch {
                return failed(error)
            }
        case .subcontractorW9, .newCustomer, .newEmployee, .newSubcontractor:
            return .failed(MBHandoffFailure.onlyOnScreen)
        }
    }

    // MARK: Scans

    /// A scan read and stitched, ready to save. Built OFF the main thread and without touching
    /// the store, so a request that ends while it is built saves nothing.
    struct ReadScan {
        let data: Data
        let scanned: ScannedReceipt
    }

    /// Every page stitched into one upright image at the fleet's width (the same stitcher the
    /// Receipts list uses), then read once by the on-device OCR. Nil when there is nothing to
    /// stitch or encode.
    static func readScan(_ images: [UIImage]) async -> ReadScan? {
        guard let prepared = await ReceiptScanPages.prepared(images) else { return nil }
        let scanned = await ReceiptService.read(prepared.image)
        return ReadScan(data: prepared.jpeg, scanned: scanned)
    }

    static func commitScan(_ read: ReadScan, plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        switch plan.target {
        case .newReceipt:
            return newReceipt(read.data, recognizedText: read.scanned.recognizedText, scanned: read.scanned,
                              plan: plan, in: store)
        case .receipt:
            guard let receipt = record(.receipt, plan, store, Receipt.self) else {
                return .failed(MBHandoffFailure.notAvailable)
            }
            do {
                try ReceiptService.setScan(read.data, recognizedText: read.scanned.recognizedText, for: receipt,
                                           in: store, subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.scanAdded,
                            detail: receipt.displayVendor, plan: plan)
            } catch {
                return failed(error)
            }
        default:
            return file(read.data, name: "Scan.jpg", plan: plan, in: store)
        }
    }

    /// Read and save in one step (the whole scan is stitched first, so every page lands).
    static func scan(_ images: [UIImage], plan: MBPickPlan, in store: ModelContext) async -> GLAIHandoffOutcome {
        guard let read = await readScan(images) else { return .failed(MBHandoffFailure.documentFailed) }
        return commitScan(read, plan: plan, in: store)
    }

    // MARK: Picked files

    /// A file the person chose, read and (for a picture) shrunk OFF the main thread. A picture
    /// is a JPEG of at most 1024 px on its long edge, the same intake every photo goes through,
    /// so a 4032 px image is never stored full size; any other file keeps its bytes.
    struct PickedFile: Sendable {
        let data: Data
        let isImage: Bool
    }

    nonisolated static func intakeFile(at url: URL) async -> PickedFile? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let raw: Data? = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let raw else { return nil }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        guard isImage else { return PickedFile(data: raw, isImage: false) }
        guard let jpeg = await ImageDownsampler.intakeJPEG(from: raw) else { return nil }
        return PickedFile(data: jpeg, isImage: true)
    }

    // MARK: Contacts

    static func contact(_ contact: CNContact, plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        let draft = ContactsBridge.draft(from: contact)
        do {
            switch plan.target {
            case .newCustomer:
                var customer = CustomerDraft()
                customer.firstName = draft.firstName
                customer.middleName = draft.middleName
                customer.lastName = draft.lastName
                customer.businessName = draft.businessName
                customer.email = draft.email
                customer.phoneNumber = draft.phoneNumber
                customer.officePhone = draft.officePhone
                customer.address = Address(street1: draft.street1,
                                           street2: draft.street2.isEmpty ? nil : draft.street2,
                                           city: draft.city, state: draft.state,
                                           postalCode: draft.postalCode)
                let made = try CustomerService.create(customer, photo: draft.imageData, in: store,
                                                      subscription: SubscriptionManager.shared)
                return created(.customer, MBIDs.id(made, MBToolEnvironment(context: { store })),
                               title: MBWriteStrings.customerAdded, detail: made.listDisplayName,
                               symbol: MBWriteSymbol.customer, in: store)
            case .newEmployee:
                var employee = EmployeeDraft()
                employee.firstName = draft.firstName
                employee.lastName = draft.lastName
                employee.email = draft.email
                employee.phone = draft.phoneNumber
                let made = try EmployeeService.create(employee, photo: draft.imageData, in: store,
                                                      subscription: SubscriptionManager.shared)
                return created(.employee, MBIDs.id(made, MBToolEnvironment(context: { store })),
                               title: MBWriteStrings.employeeAdded, detail: made.fullName,
                               symbol: MBWriteSymbol.employee, in: store)
            case .newSubcontractor:
                var sub = SubcontractorDraft()
                sub.firstName = draft.firstName
                sub.lastName = draft.lastName
                sub.businessName = draft.businessName
                sub.email = draft.email
                sub.phone = draft.phoneNumber
                sub.address = Address(street1: draft.street1,
                                      street2: draft.street2.isEmpty ? nil : draft.street2,
                                      city: draft.city, state: draft.state, postalCode: draft.postalCode)
                let made = try SubcontractorService.create(sub, photo: draft.imageData, in: store,
                                                           subscription: SubscriptionManager.shared)
                return created(.subcontractor, MBIDs.id(made, MBToolEnvironment(context: { store })),
                               title: MBWriteStrings.subcontractorAdded, detail: made.fullName,
                               symbol: MBWriteSymbol.subcontractor, in: store)
            default:
                return .failed(MBHandoffFailure.notAvailable)
            }
        } catch {
            return failed(error)
        }
    }

    // MARK: Helpers

    private static func newReceipt(_ data: Data, recognizedText: String, scanned: ScannedReceipt? = nil,
                                   plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        var draft = ReceiptDraft()
        draft.scanData = data
        draft.recognizedText = recognizedText
        if let scanned {
            _ = ReceiptService.prefill(&draft, from: scanned, keepDate: false)
        }
        do {
            let receipt = try ReceiptService.create(draft, in: store, subscription: SubscriptionManager.shared)
            let env = MBToolEnvironment(context: { store })
            let id = MBIDs.id(receipt, env)
            let ref = MBWrite.ref(.receipt, id)
            let dto = MBRecordDTO(env: env, context: store)
            return GLAIHandoffOutcome(
                output: ["ok": true, "receipt": dto.row(receipt)],
                activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.receipt,
                                        title: MBWriteStrings.receiptAdded,
                                        detail: receipt.displayVendor, record: ref)],
                undo: MBSaveReceiptTool.undoCreate(id, vendor: receipt.displayVendor, env: env))
        } catch {
            return failed(error)
        }
    }

    private static func setPhoto(_ data: Data, plan: MBPickPlan, in store: ModelContext) -> GLAIHandoffOutcome {
        do {
            switch plan.target {
            case .customerPhoto:
                guard let customer = record(.customer, plan, store, Customer.self) else {
                    return .failed(MBHandoffFailure.notAvailable)
                }
                try CustomerService.setPhoto(data, for: customer, in: store,
                                             subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.photoAdded,
                            detail: customer.listDisplayName, plan: plan)
            case .employeePhoto:
                guard let employee = record(.employee, plan, store, Employee.self) else {
                    return .failed(MBHandoffFailure.notAvailable)
                }
                try EmployeeService.setPhoto(data, for: employee, in: store,
                                             subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.photoAdded,
                            detail: employee.fullName, plan: plan)
            default:
                guard let sub = record(.subcontractor, plan, store, Subcontractor.self) else {
                    return .failed(MBHandoffFailure.notAvailable)
                }
                try SubcontractorService.setPhoto(data, for: sub, in: store,
                                                  subscription: SubscriptionManager.shared)
                return done(["ok": true, "added": true], MBWriteStrings.photoAdded,
                            detail: sub.fullName, plan: plan)
            }
        } catch {
            return failed(error)
        }
    }

    private static func attachmentOwner(_ plan: MBPickPlan, in store: ModelContext) -> DocumentService.AttachmentOwner? {
        switch plan.target {
        case .jobPhotos, .jobDocuments:
            return record(.job, plan, store, ScheduledJob.self).map { .job($0) }
        case .invoicePhotos, .invoiceDocuments:
            return record(.invoice, plan, store, Invoice.self).map { .invoice($0) }
        default:
            return nil
        }
    }

    private static func documentSlot(_ plan: MBPickPlan, in store: ModelContext) -> DocumentService.Slot? {
        switch plan.target {
        case .customerCOI:
            return record(.customer, plan, store, Customer.self).map { .customerCertificate($0, .generalLiability) }
        case .customerWCCOI:
            return record(.customer, plan, store, Customer.self).map { .customerCertificate($0, .workersComp) }
        case .subcontractorCOI:
            return record(.subcontractor, plan, store, Subcontractor.self).map { .subcontractorCOI($0) }
        case .wcExemption:
            return .compliance(.wcExemption)
        case .license:
            return .compliance(.license)
        case .referenceCOI:
            return .referenceCOI
        case .projectAgreement:
            return record(.project, plan, store, Project.self).map { .masterAgreement($0) }
        default:
            return nil
        }
    }

    private static func record<T: PersistentModel>(_ kind: MBRecordKind, _ plan: MBPickPlan,
                                                   _ store: ModelContext, _ type: T.Type) -> T? {
        MBRecordLookup.record(kind, id: plan.recordID, as: type, in: store)
    }

    private static func done(_ output: GLAIJSON, _ title: LocalizedStringResource, detail: String?,
                             plan: MBPickPlan) -> GLAIHandoffOutcome {
        let record = plan.target.owner.flatMap { kind in
            plan.recordID.map { GLAIRecordRef(kind: kind.rawValue, id: $0) }
        }
        return GLAIHandoffOutcome(
            output: output,
            activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.document,
                                    title: title, detail: detail, record: record)])
    }

    private static func created(_ kind: MBRecordKind, _ id: String, title: LocalizedStringResource,
                                detail: String, symbol: String, in store: ModelContext) -> GLAIHandoffOutcome {
        GLAIHandoffOutcome(
            output: ["ok": true, "created": true, "kind": .string(kind.rawValue), "id": .string(id)],
            activity: [GLAIActivity(kind: .created, symbol: symbol, title: title, detail: detail,
                                    record: MBWrite.ref(kind, id))])
    }

    private static func failed(_ error: any Error) -> GLAIHandoffOutcome {
        guard let domain = error as? DomainError else {
            return .failed(MBHandoffFailure.documentFailed)
        }
        return .failed(GLAIFailure(reason: domain.code,
                                   message: GLAIStrings.english(domain.personReason),
                                   personReason: domain.personReason))
    }
}
