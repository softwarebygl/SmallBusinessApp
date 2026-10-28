//
//  LocaleFormattingTests.swift
//  GLSmallBusinessTests
//
//  Which language and calendar a date or amount is written in (QA 2026-10-03 F44, F132, F139).
//
//    • On screen, dates, times, weekday and month names follow the APP's language (law 25), not
//      the phone's: an English iPhone with the app in Español reads "15 ene", never "Jan 15".
//    • The accountant CSVs are machine-read: always 2026-10-03 (Gregorian, POSIX digits), whatever
//      the phone's language, region or calendar — a Buddhist-calendar phone used to write 2569.
//    • The W-9 is an IRS form: its date is US MM/dd/yyyy (10/03/2026).
//    • The customer messages are English-pinned: their dates read "Oct 3, 2026" in every setting.
//
//  The suite runs on any simulator; it was also run with the simulator set to French (France)
//  with the Buddhist calendar, the case the audit described, where the old code wrote French month
//  names and the year 2569.
//

import Testing
import Foundation
import PDFKit
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct LocaleFormattingTests {

    /// Noon on 3 October 2026 in the phone's own time zone (Gregorian), so no time zone can move
    /// the day.
    private static let october3: Date = {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        return gregorian.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)) ?? .now
    }()

    /// The year the phone's own calendar gives the date — what the year pickers hand the exports.
    private static var deviceYear: Int { Calendar.current.component(.year, from: october3) }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Runs `body` with the app in Español, then puts the person's choice back.
    private func inSpanish(_ body: () throws -> Void) rethrows {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .es
        try body()
    }

    // MARK: - Screens follow the app's language (F44)

    @Test func certificateCaptionUsesTheAppLanguage() {
        inSpanish {
            let caption = GLCertificateStatus.caption(TS.day(2099, 1, 15)) ?? ""
            #expect(caption.contains("ene"), "got \(caption)")
            #expect(!caption.contains("Jan") && !caption.contains("janv"), "got \(caption)")
        }
    }

    @Test func statsMonthLabelUsesTheAppLanguage() {
        inSpanish {
            let label = StatsPeriod.month(year: Self.deviceYear, month: 1).label
            #expect(label.contains("enero"), "got \(label)")
        }
    }

    @Test func statsChartMonthsUseTheAppLanguage() {
        inSpanish {
            let buckets = StatsEngine.summary(period: .year(Self.deviceYear), invoices: [],
                                              estimates: [], receipts: []).inOut
            #expect(buckets.count == 12)
            let first = buckets.first?.label ?? ""
            #expect(first.lowercased().hasPrefix("ene"), "got \(first)")
        }
    }

    @Test func lastBackupDayUsesTheAppLanguage() {
        inSpanish {
            let detail = GLSyncBackupRow.detail(lastSyncAt: TS.day(2025, 1, 15),
                                                changes: MBSessionPurge.UnsyncedChanges())
            #expect(detail.contains("ene"), "got \(detail)")
        }
    }

    @Test func jobTimesUseTheAppLanguage() {
        inSpanish {
            let job = TS.job("Tile", start: Self.october3, hour: 13, minutes: 180, calendar: .current)
            let style = Date.FormatStyle(date: .omitted, time: .shortened).locale(MBLocalization.currentLocale)
            let start = job.startTime ?? Self.october3
            #expect(job.timeText.hasPrefix(start.formatted(style)), "got \(job.timeText)")
        }
    }

    @Test func workScheduleWeekdaysUseTheAppLanguage() {
        inSpanish {
            #expect(WorkScheduleScreen.weekdayName(0) == "domingo")
            #expect(WorkScheduleScreen.weekdayName(6) == "sábado")
            #expect(WorkScheduleScreen.weekdayName(7) == "")   // out of range: blank, never a trap
            #expect(WorkScheduleScreen.weekdayName(-1) == "")
        }
    }

    @Test func statsMonthPickerAndChartShareTheAppCalendar() {
        inSpanish {
            #expect(Calendar.appLanguage.monthSymbols.first == "enero")
            #expect(Calendar.appLanguage.identifier == Calendar.current.identifier)   // the phone's kind of calendar
        }
    }

    // MARK: - Screen money follows the app's language (F132)

    @Test func screenMoneyUsesTheAppLocaleAndTheOneRoundingRule() {
        inSpanish {
            let appLocale = MBLocalization.currentLocale
            #expect(appLocale.language.languageCode?.identifier == "es")
            // Same cents as `.money` (half-up on the amount as written), written the app's way.
            let expected = 1000.03.formatted(.currency(code: "USD").locale(appLocale))
            #expect(1000.025.formatted(.appMoney) == expected)
        }
    }

    // MARK: - Accountant CSVs: Gregorian, POSIX (F139)

    @Test func csvDateIgnoresTheCalendarAndLanguage() {
        #expect(StatsExport.csvDate(Self.october3) == "2026-10-03")
    }

    @Test func receiptsCSVDateIsGregorianPOSIX() {
        inSpanish {
            let receipt = TS.receipt(total: 10, category: "Materials", date: Self.october3)
            let files = StatsExport.files(period: .year(Self.deviceYear), invoices: [], estimates: [],
                                          receipts: [receipt], business: nil)
            let csv = files.first { $0.pathExtension == "csv" }.map(read) ?? ""
            #expect(csv.contains("\n2026-10-03,"), "got \(csv)")
            #expect(!csv.contains("2569"))
        }
    }

    @Test func paycheckLedgerDateIsGregorianPOSIX() {
        inSpanish {
            let employee = TS.employee(first: "Jason", last: "Garcia")
            TS.paycheck(employee, gross: 100, periodStart: Self.october3, periodEnd: Self.october3,
                        payDate: Self.october3)
            let files = EmployeePayExport.files(employees: [employee], year: Self.deviceYear, business: nil)
            let ledger = files.first { $0.lastPathComponent.contains("Paychecks") }.map(read) ?? ""
            #expect(ledger.contains("Jason Garcia,2026-10-03,2026-10-03,2026-10-03,"), "got \(ledger)")
        }
    }

    @Test func subPaymentLedgerDateIsGregorianPOSIX() {
        inSpanish {
            let sub = TS.subcontractor(first: "Luis", last: "Mendoza")
            TS.paySub(sub, 700, date: Self.october3, detail: "Rough-in")
            let files = SubPayExport.files(subcontractors: [sub], year: Self.deviceYear, business: nil)
            let ledger = files.first { $0.lastPathComponent.contains("Payments") }.map(read) ?? ""
            #expect(ledger.contains(",2026-10-03,700.00,"), "got \(ledger)")
        }
    }

    // MARK: - The W-9 date is US MM/dd/yyyy (F139)

    @Test func w9SignedDateIsUSNumeric() throws {
        try inSpanish {
            let url = try #require(W9PDF.render(BusinessProfile(), signedDate: Self.october3))
            defer { W9PDF.cleanUp() }
            let text = try #require(PDFDocument(url: url)?.string)
            #expect(text.contains("10/03/2026"), "W-9 date missing")
        }
    }

    // MARK: - English-pinned messages carry English dates (F139)

    @Test func estimateMessageDateIsEnglish() {
        inSpanish {
            let estimate = TS.estimate()
            estimate.validUntil = Self.october3
            let body = EstimateMessage.plainBody(estimate: estimate, business: nil)
            #expect(body.contains("Valid until: Oct 3, 2026"), "got \(body)")
            let html = EstimateMessage.htmlBody(estimate: estimate, business: nil)
            #expect(html.contains("Oct 3, 2026"))
        }
    }

    @Test func invoiceMessageDateIsEnglish() {
        inSpanish {
            let invoice = TS.invoice()
            invoice.dueDate = Self.october3
            #expect(InvoiceMessage.plainBody(invoice: invoice, business: nil).contains("Oct 3, 2026"))
            #expect(InvoiceMessage.htmlBody(invoice: invoice, business: nil).contains("Oct 3, 2026"))
        }
    }

    @Test func paymentReceiptMessageDateIsEnglish() {
        inSpanish {
            let invoice = TS.invoice()
            let payment = TS.pay(invoice, 250, date: Self.october3)
            let body = PaymentReceiptMessage.plainBody(invoice: invoice, payment: payment, business: nil)
            #expect(body.contains("(Check, Oct 3, 2026)"), "got \(body)")
            let html = PaymentReceiptMessage.htmlBody(invoice: invoice, payment: payment, business: nil)
            #expect(html.contains("Check · Oct 3, 2026"))
        }
    }
}
