//
//  MBSettingsTools.swift
//  GLSmallBusiness — AI
//
//  The `settings` area's writes: `update_business`, `update_work_schedule`, `update_app_settings`,
//  `save_project` and `set_document` — through `BusinessProfileService`, `WorkScheduleService`,
//  `AppSettingsService`, `ProjectService`, `DocumentService` and `DeletionService`.
//
//  What is NOT reachable from here, on purpose (contract §5 quarantine):
//    • the business Tax ID, every `w9*` field and the owner's name — `update_business` never reads
//      them, and the model is told to offer to open My Business Details instead;
//    • the Gold Life ID account's own language and appearance, and the security switches (Face ID
//      lock, hide when switching apps) — `update_app_settings` writes only THIS app's four local
//      preferences plus the document/email display switches on the business profile;
//    • a subcontractor's uploaded W-9 — `set_document` has no slot for it.
//

import Foundation
import SwiftData
import GoldLifeAI
import GoldLifeUI

// MARK: - update_business

@MainActor
struct MBUpdateBusinessTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    /// What one confirmed field changes from and to, for the alert's "old → new" line.
    struct FieldChange {
        let label: String
        let before: String
        let after: String
    }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let profile = MBRecordLookup.businessProfile(in: store)
        let details = profile.map { BusinessDetailsDraft($0) } ?? BusinessDetailsDraft()
        let messages = profile.map { DocumentMessagesDraft($0) } ?? DocumentMessagesDraft()

        switch Self.plan(details: details, messages: messages, profile: profile, args: args) {
        case .outcome(let outcome): return outcome
        case .value(let plan):
            guard !plan.confirmations.isEmpty else {
                return Self.apply(plan, env: env, keepUndo: true, before: (details, messages))
            }
            let line = MBWriteStrings.confirmBusinessChanges(
                plan.confirmations.map { "\($0.label): \($0.before.isEmpty ? mbLoc("Not set") : $0.before) → \($0.after.isEmpty ? mbLoc("Not set") : $0.after)" }
                    .joined(separator: "\n"))
            return .needsConfirmation(GLAIConfirmation(
                recordIDs: ["business"],
                line: line,
                actionLabel: MBWriteStrings.confirmContinue,
                isDestructive: false,
                declinedMessage: "The user chose not to change those business details.",
                perform: { [env] in Self.apply(plan, env: env, keepUndo: false, before: (details, messages)) }))
        }
    }

    /// What this call would write, and which of it needs the person's say-so.
    struct Plan {
        var details: BusinessDetailsDraft
        var messages: DocumentMessagesDraft
        var zelleTag: String? = nil
        var zelleEmail: String? = nil
        var zellePhone: String? = nil
        var zelleDefaultOn: Bool? = nil
        var writesDetails = false
        var writesMessages = false
        var writesZelle = false
        var confirmations: [FieldChange] = []
    }

    static func plan(details: BusinessDetailsDraft, messages: DocumentMessagesDraft,
                     profile: BusinessProfile?, args: MBArguments) -> MBStep<Plan> {
        var plan = Plan(details: details, messages: messages)

        func note(_ label: String, _ before: String, _ after: String) {
            guard before.trimmingCharacters(in: .whitespacesAndNewlines)
                    != after.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            plan.confirmations.append(FieldChange(label: label, before: before, after: after))
        }

        if let value = args.json["business_name"]?.stringValue {
            plan.details.businessName = value
            plan.writesDetails = true
        }
        if let value = args.json["phone"]?.stringValue {
            note(mbLoc("Phone"), plan.details.phone, value)
            plan.details.phone = value
            plan.writesDetails = true
        }
        if let value = args.json["email"]?.stringValue {
            note(mbLoc("Email"), plan.details.email, value)
            plan.details.email = value
            plan.writesDetails = true
        }
        if let value = args.json["website_url"]?.stringValue {
            plan.details.websiteURL = value
            plan.writesDetails = true
        }
        if let value = args.json["license_number"]?.stringValue {
            plan.details.licenseNumber = value
            plan.writesDetails = true
        }
        if args.has("address") {
            // A contact detail, and it prints on every estimate, invoice and change order: the
            // person sees old → new before it moves (contract §5).
            let after = MBWriteValue.address(plan.details.address, patch: args.object("address"))
            note(mbLoc("Address"), Self.line(plan.details.address), Self.line(after))
            plan.details.address = after
            plan.writesDetails = true
        }
        if let value = args.json["reviews_url"]?.stringValue {
            note(mbLoc("Reviews link"), plan.messages.reviewsURL, value)
            plan.messages.reviewsURL = value
            plan.details.reviewsURL = value
            plan.writesMessages = true
        }
        if let on = args.bool("review_link_on_receipts") {
            // The review link again, this time whether it goes out at all.
            note(mbLoc("Reviews link on receipts"),
                 Self.switchText(plan.messages.includeReviewLinkOnReceipts), Self.switchText(on))
            plan.messages.includeReviewLinkOnReceipts = on
            plan.writesMessages = true
        }
        if let value = args.json["warranty_text"]?.stringValue {
            // Message-template wording that goes to customers on the completion package.
            note(mbLoc("Warranty text"), plan.messages.warrantyText, value)
            plan.messages.warrantyText = value
            plan.writesMessages = true
        }
        for raw in args.objects("messages") {
            let item = MBArguments(json: raw)
            guard let document = item.string("document") else {
                return .outcome(MBToolFailure.invalid("Every message needs a document."))
            }
            guard let slot = MBMessageSlot(rawValue: document) else {
                return .outcome(MBToolFailure.invalid(
                    "document must be estimate, invoice, receipt, change_order, contractor_package or completion_package."))
            }
            if let subject = item.json["subject"]?.stringValue {
                note("\(slot.label) — \(mbLoc("Subject"))", slot.subject(plan.messages), subject)
                slot.setSubject(&plan.messages, subject)
            }
            if let intro = item.json["intro"]?.stringValue {
                note("\(slot.label) — \(mbLoc("Message"))", slot.intro(plan.messages), intro)
                slot.setIntro(&plan.messages, intro)
            }
            if let closing = item.json["closing"]?.stringValue {
                note("\(slot.label) — \(mbLoc("Closing"))", slot.closing(plan.messages), closing)
                slot.setClosing(&plan.messages, closing)
            }
            plan.writesMessages = true
        }
        if let value = args.json["zelle_tag"]?.stringValue {
            note(mbLoc("Zelle tag"), profile?.zelleTag ?? "", value)
            plan.zelleTag = value
            plan.writesZelle = true
        }
        if let value = args.json["zelle_email"]?.stringValue {
            note(mbLoc("Zelle email"), profile?.zelleEmail ?? "", value)
            plan.zelleEmail = value
            plan.writesZelle = true
        }
        if let value = args.json["zelle_phone"]?.stringValue {
            note(mbLoc("Zelle phone"), profile?.zellePhone ?? "", value)
            plan.zellePhone = value
            plan.writesZelle = true
        }
        if let on = args.bool("zelle_default_on") {
            note(mbLoc("Include Zelle on new invoices"), Self.switchText(profile?.zelleDefaultOn ?? false), Self.switchText(on))
            plan.zelleDefaultOn = on
            plan.writesZelle = true
        }
        guard plan.writesDetails || plan.writesMessages || plan.writesZelle else {
            return .outcome(MBToolFailure.invalid("Send at least one business field to change."))
        }
        return .value(plan)
    }

    /// One line of address, for the alert's old → new (never the multi-line document spelling).
    @MainActor
    static func line(_ address: Address) -> String {
        [address.street1, address.city, address.state, address.postalCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    @MainActor
    static func switchText(_ on: Bool) -> String { on ? mbLoc("On") : mbLoc("Off") }

    static func apply(_ plan: Plan, env: MBToolEnvironment, keepUndo: Bool,
                      before: (BusinessDetailsDraft, DocumentMessagesDraft)) -> GLAIToolOutcome {
        guard let store = env.context() else { return MBToolFailure.unavailable }
        do {
            if plan.writesDetails {
                _ = try BusinessProfileService.updateDetails(plan.details, in: store,
                                                             subscription: env.subscription())
            }
            if plan.writesMessages {
                try BusinessProfileService.updateDocumentMessages(plan.messages, in: store,
                                                                  subscription: env.subscription())
            }
            if plan.writesZelle {
                let currentProfile = MBRecordLookup.businessProfile(in: store)
                let tag = plan.zelleTag ?? currentProfile?.zelleTag ?? ""
                let email = plan.zelleEmail ?? currentProfile?.zelleEmail ?? ""
                let phone = plan.zellePhone ?? currentProfile?.zellePhone ?? ""
                try BusinessProfileService.updateZelleDetails(tag: tag, email: email, phone: phone,
                                                              qrCodeData: currentProfile?.zelleQRCodeData,
                                                              in: store, subscription: env.subscription())
                if let on = plan.zelleDefaultOn {
                    try BusinessProfileService.setZelleDefault(on, in: store, subscription: env.subscription())
                }
            }
        } catch {
            return MBToolFailure.unexpected(error)
        }
        // What the business looks like right after this write: an Undo skips ("changed since")
        // when a hand edit moved it afterwards, instead of putting the old values back over it.
        env.ledger.note(Self.ledgerID, MBFingerprint.business(in: store))
        let undo: GLAIUndo? = keepUndo ? Self.undo(plan, before: before, env: env) : nil
        let dto = MBRecordDTO(env: env, context: store)
        let profile = MBRecordLookup.businessProfile(in: store)
        return .result(["ok": true, "business": .object(dto.business(profile))],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.business,
                                               title: MBWriteStrings.businessUpdated,
                                               detail: profile?.businessName, record: nil)],
                       undo: undo)
    }

    /// The business is one record; its Undo entry and its ledger stamp share this id.
    static let ledgerID = "business"

    static func undo(_ plan: Plan, before: (BusinessDetailsDraft, DocumentMessagesDraft),
                     env: MBToolEnvironment) -> GLAIUndo {
        let ref = GLAIRecordRef(kind: MBRecordKind.business.rawValue, id: ledgerID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitleBusiness, ledger: env.ledger,
                            fingerprint: { env.context().map { MBFingerprint.business(in: $0) } }) {
            guard let store = env.context() else { return MBUndo.recordGone }
            do {
                if plan.writesDetails {
                    _ = try BusinessProfileService.updateDetails(before.0, in: store,
                                                                 subscription: env.subscription())
                }
                if plan.writesMessages {
                    try BusinessProfileService.updateDocumentMessages(before.1, in: store,
                                                                      subscription: env.subscription())
                }
            } catch {
                return MBWrite.revertFailure(error)
            }
            // Put back, so an older entry in the same conversation can still be undone in turn.
            env.ledger.note(ledgerID, MBFingerprint.business(in: store))
            return MBUndo.reverted(.updated, MBWriteSymbol.business, MBWriteStrings.businessRestored,
                                   detail: nil, record: nil)
        }
    }
}

