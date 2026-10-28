//
//  DomainFoundationTests.swift
//  GLSmallBusinessTests — Domain
//
//  The pieces every domain service stands on: the gate (read-only, caps, liveness, values), the
//  money helper, the sync-identity helper, and the refusal type's two halves (EN + ES for the
//  person, a value-free log line for the developer).
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

// MARK: - The gate

@MainActor
@Suite(.serialized)
struct DomainGateTests {

    @Test func writableWhenSubscribedOrNeverSubscribed() throws {
        for state in [DomainState.subscribed, .neverSubscribed] {
            try state.run { try DomainGate.requireWritable(.saveCustomer) }
        }
    }

    @Test func lapsedAndOfflineAreRefusedWithTheirCause() {
        let lapsed = DomainState.lapsed.run { domainError { try DomainGate.requireWritable(.saveCustomer) } }
        #expect(lapsed == .readOnly(operation: "saveCustomer", lapsed: true))
        #expect(lapsed?.code == "read_only_lapsed")

        let offline = DomainState.offline.run { domainError { try DomainGate.requireWritable(.logHours) } }
        #expect(offline == .readOnly(operation: "logHours", lapsed: false))
        #expect(offline?.code == "read_only_offline")
    }

    /// Sample mode is never read-only (law 15) — the same exemption every tap gets.
    @Test func sampleModeIsExemptFromOffline() throws {
        try DomainState.sampleOffline.run { try DomainGate.requireWritable(.recordPaycheck) }
    }

    @Test func createIsCappedForTheFreeTierOnly() throws {
        let context = try DomainFixtures.context()
        for i in 0..<FreeTier.employees { context.insert(Employee(firstName: "E\(i)")) }
        try context.save()

        let atCap = DomainState.neverSubscribed.run {
            domainError {
                try DomainGate.requireCanCreate(Employee.self, cap: FreeTier.employees,
                                                operation: .saveEmployee, in: context)
            }
        }
        #expect(atCap == .freeLimitReached(operation: "saveEmployee"))

        // Subscribed: no cap. No cap given (projects): never capped.
        try DomainState.subscribed.run {
            try DomainGate.requireCanCreate(Employee.self, cap: FreeTier.employees,
                                            operation: .saveEmployee, in: context)
        }
        try DomainState.neverSubscribed.run {
            try DomainGate.requireCanCreate(Employee.self, cap: nil, operation: .saveProject, in: context)
        }
        // Sample mode is never capped.
        try DomainState.sampleOffline.run {
            try DomainGate.requireCanCreate(Employee.self, cap: FreeTier.employees,
                                            operation: .saveEmployee, in: context)
        }
    }

    @Test func createWhileLapsedIsReadOnlyNotTheCap() throws {
        let context = try DomainFixtures.context()
        let error = DomainState.lapsed.run {
            domainError {
                try DomainGate.requireCanCreate(Customer.self, cap: FreeTier.customers,
                                                operation: .saveCustomer, in: context)
            }
        }
        #expect(error == .readOnly(operation: "saveCustomer", lapsed: true))
    }

    @Test func deletedAndUnsavedRecordsAreNotLive() throws {
        let context = try DomainFixtures.context()
        #expect(domainError { try DomainGate.requireLive(Customer(), .saveCustomer) } == .recordNotFound)
        #expect(domainError { try DomainGate.requireLive(nil, .saveCustomer) } == .recordNotFound)

        let customer = TS.customer(in: context)
        try context.save()
        try DomainGate.requireLive(customer, .saveCustomer)
        context.deleteSynced(customer)
        #expect(domainError { try DomainGate.requireLive(customer, .saveCustomer) } == .recordNotFound)
    }

    @Test func valueRules() {
        #expect(domainError { try DomainGate.requireNonNegative(0, 1.5, for: .logHours) } == nil)
        #expect(domainError { try DomainGate.requireNonNegative(1, -0.01, for: .logHours) } == .negativeValue)
        #expect(domainError { try DomainGate.requireNonNegative(.nan, for: .logHours) } == .negativeValue)
        #expect(domainError { try DomainGate.requireNonNegative(.infinity, for: .logHours) } == .negativeValue)
        #expect(domainError { try DomainGate.requirePercent(100, for: .saveInvoice) } == nil)
        #expect(domainError { try DomainGate.requirePercent(100.01, for: .saveInvoice) } == .percentOutOfRange)
        #expect(domainError { try DomainGate.requirePercent(-1, for: .saveInvoice) } == .percentOutOfRange)
    }

