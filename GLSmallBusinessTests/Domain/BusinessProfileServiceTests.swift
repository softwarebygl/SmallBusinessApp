//
//  BusinessProfileServiceTests.swift
//  GLSmallBusinessTests — Domain
//
//  The business profile singleton's save paths (details, logos, Document Messages, the Settings
//  switches, insurance and license documents), the work schedule, and the app-level settings.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct BusinessProfileServiceTests {

    private func details() -> BusinessDetailsDraft {
        var draft = BusinessDetailsDraft()
        draft.businessName = " Gold Life Tile "
        draft.email = " hi@example.com "
        draft.address = Address(street1: " 1 Main ", city: "Miami", state: "FL", postalCode: "32301")
        draft.w9LLCClassification = " s "
        return draft
    }

    @Test func detailsAreTrimmedSavedAndKeepStreet2() throws {
        let context = try DomainFixtures.context()
        let profile = BusinessProfile()
        profile.addressStreet2 = "Suite 200"
        context.insert(profile)
        context.saveChanges()
        _ = try DomainState.subscribed.run {
            try BusinessProfileService.updateDetails(details(), logos: BusinessLogos(light: Data([1]), dark: nil),
                                                     for: profile, in: context)
        }
        #expect(profile.businessName == "Gold Life Tile" && profile.email == "hi@example.com")
        #expect(profile.address.street1 == "1 Main" && profile.address.street2 == "Suite 200",
                "the form has no Apt/Suite line — it is left alone")
        #expect(profile.w9LLCClassification == "S", "the LLC letter is uppercased")
        #expect(profile.logoData == Data([1]) && profile.logoDataDark == nil)
        #expect(!context.hasChanges, "saved now — the form used to rely on autosave")
    }

    @Test func detailsRefusals() throws {
        let context = try DomainFixtures.context()
        var noName = details()
        noName.businessName = "  "
        var noContact = details()
        noContact.email = ""
        try DomainState.subscribed.run {
            #expect(domainError { try BusinessProfileService.updateDetails(noName, in: context) } == .businessNameRequired)
            // A name alone saves (found 2026-09-29) — contact is the SEND gate, not the save's.
            noContact.phone = ""
            let saved = try BusinessProfileService.updateDetails(noContact, in: context)
            #expect(saved.businessName == noContact.businessName.trimmingCharacters(in: .whitespaces))
            #expect(!saved.isComplete, "still can't send until a phone or email is added")
            noContact.phone = "850-555-0100"
            try BusinessProfileService.updateDetails(noContact, in: context)
        }
        #expect(DomainState.lapsed.run { domainError { try BusinessProfileService.updateDetails(details(), in: context) } }
                == .readOnly(operation: "saveBusinessProfile", lapsed: true))
        #expect(try context.fetchCount(FetchDescriptor<BusinessProfile>()) == 1, "found or created exactly once")
    }

    /// The transient stand-in BusinessProfileHost renders offline is adopted once writes are allowed.
    @Test func aDetachedStandInIsAdopted() throws {
        let context = try DomainFixtures.context()
        let standIn = BusinessProfile()
        #expect(DomainState.offline.run { domainError { try BusinessProfileService.updateDetails(details(), for: standIn, in: context) } }
                == .readOnly(operation: "saveBusinessProfile", lapsed: false))
        #expect(standIn.modelContext == nil, "a refused write adopts nothing")
        _ = try DomainState.subscribed.run { try BusinessProfileService.updateDetails(details(), for: standIn, in: context) }
        #expect(standIn.modelContext != nil && standIn.syncID != nil)
        #expect(try context.fetchCount(FetchDescriptor<BusinessProfile>()) == 1)
    }

    /// A stand-in held while offline must not become a SECOND profile when the real one has
    /// appeared since (reconnected, or pulled by a sync): the write lands on the stored one.
    @Test func aStandInNeverBecomesASecondProfile() throws {
        let context = try DomainFixtures.context()
        let stored = BusinessProfile()
        stored.businessName = "Stored"
        context.insert(stored)
        context.saveChanges()
        let standIn = BusinessProfile()
        let saved = try DomainState.subscribed.run {
            try BusinessProfileService.updateDetails(details(), for: standIn, in: context)
        }
        #expect(saved === stored && standIn.modelContext == nil)
        var messages = DocumentMessagesDraft()
        messages.warrantyText = "Two years."
        try DomainState.subscribed.run {
            try BusinessProfileService.updateDocumentMessages(messages, for: BusinessProfile(), in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<BusinessProfile>()) == 1)
        #expect(stored.warrantyText == "Two years." && !context.hasChanges)
    }

    @Test func documentMessagesAndLogo() throws {
        let context = try DomainFixtures.context()
        var draft = DocumentMessagesDraft()
        draft.includeReviewLinkOnReceipts = true
        draft.reviewsURL = " https://g.page/r/x "
        draft.invoiceIntro = "  Thanks!  "
        draft.warrantyText = " One year. "
        try DomainState.subscribed.run {
            try BusinessProfileService.updateDocumentMessages(draft, in: context)
            try BusinessProfileService.setLogo(Data([9]), dark: true, in: context)
        }
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(profile.includeReviewLinkOnReceipts && profile.reviewsURL == "https://g.page/r/x")
        #expect(profile.invoiceMessageIntro == "Thanks!" && profile.warrantyText == "One year.")
        #expect(DocumentMessagesDraft(profile).invoiceIntro == "Thanks!")
        #expect(profile.logoDataDark == Data([9]) && profile.logoData == nil)
        #expect(DomainState.lapsed.run { domainError { try BusinessProfileService.updateDocumentMessages(draft, in: context) } }
                == .readOnly(operation: "saveDocumentSettings", lapsed: true))
    }

    @Test func settingsSwitchesCreateTheProfileAndKeepTypedText() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            try BusinessProfileService.setDisplay(.addressOnDocuments, false, in: context)
            try BusinessProfileService.setEmailSignatureText("Licensed & insured ", in: context)
        }
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(!profile.showAddressOnDocuments && profile.showLogoOnDocuments)
        #expect(profile.emailSignatureText == "Licensed & insured ", "stored as typed, trailing space and all")
        #expect(DomainState.offline.run { domainError { try BusinessProfileService.setDisplay(.logoOnDocuments, false, in: context) } }
                == .readOnly(operation: "saveAppSettings", lapsed: false))
        #expect(profile.showLogoOnDocuments)
        #expect(try context.fetchCount(FetchDescriptor<BusinessProfile>()) == 1)
    }

    /// The Settings field writes each keystroke without saving, then saves once.
    @Test func signatureTextCanWaitForOneSave() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run { try BusinessProfileService.setDisplay(.emailSignature, true, in: context) }
        try DomainState.subscribed.run {
            try BusinessProfileService.setEmailSignatureText("L", saveNow: false, in: context)
            try BusinessProfileService.setEmailSignatureText("Li", saveNow: false, in: context)
        }
        #expect(context.hasChanges, "not saved per keystroke")
        context.saveChanges()
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(profile.emailSignatureText == "Li" && !context.hasChanges)
    }

    @Test func payLinkDefaultIsASavedSettingsWrite() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run { try BusinessProfileService.setPayLinkDefault(false, in: context) }
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(!profile.payLinkDefaultOn && profile.syncID != nil && !context.hasChanges)
        #expect(DomainState.lapsed.run { domainError { try BusinessProfileService.setPayLinkDefault(true, in: context) } }
                == .readOnly(operation: "saveAppSettings", lapsed: true))
        #expect(!profile.payLinkDefaultOn)
    }

    @Test func zelleDetailsAndDefaultAreSavedSettingsWrites() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            try BusinessProfileService.updateZelleDetails(tag: "  Gold Life  ",
                                                          email: " zelle@example.com ",
                                                          phone: " 850-555-0199 ",
                                                          qrCodeData: Data([0x89, 0x50]),
                                                          in: context)
            try BusinessProfileService.setZelleDefault(true, in: context)
        }
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(profile.zelleTag == "Gold Life" && profile.zelleEmail == "zelle@example.com" && profile.zellePhone == "850-555-0199")
        #expect(profile.zelleQRCodeData == Data([0x89, 0x50]) && profile.zelleDefaultOn && profile.zelleIsConfigured)
        #expect(profile.syncID != nil && !context.hasChanges)
        #expect(DomainState.lapsed.run { domainError { try BusinessProfileService.setZelleDefault(false, in: context) } }
                == .readOnly(operation: "saveAppSettings", lapsed: true))
        #expect(profile.zelleDefaultOn)
    }

    @Test func complianceDocumentsAndReferenceCOI() throws {
        let context = try DomainFixtures.context()
        let expiry = TS.day(2027, 1, 31)
        try DomainState.subscribed.run {
            try DocumentService.set(.compliance(.license), data: Data([1]), name: "license.pdf", in: context)
            try DocumentService.setExpiry(.compliance(.license), expiry, in: context)
            try DocumentService.set(.referenceCOI, data: Data([2]), name: "coi.pdf", in: context)
        }
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(profile.licenseDocumentData == Data([1]) && profile.licenseDocumentName == "license.pdf")
        #expect(profile.licenseExpiresOn == expiry && ComplianceKind.license.expiry(profile) == expiry)
        #expect(profile.ownerReferenceCOIName == "coi.pdf" && profile.wcExemptionData == nil)

        #expect(DomainState.lapsed.run { domainError { try DocumentService.set(.compliance(.license), data: nil, name: "", in: context) } }
                == .readOnly(operation: "deleteDocument", lapsed: true))
        try DomainState.subscribed.run {
            try DocumentService.set(.compliance(.license), data: nil, name: "ignored", in: context)
            try DocumentService.set(.referenceCOI, data: nil, name: "ignored", in: context)
        }
        #expect(profile.licenseDocumentData == nil && profile.licenseDocumentName == "")
        #expect(profile.licenseExpiresOn == expiry, "removing the file leaves the date, as the screens always have")
        #expect(profile.ownerReferenceCOIData == nil && profile.ownerReferenceCOIName == "")
        #expect(!context.hasChanges)
    }
}