/// The six per-document message slots `update_business` can reword.
enum MBMessageSlot: String, CaseIterable {
    case estimate, invoice, receipt
    case changeOrder = "change_order"
    case contractorPackage = "contractor_package"
    case completionPackage = "completion_package"

    @MainActor
    var label: String {
        switch self {
        case .estimate: return mbLoc("Estimate")
        case .invoice: return mbLoc("Invoice")
        case .receipt: return mbLoc("Payment Receipt")
        case .changeOrder: return mbLoc("Change Order")
        case .contractorPackage: return mbLoc("Contractor Package")
        case .completionPackage: return mbLoc("Completion Package")
        }
    }

    func subject(_ d: DocumentMessagesDraft) -> String {
        switch self {
        case .estimate: return d.estimateSubject
        case .invoice: return d.invoiceSubject
        case .receipt: return d.receiptSubject
        case .changeOrder: return d.changeOrderSubject
        case .contractorPackage: return d.packageSubject
        case .completionPackage: return d.completionSubject
        }
    }

    func intro(_ d: DocumentMessagesDraft) -> String {
        switch self {
        case .estimate: return d.estimateIntro
        case .invoice: return d.invoiceIntro
        case .receipt: return d.receiptIntro
        case .changeOrder: return d.changeOrderIntro
        case .contractorPackage: return d.packageIntro
        case .completionPackage: return d.completionIntro
        }
    }