    @Test func loggedWorkFollowsTheSheetsSaveRule() {
        let day = TS.day(2026, 9, 1)
        let nine = day.addingTimeInterval(9 * 3600)
        #expect(domainError { try LoggedWork.hours(8, on: day, rate: 25).validate(for: .logHours) } == nil)
        #expect(domainError { try LoggedWork.hours(0, on: day, rate: 25).validate(for: .logHours) } == .hoursAndRateRequired)
        #expect(domainError { try LoggedWork.hours(8, on: day, rate: 0).validate(for: .logHours) } == .hoursAndRateRequired)
        #expect(domainError { try LoggedWork.hours(-8, on: day, rate: 25).validate(for: .logHours) } == .negativeValue)
        #expect(domainError { try LoggedWork.range(start: nine, end: nine, rate: 25).validate(for: .logHours) } == .hoursAndRateRequired)
        #expect(domainError { try LoggedWork.range(start: nine, end: nine.addingTimeInterval(3600), rate: -1).validate(for: .logHours) } == .negativeValue)
        #expect(domainError { try LoggedWork.dollars(0, on: day).validate(for: .logHours) } == .amountRequired)
        #expect(domainError { try LoggedWork.dollars(50, on: day).validate(for: .logHours) } == nil)

        let overnight = LoggedWork.range(start: nine.addingTimeInterval(13 * 3600),
                                         end: nine.addingTimeInterval(21 * 3600), rate: 30)
        #expect(overnight.hours == 8)
        #expect(overnight.date == nine.addingTimeInterval(13 * 3600))
        #expect(LoggedWork.range(start: nine, end: day, rate: 1).hours == 0, "a backwards range is 0 hours, never negative")
    }
}

// MARK: - Money

struct DomainMoneyTests {

    @Test func roundsHalfUpToWholeCents() {
        #expect(DomainMoney.roundedToCents(2.675) == 2.68)
        #expect(DomainMoney.roundedToCents(2.674) == 2.67)
        #expect(DomainMoney.roundedToCents(1.005) == 1.01)
        #expect(DomainMoney.roundedToCents(0.125) == 0.13)
        #expect(DomainMoney.roundedToCents(-1.005) == -1.01)
        #expect(DomainMoney.roundedToCents(1234.5) == 1234.5)
        #expect(DomainMoney.roundedToCents(0.0) == 0)
        #expect(DomainMoney.roundedToCents(.infinity) == .infinity)
    }

    @Test func validationAndClamping() {
        #expect(DomainMoney.isNonNegative(0))
        #expect(!DomainMoney.isNonNegative(-0.001))
        #expect(!DomainMoney.isNonNegative(.nan))
        #expect(DomainMoney.isPercent(100) && !DomainMoney.isPercent(101))
        #expect(DomainMoney.clampedNonNegative(-5) == 0)
        #expect(DomainMoney.clampedNonNegative(.nan) == 0)
        #expect(DomainMoney.clampedNonNegative(12.345) == 12.345, "never re-rounds a valid value")
    }
}

// MARK: - Sync identity

@MainActor
@Suite(.serialized)
struct DomainSyncIdentityTests {

    @Test func mintsAndSavesAnIDOnlyWhenMissing() throws {
        let context = try DomainFixtures.context()
        let customer = TS.customer(in: context)
        try context.save()   // a plain save, like a pre-Phase-0 row: no syncID
        #expect(customer.syncID == nil)

        let minted = try DomainState.subscribed.run { try DomainSyncIdentity.ensure(customer, in: context) }
        #expect(customer.syncID == minted)
        #expect(!context.hasChanges, "the minted id is saved, not left for autosave")

        let again = try DomainState.subscribed.run { try DomainSyncIdentity.ensure(customer, in: context) }
        #expect(again == minted, "an existing id is returned, never replaced")
    }

    /// Read-only (lapsed or offline): the id is minted so the record can be named, but NOT saved —
    /// a save would stamp the row and queue a sync op while nothing may go to the server.
    @Test func mintsButDoesNotSaveWhileReadOnly() throws {
        for state in [DomainState.lapsed, .offline] {
            let context = try DomainFixtures.context()
            let customer = TS.customer(in: context)
            try context.save()
            let minted = try state.run { try DomainSyncIdentity.ensure(customer, in: context) }
            #expect(customer.syncID == minted && customer.updatedAt == nil)
            #expect(context.hasChanges, "left for the next allowed save")
        }
    }

    @Test func refusesARecordNotInAContext() {
        #expect(domainError { _ = try DomainSyncIdentity.ensure(Customer(), in: try DomainFixtures.context()) }
                == .recordNotFound)
    }
}

// MARK: - The refusal's two halves

@MainActor
@Suite(.serialized)
struct DomainErrorTests {