// MARK: - Work schedule

@MainActor
@Suite(.serialized)
struct WorkScheduleServiceTests {

    /// The screen's clamps, now on WorkSchedule itself.
    @Test func editRulesClamp() {
        var s = WorkSchedule.standard
        s.setStart(18 * 60, weekday: 1)                   // after the 5 PM end
        #expect(s.weekdayHours[1].startMinutes == 17 * 60 - 1)
        s.setEnd(0, weekday: 1)
        #expect(s.weekdayHours[1].endMinutes == s.weekdayHours[1].startMinutes + 1)
        s.setWorkday(6, true)
        #expect(s.weekdayHours[6].isWorkday)
        s.setWorkday(9, true)                              // out of range: ignored, no trap

        s.vacations = [DateRangeRule(start: TS.day(2026, 7, 1), end: TS.day(2026, 7, 3))]
        s.setTimeOffStart(TS.day(2026, 7, 10), at: 0)
        #expect(s.vacations[0].end == TS.day(2026, 7, 10), "To is dragged along")
        s.setTimeOffEnd(TS.day(2026, 7, 1), at: 0)
        #expect(s.vacations[0].end == TS.day(2026, 7, 10), "To never moves before From")

        s.overrides = [DateOverride(date: TS.day(2026, 7, 4), kind: .blocked)]
        s.setOverrideTime(600, start: true, at: 0)
        #expect(s.overrides[0].kind == .blocked, "a day off has no times to set")
        s.setOverrideCustomHours(true, at: 0)
        s.setOverrideTime(20 * 60, start: true, at: 0)
        #expect(s.overrides[0].kind == .customHours(startMinutes: 17 * 60 - 1, endMinutes: 17 * 60))

        s.setHoliday("us.new-years-day", enabled: false)
        #expect(!s.isHolidayOff("us.new-years-day"))
        #expect(WorkSchedule.minutes(of: TS.calendar.date(bySettingHour: 7, minute: 45, second: 0, of: TS.day(2026, 1, 1)) ?? .now,
                                     calendar: TS.calendar) == 465)
    }

    @Test func saveCreatesTheProfileAndARefusalWritesNothing() throws {
        let context = try DomainFixtures.context()
        var schedule = WorkSchedule.standard
        schedule.setWorkday(6, true)
        #expect(DomainState.lapsed.run { domainError { try WorkScheduleService.save(schedule, in: context) } }
                == .readOnly(operation: "saveWorkSchedule", lapsed: true))
        #expect(try context.fetchCount(FetchDescriptor<BusinessProfile>()) == 0)

        try DomainState.subscribed.run { try WorkScheduleService.save(schedule, in: context) }
        let profile = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(profile.workSchedule == schedule && !context.hasChanges)
        let stamp = profile.updatedAt
        try DomainState.subscribed.run { try WorkScheduleService.save(schedule, in: context) }
        #expect(profile.updatedAt == stamp, "an equal schedule is not rewritten")
    }

    @Test func oneEditAtATime() throws {
        let context = try DomainFixtures.context()
        try DomainState.subscribed.run {
            let s1 = try WorkScheduleService.setWeekday(6, isWorkday: true, startMinutes: 9 * 60, endMinutes: 13 * 60,
                                                        in: context)
            #expect(s1.weekdayHours[6] == WeekdayHours(isWorkday: true, startMinutes: 540, endMinutes: 780))
            #expect(domainError { try WorkScheduleService.setWeekday(1, isWorkday: true, startMinutes: 600, endMinutes: 600, in: context) }
                    == .invalidHours)
            #expect(domainError { try WorkScheduleService.setWeekday(7, isWorkday: true, in: context) }
                    == .unknownScheduleItem)

            let s2 = try WorkScheduleService.setHoliday("us.new-years-day", enabled: false, in: context)
            #expect(!s2.isHolidayOff("us.new-years-day") && s2.weekdayHours[6].isWorkday, "earlier edits are kept")
            #expect(domainError { try WorkScheduleService.setHoliday("not-a-holiday", enabled: true, in: context) }
                    == .unknownScheduleItem)

            #expect(domainError { try WorkScheduleService.addTimeOff(from: TS.day(2026, 7, 5), through: TS.day(2026, 7, 1), in: context, calendar: TS.calendar) }
                    == .invalidDateRange)
            let s3 = try WorkScheduleService.addTimeOff(from: TS.day(2026, 7, 1), through: TS.day(2026, 7, 5),
                                                        in: context, calendar: TS.calendar)
            let s4 = try WorkScheduleService.addDayOff(TS.day(2026, 3, 17), label: " Parade ", repeatsYearly: true,
                                                       in: context, calendar: TS.calendar)
            #expect(s4.customDaysOff.last?.label == "Parade")
            #expect(domainError { try WorkScheduleService.addOverride(TS.day(2026, 8, 1), kind: .customHours(startMinutes: 700, endMinutes: 600), in: context) }
                    == .invalidHours)
            let s5 = try WorkScheduleService.addOverride(TS.day(2026, 8, 1), kind: .blocked, in: context, calendar: TS.calendar)
            #expect(s5.overrides.count == 1)

            let timeOff = try #require(s3.vacations.last?.id)
            let s6 = try WorkScheduleService.removeEntry(timeOff, in: context)
            #expect(s6.vacations.isEmpty && s6.customDaysOff.count == 1)
            #expect(domainError { try WorkScheduleService.removeEntry(UUID(), in: context) } == .unknownScheduleItem)
        }
        let saved = try #require(try context.fetch(FetchDescriptor<BusinessProfile>()).first).workSchedule
        #expect(saved.overrides.count == 1 && saved.weekdayHours[6].isWorkday)
        #expect(DomainState.offline.run { domainError { try WorkScheduleService.setHoliday("us.new-years-day", enabled: true, in: context) } }
                == .readOnly(operation: "saveWorkSchedule", lapsed: false))
    }
}

// MARK: - App settings

@MainActor
@Suite(.serialized)
struct AppSettingsServiceTests {

    @Test func switchesDefaultOnAndPersist() throws {
        let suite = "AppSettingsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettingsService.oneJobAtATime(defaults) && AppSettingsService.useCompanyLogo(defaults))
        AppSettingsService.setOneJobAtATime(false, defaults: defaults)
        AppSettingsService.setUseCompanyLogo(false, defaults: defaults)
        #expect(!AppSettingsService.oneJobAtATime(defaults) && !AppSettingsService.useCompanyLogo(defaults))
        #expect(defaults.bool(forKey: SchedulingPrefs.oneJobAtATimeKey) == false)
    }

    @Test func languageAndAppearanceAreLocalOverrides() {
        let language = AppSettingsService.language, appearance = AppSettingsService.appearance
        defer {
            AppSettingsService.setLanguage(language)
            AppSettingsService.setAppearance(appearance)
        }
        AppSettingsService.setLanguage(.es)
        #expect(AppSettingsService.language == .es && MBLocalization.shared.language == .es)
        AppSettingsService.setAppearance(.dark)
        #expect(AppSettingsService.appearance == .dark)
    }
}