    func closing(_ d: DocumentMessagesDraft) -> String {
        switch self {
        case .estimate: return d.estimateClosing
        case .invoice: return d.invoiceClosing
        case .receipt: return d.receiptClosing
        case .changeOrder: return d.changeOrderClosing
        case .contractorPackage: return d.packageClosing
        case .completionPackage: return d.completionClosing
        }
    }

    func setSubject(_ d: inout DocumentMessagesDraft, _ value: String) {
        switch self {
        case .estimate: d.estimateSubject = value
        case .invoice: d.invoiceSubject = value
        case .receipt: d.receiptSubject = value
        case .changeOrder: d.changeOrderSubject = value
        case .contractorPackage: d.packageSubject = value
        case .completionPackage: d.completionSubject = value
        }
    }

    func setIntro(_ d: inout DocumentMessagesDraft, _ value: String) {
        switch self {
        case .estimate: d.estimateIntro = value
        case .invoice: d.invoiceIntro = value
        case .receipt: d.receiptIntro = value
        case .changeOrder: d.changeOrderIntro = value
        case .contractorPackage: d.packageIntro = value
        case .completionPackage: d.completionIntro = value
        }
    }

    func setClosing(_ d: inout DocumentMessagesDraft, _ value: String) {
        switch self {
        case .estimate: d.estimateClosing = value
        case .invoice: d.invoiceClosing = value
        case .receipt: d.receiptClosing = value
        case .changeOrder: d.changeOrderClosing = value
        case .contractorPackage: d.packageClosing = value
        case .completionPackage: d.completionClosing = value
        }
    }
}

// MARK: - update_work_schedule