    static let all: [DomainError] = [
        .readOnly(operation: "saveCustomer", lapsed: true), .readOnly(operation: "saveCustomer", lapsed: false),
        .freeLimitReached(operation: "saveCustomer"), .recordNotFound, .nameRequired,
        .personNameRequired, .projectNameRequired, .negativeValue, .percentOutOfRange,
        .amountRequired, .hoursAndRateRequired, .projectBelongsToAnotherCustomer, .paidLocked, .changeOrderLinesReadOnly,
        .titleRequired, .itemRequired, .exceedsBalance, .optionsRequired, .changeOrderNotApproved,
        .customerRequired, .jobBelongsToAnotherCustomer, .receiptDetailsRequired, .itemNameRequired,
        .businessNameRequired, .contactRequired, .invalidHours, .invalidDateRange, .unknownScheduleItem,
        .paymentsCannotBeDeleted, .hasRecordedPayments(customer: false), .hasRecordedPayments(customer: true),
        .tooMuchToDelete, .noExpiry,
    ]

    @Test func everyCaseHasACodeAndEnglishAndSpanishCopy() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }

        // The customer variant shares its invoice twin's code: the server has one reason for both.
        let distinct = Self.all.filter { $0 != .hasRecordedPayments(customer: true) }
        #expect(Set(distinct.map(\.code)).count == distinct.count, "codes are unique")
        #expect(DomainError.hasRecordedPayments(customer: true).code == "has_payments")
        #expect(DomainError.hasRecordedPayments(customer: false).code == "has_payments", "the server's reason")
        #expect(Set(Self.all.map { $0.errorDescription ?? "" }).count == Self.all.count, "every refusal has its own sentence")
        for error in Self.all {
            MBLocalization.shared.language = .en
            let english = error.errorDescription ?? ""
            MBLocalization.shared.language = .es
            let spanish = error.errorDescription ?? ""
            #expect(!english.isEmpty)
            #expect(!spanish.isEmpty && spanish != english, "no Spanish for \(error.code)")
            #expect(!spanish.contains("añadir"), "house Spanish says agregar")
        }
    }

    /// Every message is a catalog key with a translated Spanish value — checked against the file,
    /// so a key that only resolves by falling back to English cannot pass.
    @Test func everyMessageIsInTheCatalog() throws {
        let text = try #require(GLSource.file("Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .en
        for error in Self.all {
            let key = try #require(error.errorDescription)
            let entry = strings[key] as? [String: Any]
            let es = ((entry?["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(es?["state"] as? String == "translated", "missing ES for “\(key)”")
        }
    }

    /// The developer half names the operation and the code — never a value.
    @Test func theRefusalLogLineCarriesNoUserData() throws {
        let source = try #require(GLSource.file("Services/Domain/DomainGate.swift"))
        let lines = source.split(separator: "\n").filter { $0.contains("domain refusal:") }
        #expect(lines.count == 1)
        for line in lines {
            #expect(line.contains("operation=\\(operation.rawValue, privacy: .public)"))
            #expect(line.contains("code=\\(error.code, privacy: .public)"))
            #expect(line.components(separatedBy: "\\(").count == 3, "exactly two interpolations")
        }
    }
}

// MARK: - Every domain write is gated and saved

/// Source scan over Services/Domain: every function that inserts, deletes, writes a field or saves
/// goes through `DomainGate` first and ends in `saveChanges()`. A net for the next service someone
/// adds.
struct DomainWritesAreGatedTests {

    /// Writers whose gate is elsewhere, each for a stated reason.
    static let gatedElsewhere: Set<String> = [
        // Gated per target kind in its private `checked`, before anything is touched.
        "DeletionService.swift delete",
        // Id minting on a READ (the contract allows it); saves only when the app is not read-only.
        "DomainSyncIdentity.swift ensure",
        "PriceSheetService.swift ensureID",
    ]

    @Test func everyWritingFunctionGatesAndSaves() throws {
        let files = GLSource.files(excluding: []).filter { $0.path.hasPrefix("Services/Domain/") }
        #expect(files.count >= 8, "the Domain folder was not read")
        var offenders: [String] = []
        var writers = 0
        for file in files {
            // Public entry points only: `private static func` helpers are reached through them.
            let names = file.text.matches(of: /\n\s+static func (\w+)/).map { String($0.1) }
            for name in Set(names) {
                guard let body = GLSource.functionBody(name, in: file.text) else { continue }
                let writes = body.contains("context.insert(") || body.contains("deleteSynced(")
                    || body.contains("setIfChanged(") || body.contains("saveChanges()")
                guard writes else { continue }
                writers += 1
                let fileName = file.path.split(separator: "/").last.map(String.init) ?? file.path
                if Self.gatedElsewhere.contains("\(fileName) \(name)") { continue }
                if !body.contains("DomainGate.require") { offenders.append("\(file.path) \(name): no gate") }
                if !body.contains("context.saveChanges()") { offenders.append("\(file.path) \(name): no save") }
            }
        }
        #expect(writers >= 20, "only \(writers) writing functions found")
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }
}
