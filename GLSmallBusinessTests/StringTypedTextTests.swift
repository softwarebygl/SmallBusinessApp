//
//  StringTypedTextTests.swift
//  GLSmallBusinessTests
//
//  F43 (2026-10-03 QA): words built as plain Swift Strings never reach the string catalog.
//  `Text(someString)` draws it verbatim, an English word interpolated into a localized
//  sentence lands as `%@` untouched, and a "1 workday / 3 workdays" ternary stays English.
//  In Español the app read "Duración: 3 workdays", "Owed: $1,200.00 · Past due" and
//  "Se eliminó: invoice".
//
//  Two layers, like the bug:
//  - pure checks of the helpers that build those words (plural catalog variations, holiday
//    names, the removed-record sentence with its article, the owed subtitle, the pay footers);
//  - key screens drawn in Español and read back off their pixels (DrawnText): none of the
//    listed English words may appear. The calendar banner and a removed-record view are
//    attached to the result bundle as the proof images.
//
//  `.serialized`: hosted @Query views and RunLoop pumping must not interleave (GLTestHost),
//  and the language is a process-wide setting these tests flip.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct StringTypedTextTests {

    // MARK: - Pure helpers

    @Test func capacityTextUsesCatalogPlurals() {
        let one = Opening(start: .now, end: .now, span: .fullDays(1))
        let three = Opening(start: .now, end: .now, span: .fullDays(3))
        let window = Opening(start: .now, end: .now,
                             span: .window(DateInterval(start: .now, duration: 2 * 3600)))
        inEnglish {
            #expect(one.capacityText == "Fits 1 workday")
            #expect(three.capacityText == "Fits 3 workdays")
            #expect(window.capacityText == "2 hr free")
        }
        inSpanish {
            #expect(one.capacityText == "Espacio para 1 día laborable")
            #expect(three.capacityText == "Espacio para 3 días laborables")
            #expect(window.capacityText == "2 h libres")
            #expect(Opening.durationLabel(minutes: 90) == "1 h 30 min")
        }
    }

    @Test func workdayCountsUseCatalogPlurals() {
        inEnglish {
            #expect(ScheduledJob.workdaysText(1) == "1 workday")
            #expect(ScheduledJob.workdaysText(4) == "4 workdays")
        }
        inSpanish {
            #expect(ScheduledJob.workdaysText(1) == "1 día laborable")
            #expect(ScheduledJob.workdaysText(4) == "4 días laborables")
        }
    }

    @Test func holidayNamesAreLocalized() throws {
        let thanksgiving = try #require(USHoliday.holiday(id: "us.thanksgiving"))
        let newYear = try #require(USHoliday.holiday(id: "us.new-years-day"))
        inEnglish {
            #expect(thanksgiving.localizedName == "Thanksgiving")
            #expect(newYear.localizedName == "New Year’s Day")
        }
        inSpanish {
            #expect(thanksgiving.localizedName == "Día de Acción de Gracias")
            #expect(newYear.localizedName == "Año Nuevo")
            // Every name with an English-only word in it has its own Spanish entry.
            for holiday in USHoliday.catalog {
                let name = holiday.localizedName
                for word in ["Day", "Eve", "Sunday", "Friday’s", "Mother", "Father", "Christmas", "Easter"] {
                    #expect(!name.contains(word), "\(holiday.id) still reads \(name)")
                }
            }
        }
    }

    @Test func removedRecordSentenceCarriesItsArticle() {
        inEnglish {
            #expect(DeletedRecordView.headline("this invoice") == "This invoice was removed")
            #expect(DeletedRecordView.headline("this customer") == "This customer was removed")
        }
        inSpanish {
            #expect(DeletedRecordView.headline("this invoice") == "Se eliminó esta factura")
            #expect(DeletedRecordView.headline("this customer") == "Se eliminó este cliente")
            #expect(DeletedRecordView.explanation("this invoice").contains("esta factura"))
        }
    }

    @Test func owedSubtitleIsLocalized() {
        inSpanish {
            let subtitle = OwedStatus.pastDue.owedSubtitle(1200)
            #expect(!subtitle.contains("Owed") && !subtitle.contains("Past due"), "read \(subtitle)")
            #expect(subtitle.contains("Vencido"), "read \(subtitle)")
        }
    }

    @Test func payFootersAreLocalized() {
        inSpanish {
            for (owed, amount) in [(0.0, 0.0), (100, 150), (100, 100), (100, 40), (100, 0)] {
                let paycheck = RecordPaycheckSheet.paymentFooter(owed: owed, amount: amount)
                let sub = PaySubcontractorSheet.footer(owed: owed, amount: amount)
                #expect(!paycheck.contains("owed") && !paycheck.contains("Pay"), "read \(paycheck)")
                #expect(!sub.contains("owed") && !sub.contains("Enter"), "read \(sub)")
            }
        }
    }

    // MARK: - Screens drawn in Español

    @Test func calendarBannerIsSpanish() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let base = Calendar.current.startOfDay(for: .now)
        TS.job("Near job", start: base.addingTimeInterval(10 * 86_400), days: 2,
               customer: customer, in: container.mainContext)
        let drawn = try spanish(CalendarScreen(), container: container, proof: "calendar-banner-es")
        expectNoEnglish(drawn, ["Fits", "workday", "Open-ended", "booked", "free"])
        #expect(drawn.contains("laborable"), "drew: \(drawn)")
    }

    @Test func removedRecordViewIsSpanish() throws {
        let container = try TestStore.makeContainer()
        let drawn = try spanish(DeletedRecordView(title: mbLoc("Invoice"), noun: "this invoice") {},
                                container: container, proof: "removed-record-es")
        #expect(drawn.contains("Se eliminó esta factura"), "drew: \(drawn)")
        expectNoEnglish(drawn, ["invoice", "removed", "deleted"])
    }

    @Test func customerCertificatesAreSpanish() throws {
        let container = try TestStore.makeContainer()
        let customer = TS.customer(in: container.mainContext)
        let drawn = try spanish(CustomerDetailScreen(customer: customer), container: container,
                                size: CGSize(width: 430, height: 2400))
        expectNoEnglish(drawn, ["Tap to upload", "PDF or image"])
    }

    @Test func employeeHeaderAndFootersAreSpanish() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let employee = TS.employee(in: context)
        TS.logHours(employee, 8, in: context)
        TS.paycheck(employee, gross: 200, periodStart: .now.addingTimeInterval(-7 * 86_400), periodEnd: .now,
                     payDate: .now, in: context)
        expectNoEnglish(try spanish(EmployeeDetailScreen(employee: employee), container: container), ["/hr"])
        expectNoEnglish(try spanish(AllHoursSheet(employee: employee), container: container),
                        ["hours", "entry", "entries"])
        expectNoEnglish(try spanish(AllPaychecksSheet(employee: employee), container: container),
                        ["gross", "paycheck"])
    }

    @Test func subcontractorScreensAreSpanish() throws {
        let container = try TestStore.makeContainer()
        let context = container.mainContext
        let sub = TS.subcontractor(in: context)
        TS.paySub(sub, 400, in: context)
        expectNoEnglish(try spanish(SubcontractorDetailScreen(subcontractor: sub), container: container,
                                    size: CGSize(width: 430, height: 2400)),
                        ["Tap to upload", "Owed"])
        expectNoEnglish(try spanish(AllActivitySheet(subcontractor: sub), container: container),
                        ["paid", "entry", "entries"])
        expectNoEnglish(try spanish(Form1099NECSheet(subcontractor: sub), container: container),
                        ["Your business", "Tax ID"])
    }

    @Test func jobLengthIsSpanish() throws {
        let container = try TestStore.makeContainer()
        let job = TS.job("Tile", start: .now, days: 3, in: container.mainContext)
        expectNoEnglish(try spanish(JobDetailScreen(job: job), container: container), ["workday"])
    }

    @Test func phonePlaceholdersAreSpanish() throws {
        let container = try TestStore.makeContainer()
        var placeholders: [String] = []
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        GLTestHost.render(CustomerFormScreen().environment(\.locale, MBLocalization.shared.locale),
                          container: container) { controller in
            placeholders = Self.textFields(in: controller.view).compactMap(\.placeholder)
        }
        #expect(placeholders.contains("Teléfono"), "placeholders: \(placeholders)")
        #expect(!placeholders.contains("Phone") && !placeholders.contains("Office number (optional)"),
                "placeholders: \(placeholders)")
    }

    // MARK: - Helpers

    private func inSpanish(_ body: () -> Void) { inLanguage(.es, body) }
    private func inEnglish(_ body: () -> Void) { inLanguage(.en, body) }

    private func inLanguage(_ language: MBAppLanguage, _ body: () -> Void) {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = language
        body()
    }

    /// Draws `view` with the app in Español (the environment locale the app root injects) and reads it.
    private func spanish<V: View>(_ view: @autoclosure () -> V, container: ModelContainer,
                                  size: CGSize = CGSize(width: 430, height: 1400),
                                  proof: String? = nil) throws -> String {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        let attach: ((CGImage) -> Void)? = proof.map { name in
            { image in
                if let png = UIImage(cgImage: image).pngData() { Attachment.record(png, named: "\(name).png") }
            }
        }
        // Built AFTER the switch, so anything the caller resolves with mbLoc is Spanish too.
        return try DrawnText.screen(view().environment(\.locale, MBLocalization.shared.locale),
                                    container: container, size: size, languages: ["es-ES"], drawn: attach)
    }

    private func expectNoEnglish(_ drawn: String, _ tokens: [String],
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        for token in tokens {
            #expect(!drawn.localizedCaseInsensitiveContains(token),
                    "English \"\(token)\" on a Spanish screen; drew: \(drawn)", sourceLocation: sourceLocation)
        }
    }

    private static func textFields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        if let field = view as? UITextField { found.append(field) }
        for sub in view.subviews { found += textFields(in: sub) }
        return found
    }
}