@MainActor
struct MBUpdateWorkScheduleTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        let before = WorkScheduleService.current(in: store, legacyMask: env.legacyMask())
        var changes = 0

        do {
            for raw in args.objects("weekdays") {
                let item = MBArguments(json: raw)
                guard let day = item.string("day"), let index = Self.weekdayNames.firstIndex(of: day) else {
                    return MBToolFailure.invalid("day must be a weekday name, sunday through saturday.")
                }
                let current = WorkScheduleService.current(in: store, legacyMask: env.legacyMask())
                let works = item.bool("works") ?? current.weekdayHours[index].isWorkday
                let start = Self.minutes(item.string("start"))
                let end = Self.minutes(item.string("end"))
                if item.has("start"), start == nil { return MBToolFailure.invalid("start must be HH:mm, 24-hour.") }
                if item.has("end"), end == nil { return MBToolFailure.invalid("end must be HH:mm, 24-hour.") }
                _ = try WorkScheduleService.setWeekday(index, isWorkday: works, startMinutes: start,
                                                       endMinutes: end, in: store,
                                                       subscription: env.subscription())
                changes += 1
            }
            for raw in args.objects("holidays") {
                let item = MBArguments(json: raw)
                guard let id = item.string("id"), let off = item.bool("off") else {
                    return MBToolFailure.invalid("Every holiday needs an id and off.")
                }
                _ = try WorkScheduleService.setHoliday(id, enabled: off, in: store,
                                                       subscription: env.subscription())
                changes += 1
            }
            for raw in args.objects("add_time_off") {
                let item = MBArguments(json: raw)
                guard let start = value.parseDay(item.string("start")),
                      let end = value.parseDay(item.string("end")) else {
                    return MBToolFailure.invalid("Time off needs start and end as days, YYYY-MM-DD.")
                }
                _ = try WorkScheduleService.addTimeOff(from: start, through: end, in: store,
                                                       calendar: env.calendar,
                                                       subscription: env.subscription())
                changes += 1
            }
            for raw in args.objects("add_days_off") {
                let item = MBArguments(json: raw)
                guard let date = value.parseDay(item.string("date")) else {
                    return MBToolFailure.invalid("A day off needs a date, YYYY-MM-DD.")
                }
                _ = try WorkScheduleService.addDayOff(date, label: item.string("label") ?? "",
                                                      repeatsYearly: item.bool("repeats_yearly") ?? false,
                                                      in: store, calendar: env.calendar,
                                                      subscription: env.subscription())
                changes += 1
            }
            for raw in args.objects("add_overrides") {
                let item = MBArguments(json: raw)
                guard let date = value.parseDay(item.string("date")) else {
                    return MBToolFailure.invalid("An override needs a date, YYYY-MM-DD.")
                }
                let kind: DateOverrideKind
                switch item.string("kind") {
                case "day_off":
                    kind = .blocked
                case "custom_hours":
                    guard let start = Self.minutes(item.string("start")),
                          let end = Self.minutes(item.string("end")) else {
                        return MBToolFailure.invalid("custom_hours needs start and end as HH:mm, 24-hour.")
                    }
                    kind = .customHours(startMinutes: start, endMinutes: end)
                default:
                    return MBToolFailure.invalid("kind must be day_off or custom_hours.")
                }
                _ = try WorkScheduleService.addOverride(date, kind: kind, in: store, calendar: env.calendar,
                                                        subscription: env.subscription())
                changes += 1
            }
            for id in args.strings("remove_ids") {
                guard let uuid = MBIDs.uuid(id) else {
                    return MBToolFailure.domain(.unknownScheduleItem)
                }
                _ = try WorkScheduleService.removeEntry(uuid, in: store, subscription: env.subscription())
                changes += 1
            }
        } catch {
            return MBToolFailure.unexpected(error)
        }

        guard changes > 0 else {
            return MBToolFailure.invalid("Send at least one change to the work schedule.")
        }
        let after = WorkScheduleService.current(in: store, legacyMask: env.legacyMask())
        env.ledger.note(Self.ledgerID, MBFingerprint.workSchedule(after))
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "work_schedule": .object(dto.workSchedule(after))],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.hours,
                                               title: MBWriteStrings.workScheduleUpdated, record: nil)],
                       undo: Self.undo(before, env: env))
    }

    /// `HH:mm`, 24-hour → minutes after midnight.
    static func minutes(_ text: String?) -> Int? {
        guard let text, text.count == 5 else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        let total = hour * 60 + minute
        return total <= WorkSchedule.minutesPerDay ? total : nil
    }

    static let ledgerID = "work_schedule"

    static func undo(_ before: WorkSchedule, env: MBToolEnvironment) -> GLAIUndo {
        let ref = GLAIRecordRef(kind: MBRecordKind.workSchedule.rawValue, id: ledgerID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitleWorkSchedule, ledger: env.ledger,
                            fingerprint: {
                                env.context().map {
                                    MBFingerprint.workSchedule(WorkScheduleService.current(in: $0, legacyMask: env.legacyMask()))
                                }
                            }) {
            guard let store = env.context() else { return MBUndo.recordGone }
            do {
                try WorkScheduleService.save(before, in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(ledgerID, MBFingerprint.workSchedule(
                WorkScheduleService.current(in: store, legacyMask: env.legacyMask())))
            return MBUndo.reverted(.updated, MBWriteSymbol.hours, MBWriteStrings.workScheduleRestored,
                                   detail: nil, record: nil)
        }
    }
}

// MARK: - update_app_settings

@MainActor
struct MBUpdateAppSettingsTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    /// One setting this tool can touch. A call writes — and its Undo puts back — only the ones it
    /// was actually asked for: there is no `updatedAt` stamp on a preference to compare against, so
    /// restoring the whole snapshot would silently roll back a switch the person flipped by hand in
    /// Settings between the write and the Undo.
    enum Field: CaseIterable {
        case language, appearance, oneJobAtATime, logoInApp, logoOnDocuments, logoInEmails
        case addressOnDocuments, emailExtraLine, payButton
    }

    /// Everything one call can change, so Undo puts back exactly what it found.
    struct Snapshot {
        var language: MBLanguagePref
        var appearance: AppearancePref
        var oneJobAtATime: Bool
        var useCompanyLogo: Bool
        var logoOnDocuments: Bool
        var emailSignature: Bool
        var addressOnDocuments: Bool
        var emailExtraLine: String
        var payButtonByDefault: Bool

        @MainActor
        init(_ profile: BusinessProfile?) {
            language = AppSettingsService.language
            appearance = AppSettingsService.appearance
            oneJobAtATime = AppSettingsService.oneJobAtATime()
            useCompanyLogo = AppSettingsService.useCompanyLogo()
            logoOnDocuments = profile?.showLogoOnDocuments ?? true
            emailSignature = profile?.emailSignatureEnabled ?? true
            addressOnDocuments = profile?.showAddressOnDocuments ?? true
            emailExtraLine = profile?.emailSignatureText ?? ""
            // The model's own default (BusinessProfile.payLinkDefaultOn = true), so a snapshot
            // taken before the singleton exists can't hand Undo a `false` that never was.
            payButtonByDefault = profile?.payLinkDefaultOn ?? true
        }

        /// The values of just `fields`, as one comparable line.
        func stamp(_ fields: Set<Field>) -> String {
            Field.allCases.filter { fields.contains($0) }.map { field -> String in
                switch field {
                case .language: return "\(language)"
                case .appearance: return "\(appearance)"
                case .oneJobAtATime: return "\(oneJobAtATime)"
                case .logoInApp: return "\(useCompanyLogo)"
                case .logoOnDocuments: return "\(logoOnDocuments)"
                case .logoInEmails: return "\(emailSignature)"
                case .addressOnDocuments: return "\(addressOnDocuments)"
                case .emailExtraLine: return emailExtraLine
                case .payButton: return "\(payButtonByDefault)"
                }
            }.joined(separator: "|")
        }
    }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let before = Snapshot(MBRecordLookup.businessProfile(in: store))
        var after = before
        var fields: Set<Field> = []

        if args.has("language") {
            guard let pref = args.raw("language", MBLanguagePref.self) else {
                return MBToolFailure.invalid("language must be goldLife, system, en or es.")
            }
            after.language = pref
            fields.insert(.language)
        }
        if args.has("appearance") {
            guard let pref = args.raw("appearance", AppearancePref.self) else {
                return MBToolFailure.invalid("appearance must be goldLife, system, light or dark.")
            }
            after.appearance = pref
            fields.insert(.appearance)
        }
        if let on = args.bool("book_one_job_at_a_time") { after.oneJobAtATime = on; fields.insert(.oneJobAtATime) }
        if let on = args.bool("logo_in_app") { after.useCompanyLogo = on; fields.insert(.logoInApp) }
        if let on = args.bool("logo_on_documents") { after.logoOnDocuments = on; fields.insert(.logoOnDocuments) }
        if let on = args.bool("logo_in_emails") { after.emailSignature = on; fields.insert(.logoInEmails) }
        if let on = args.bool("address_on_documents") {
            after.addressOnDocuments = on
            fields.insert(.addressOnDocuments)
        }
        if let text = args.json["email_extra_line"]?.stringValue {
            after.emailExtraLine = text
            fields.insert(.emailExtraLine)
        }
        if let on = args.bool("pay_button_by_default") { after.payButtonByDefault = on; fields.insert(.payButton) }

        guard !fields.isEmpty else { return MBToolFailure.invalid("Send at least one setting to change.") }
        let outcome = Self.write(after, fields: fields, env: env)
        if case .failure = outcome { return outcome }
        // What the written settings read right now: Undo skips if one of THEM was changed by hand
        // afterwards, and still runs when the person only touched a setting this call never wrote.
        let written = Snapshot(MBRecordLookup.businessProfile(in: store)).stamp(fields)
        let dto = MBRecordDTO(env: env, context: store)
        return .result(["ok": true, "app_settings": .object(dto.appSettings(MBRecordLookup.businessProfile(in: store)))],
                       activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.settings,
                                               title: MBWriteStrings.appSettingsUpdated, record: nil)],
                       undo: Self.undo(before, fields: fields, writtenStamp: written, env: env))
    }

    /// The four local preferences go through `AppSettingsService`; the five document/email
    /// switches are business-profile writes, gated as `.saveAppSettings`. Only the `fields` this
    /// call named are written — everything else is left exactly as the person has it.
    static func write(_ values: Snapshot, fields: Set<Field>, env: MBToolEnvironment) -> GLAIToolOutcome {
        guard let store = env.context() else { return MBToolFailure.unavailable }
        do {
            if fields.contains(.logoOnDocuments) {
                try BusinessProfileService.setDisplay(.logoOnDocuments, values.logoOnDocuments, in: store,
                                                      subscription: env.subscription())
            }
            if fields.contains(.logoInEmails) {
                try BusinessProfileService.setDisplay(.emailSignature, values.emailSignature, in: store,
                                                      subscription: env.subscription())
            }
            if fields.contains(.addressOnDocuments) {
                try BusinessProfileService.setDisplay(.addressOnDocuments, values.addressOnDocuments, in: store,
                                                      subscription: env.subscription())
            }
            if fields.contains(.emailExtraLine) {
                try BusinessProfileService.setEmailSignatureText(values.emailExtraLine, in: store,
                                                                 subscription: env.subscription())
            }
            if fields.contains(.payButton) {
                try BusinessProfileService.setPayLinkDefault(values.payButtonByDefault, in: store,
                                                             subscription: env.subscription())
            }
        } catch {
            return MBToolFailure.unexpected(error)
        }
        if fields.contains(.language) { AppSettingsService.setLanguage(values.language) }
        if fields.contains(.appearance) { AppSettingsService.setAppearance(values.appearance) }
        if fields.contains(.oneJobAtATime) { AppSettingsService.setOneJobAtATime(values.oneJobAtATime) }
        if fields.contains(.logoInApp) { AppSettingsService.setUseCompanyLogo(values.useCompanyLogo) }
        return .result(["ok": true])
    }

    static func undo(_ before: Snapshot, fields: Set<Field>, writtenStamp: String,
                     env: MBToolEnvironment) -> GLAIUndo {
        let ref = GLAIRecordRef(kind: MBRecordKind.appSettings.rawValue, id: "app_settings")
        return GLAIUndo(record: ref, title: MBWriteStrings.undoTitleAppSettings, dropReason: { nil },
                        changedSince: {
                            guard let store = env.context() else { return true }
                            return Snapshot(MBRecordLookup.businessProfile(in: store)).stamp(fields) != writtenStamp
                        }) {
            guard env.context() != nil else { return MBUndo.recordGone }
            if case .failure = write(before, fields: fields, env: env) { return .failed(GLAIStrings.errorGeneric) }
            return MBUndo.reverted(.updated, MBWriteSymbol.settings, MBWriteStrings.appSettingsRestored,
                                   detail: nil, record: nil)
        }
    }
}

// MARK: - save_project

@MainActor
struct MBSaveProjectTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let dto = MBRecordDTO(env: env, context: store)
        let adds = args.strings("add_job_ids")
        let removes = args.strings("remove_job_ids")

        if let id = args.string("id") {
            guard let project = MBRecordLookup.record(.project, id: id, as: Project.self, in: store) else {
                return MBToolFailure.notFound(.project)
            }
            let recordID = MBIDs.id(project, env)
            let ref = MBWrite.ref(.project, recordID)
            let beforeName = project.name
            let beforeJobs = project.sortedJobs.map { MBIDs.id($0, env) }
            do {
                if let name = args.string("name"), name != project.name {
                    try ProjectService.rename(project, to: name, in: store, subscription: env.subscription())
                }
                for jobID in adds {
                    guard let job = MBRecordLookup.record(.job, id: jobID, as: ScheduledJob.self, in: store) else {
                        return MBToolFailure.notFound(.job)
                    }
                    try ProjectService.assign(job, to: project, in: store, subscription: env.subscription())
                }
                for jobID in removes {
                    guard let job = MBRecordLookup.record(.job, id: jobID, as: ScheduledJob.self, in: store) else {
                        return MBToolFailure.notFound(.job)
                    }
                    try ProjectService.assign(job, to: nil, in: store, subscription: env.subscription())
                }
            } catch {
                return MBToolFailure.unexpected(error, ref)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(project))
            return .result(["ok": true, "project": dto.row(project)],
                           activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.project,
                                                   title: MBWriteStrings.projectUpdated,
                                                   detail: project.displayName, record: ref)],
                           undo: Self.undoEdit(recordID, name: beforeName, jobIDs: beforeJobs, env: env))
        }

        guard let name = args.string("name") else { return MBToolFailure.domain(.projectNameRequired) }
        // A project is made around a job (the Add to Project sheet's rule): the first job named,
        // else the customer's own — the service takes the customer from that job.
        guard let seedID = adds.first,
              let seed = MBRecordLookup.record(.job, id: seedID, as: ScheduledJob.self, in: store) else {
            return .failure(GLAIFailure(
                reason: "job_required",
                message: "A project is made around a job. Ask which job starts it, then call save_project with that job in add_job_ids.",
                personReason: MBWriteStrings.projectNeedsJob))
        }
        if let customerID = args.string("customer_id"),
           let customer = MBRecordLookup.record(.customer, id: customerID, as: Customer.self, in: store),
           seed.customer?.persistentModelID != customer.persistentModelID {
            return MBToolFailure.domain(.projectBelongsToAnotherCustomer)
        }
        let project: Project
        do {
            project = try ProjectService.createAndAssign(name: name, to: seed, in: store,
                                                         subscription: env.subscription())
            for jobID in adds.dropFirst() {
                guard let job = MBRecordLookup.record(.job, id: jobID, as: ScheduledJob.self, in: store) else {
                    return MBToolFailure.notFound(.job)
                }
                try ProjectService.assign(job, to: project, in: store, subscription: env.subscription())
            }
        } catch {
            return MBToolFailure.unexpected(error)
        }
        let recordID = MBIDs.id(project, env)
        let ref = MBWrite.ref(.project, recordID)
        env.ledger.note(recordID, MBFingerprint.stamp(project))
        return .result(["ok": true, "project": dto.row(project)],
                       activity: [GLAIActivity(kind: .created, symbol: MBWriteSymbol.project,
                                               title: MBWriteStrings.projectCreated,
                                               detail: project.displayName, record: ref)],
                       undo: Self.undoCreate(recordID, name: project.displayName, env: env))
    }

    static func project(_ recordID: String, _ env: MBToolEnvironment) -> Project? {
        guard let store = env.context() else { return nil }
        return MBRecordLookup.record(.project, id: recordID, as: Project.self, in: store)
    }

    static func undoCreate(_ recordID: String, name: String, env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.project, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(project: name), ledger: env.ledger,
                            fingerprint: { project(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let found = project(recordID, env) else { return MBUndo.recordGone }
            let label = found.displayName
            do {
                // Deleting a project keeps its jobs (DeletionService's rule).
                try DeletionService.delete([.project(found)], in: store, subscription: env.subscription())
            } catch {
                return MBWrite.revertFailure(error)
            }
            return MBUndo.reverted(.deleted, MBWriteSymbol.project, MBWriteStrings.deleted(.project),
                                   detail: label, record: nil)
        }
    }

    static func undoEdit(_ recordID: String, name: String, jobIDs: [String],
                         env: MBToolEnvironment) -> GLAIUndo {
        let ref = MBWrite.ref(.project, recordID)
        return MBUndo.entry(ref, title: MBWriteStrings.undoTitle(project: name), ledger: env.ledger,
                            fingerprint: { project(recordID, env).map(MBFingerprint.stamp) }) {
            guard let store = env.context(), let found = project(recordID, env) else { return MBUndo.recordGone }
            let wanted = Set(jobIDs)
            do {
                if found.name != name { try ProjectService.rename(found, to: name, in: store,
                                                                  subscription: env.subscription()) }
                for job in found.sortedJobs where !wanted.contains(MBIDs.id(job, env)) {
                    try ProjectService.assign(job, to: nil, in: store, subscription: env.subscription())
                }
                for id in jobIDs {
                    guard let job = MBRecordLookup.record(.job, id: id, as: ScheduledJob.self, in: store),
                          job.project?.persistentModelID != found.persistentModelID else { continue }
                    try ProjectService.assign(job, to: found, in: store, subscription: env.subscription())
                }
            } catch {
                return MBWrite.revertFailure(error)
            }
            env.ledger.note(recordID, MBFingerprint.stamp(found))
            return MBUndo.reverted(.updated, MBWriteSymbol.project, MBWriteStrings.projectRestored,
                                   detail: found.displayName, record: ref)
        }
    }
}

// MARK: - set_document

@MainActor
struct MBSetDocumentTool: GLAITool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        let value = MBValue(calendar: env.calendar)
        guard let documentName = args.string("document"),
              let document = MBDocumentSlot(rawValue: documentName) else {
            return MBToolFailure.invalid("document must be one of the listed documents.")
        }
        guard let action = args.string("action") else { return MBToolFailure.invalid("action is required.") }
        let id = args.string("id")

        switch action {
        case "set_expiry", "clear_expiry":
            guard document.hasExpiry else { return MBToolFailure.domain(.noExpiry) }
            var date: Date?
            if action == "set_expiry" {
                guard let parsed = value.parseDay(args.string("expires_on")) else {
                    return MBToolFailure.invalid("expires_on must be a day, YYYY-MM-DD.")
                }
                date = parsed
            }
            switch document.slot(id: id, env: env, store: store) {
            case .outcome(let outcome): return outcome
            case .value(let slot):
                do {
                    try DocumentService.setExpiry(slot, date, in: store, subscription: env.subscription())
                } catch {
                    return MBToolFailure.unexpected(error)
                }
                return .result(["ok": true, "document": .string(document.rawValue),
                                "expires_on": date.map { value.day($0) } ?? .null],
                               activity: [GLAIActivity(kind: .updated, symbol: MBWriteSymbol.document,
                                                       title: MBWriteStrings.documentUpdated,
                                                       detail: document.label, record: nil)])
            }
        case "remove":
            // Photos and logos are removed here too — the manifest promises it ("remove a stored
            // document, photo or logo"; found 2026-09-29 refusing). A delete, so it asks first
            // (law 58), through the same service the record's screen uses.
            if document.isMedia {
                return removeMedia(document, id: id, store: store)
            }
            switch document.slot(id: id, env: env, store: store) {
            case .outcome(let outcome): return outcome
            case .value(let slot):
                let label = document.label
                return .needsConfirmation(GLAIConfirmation(
                    recordIDs: [id ?? document.rawValue],
                    line: MBWriteStrings.confirmRemoveDocument(label),
                    actionLabel: MBWriteStrings.confirmDeleteAction,
                    isDestructive: true,
                    declinedMessage: "The user chose not to remove \(document.rawValue).",
                    perform: { [env] in
                        guard let store = env.context() else { return MBToolFailure.unavailable }
                        do {
                            try DocumentService.set(slot, data: nil, name: "", in: store,
                                                    subscription: env.subscription())
                        } catch {
                            return MBToolFailure.unexpected(error)
                        }
                        return .result(["ok": true, "removed": true, "document": .string(document.rawValue)],
                                       activity: [GLAIActivity(kind: .deleted, symbol: MBWriteSymbol.document,
                                                               title: MBWriteStrings.documentRemoved,
                                                               detail: label, record: nil)])
                    }))
            }
        default:
            return MBToolFailure.invalid("action must be set_expiry, clear_expiry or remove.")
        }
    }

    /// Removes a logo or a person's photo, after the person confirms. Nothing on file → says so,
    /// no confirmation raised.
    private func removeMedia(_ document: MBDocumentSlot, id: String?, store: ModelContext) -> GLAIToolOutcome {
        let remove: @MainActor @Sendable (ModelContext) throws -> Void
        let record: GLAIRecordRef?
        let hasOne: Bool
        switch document {
        case .businessLogo, .businessLogoDark:
            let dark = document == .businessLogoDark
            let profile = MBRecordLookup.businessProfile(in: store)
            hasOne = (dark ? profile?.logoDataDark : profile?.logoData) != nil
            record = nil
            remove = { [env] store in
                try BusinessProfileService.setLogo(nil, dark: dark, in: store, subscription: env.subscription())
            }
        case .customerPhoto:
            guard let id, let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return MBToolFailure.notFound(.customer)
            }
            hasOne = customer.profileImageData != nil
            record = GLAIRecordRef(kind: MBRecordKind.customer.rawValue, id: id)
            remove = { [env] store in
                try CustomerService.setPhoto(nil, for: customer, in: store, subscription: env.subscription())
            }
        case .employeePhoto:
            guard let id, let employee = MBRecordLookup.record(.employee, id: id, as: Employee.self, in: store) else {
                return MBToolFailure.notFound(.employee)
            }
            hasOne = employee.profileImageData != nil
            record = GLAIRecordRef(kind: MBRecordKind.employee.rawValue, id: id)
            remove = { [env] store in
                try EmployeeService.setPhoto(nil, for: employee, in: store, subscription: env.subscription())
            }
        case .subcontractorPhoto:
            guard let id, let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
                return MBToolFailure.notFound(.subcontractor)
            }
            hasOne = sub.profileImageData != nil
            record = GLAIRecordRef(kind: MBRecordKind.subcontractor.rawValue, id: id)
            remove = { [env] store in
                try SubcontractorService.setPhoto(nil, for: sub, in: store, subscription: env.subscription())
            }
        default:
            return MBToolFailure.invalid("document must be a photo or a logo.")
        }
        guard hasOne else {
            return .failure(GLAIFailure(reason: "not_on_file",
                                        message: "There is no \(document.rawValue) on file, so there is nothing to remove.",
                                        personReason: MBWriteStrings.documentNotOnFile))
        }
        let label = document.label
        return .needsConfirmation(GLAIConfirmation(
            recordIDs: [id ?? document.rawValue],
            line: MBWriteStrings.confirmRemoveDocument(label),
            actionLabel: MBWriteStrings.confirmDeleteAction,
            isDestructive: true,
            declinedMessage: "The user chose not to remove \(document.rawValue).",
            perform: { [env] in
                guard let store = env.context() else { return MBToolFailure.unavailable }
                do {
                    try remove(store)
                } catch {
                    return MBToolFailure.unexpected(error)
                }
                return .result(["ok": true, "removed": true, "document": .string(document.rawValue)],
                               activity: [GLAIActivity(kind: .deleted, symbol: MBWriteSymbol.document,
                                                       title: MBWriteStrings.documentRemoved,
                                                       detail: label, record: record)])
            }))
    }
}

/// The `set_document` slots, spelled exactly as the manifest spells them.
enum MBDocumentSlot: String, CaseIterable {
    case customerCOI = "customer_coi"
    case customerWCCOI = "customer_wc_coi"
    case subcontractorCOI = "subcontractor_coi"
    case subcontractorW9 = "subcontractor_w9"
    case wcExemption = "wc_exemption"
    case license
    case packageDocument = "package_document"
    case projectAgreement = "project_agreement"
    case jobDocument = "job_document"
    case invoiceDocument = "invoice_document"
    case businessLogo = "business_logo"
    case businessLogoDark = "business_logo_dark"
    case customerPhoto = "customer_photo"
    case employeePhoto = "employee_photo"
    case subcontractorPhoto = "subcontractor_photo"

    /// A logo or a person's photo: removed through its own service (`removeMedia`), never a
    /// `DocumentService` slot.
    var isMedia: Bool {
        switch self {
        case .businessLogo, .businessLogoDark, .customerPhoto, .employeePhoto, .subcontractorPhoto: return true
        default: return false
        }
    }

    var hasExpiry: Bool {
        switch self {
        case .customerCOI, .customerWCCOI, .subcontractorCOI, .wcExemption, .license: return true
        default: return false
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .customerCOI: return mbLoc("Certificate of Insurance")
        case .customerWCCOI: return mbLoc("Workers’ Comp Certificate")
        case .subcontractorCOI: return mbLoc("Subcontractor Certificate of Insurance")
        case .subcontractorW9: return mbLoc("Subcontractor W-9")
        case .wcExemption: return mbLoc("Workers’ Comp Exemption")
        case .license: return mbLoc("Contractor License")
        case .packageDocument: return mbLoc("Package document")
        case .projectAgreement: return mbLoc("Project agreement")
        case .jobDocument: return mbLoc("Job document")
        case .invoiceDocument: return mbLoc("Invoice document")
        case .businessLogo: return mbLoc("Logo")
        case .businessLogoDark: return mbLoc("Dark mode logo")
        case .customerPhoto: return mbLoc("Customer photo")
        case .employeePhoto: return mbLoc("Employee photo")
        case .subcontractorPhoto: return mbLoc("Subcontractor photo")
        }
    }

    /// The `DocumentService.Slot` this names, or the refusal that stops the call. The photo, logo
    /// and W-9 slots are NOT `DocumentService` slots — they go through their own doors, so they
    /// answer with a refusal that names the right tool.
    @MainActor
    func slot(id: String?, env: MBToolEnvironment, store: ModelContext) -> MBStep<DocumentService.Slot> {
        switch self {
        case .customerCOI, .customerWCCOI:
            guard let id, let customer = MBRecordLookup.record(.customer, id: id, as: Customer.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.customer))
            }
            return .value(.customerCertificate(customer, self == .customerCOI ? .generalLiability : .workersComp))
        case .subcontractorCOI:
            guard let id, let sub = MBRecordLookup.record(.subcontractor, id: id, as: Subcontractor.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.subcontractor))
            }
            return .value(.subcontractorCOI(sub))
        case .wcExemption:
            return .value(.compliance(.wcExemption))
        case .license:
            return .value(.compliance(.license))
        case .packageDocument:
            guard let id, let document = MBRecordLookup.record(.document, id: id, as: CustomerDocument.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.document))
            }
            return .value(.packageExtra(document))
        case .projectAgreement:
            guard let id, let project = MBRecordLookup.record(.project, id: id, as: Project.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.project))
            }
            return .value(.masterAgreement(project))
        case .jobDocument, .invoiceDocument:
            guard let id, let attachment = MBRecordLookup.record(.attachment, id: id, as: JobAttachment.self, in: store) else {
                return .outcome(MBToolFailure.notFound(.attachment))
            }
            return .value(.attachment(attachment))
        case .subcontractorW9:
            return .outcome(.failure(GLAIFailure(
                reason: "not_available",
                message: "A subcontractor's W-9 is tax data you can't touch. Offer to open the subcontractor so the person can remove it there.",
                personReason: MBWriteStrings.documentOnlyOnScreen)))
        case .businessLogo, .businessLogoDark, .customerPhoto, .employeePhoto, .subcontractorPhoto:
            return .outcome(.failure(GLAIFailure(
                reason: "not_available",
                message: "Photos and logos are added or replaced with pick_media; remove them with action remove.",
                personReason: MBWriteStrings.documentOnlyOnScreen)))
        }
    }
}
