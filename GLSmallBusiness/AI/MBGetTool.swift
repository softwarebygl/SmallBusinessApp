//
//  MBGetTool.swift
//  GLSmallBusiness — AI
//
//  `get`: one record in full — fields, totals, balances, payments, linked records and every
//  group / line / payment id (contract §5). The singletons `business`, `work_schedule` and
//  `app_settings` need no id.
//
//  Paging (estimates and invoices): page 1 is the header plus as many lines as fit; later pages
//  carry lines only. Pages are packed greedily in line order against the 8 KB budget, so the
//  same record always pages the same way and no line is ever skipped between pages.
//
//  On device (`outputCharacterLimit` set): the header's key facts plus the first 5 lines and a
//  `more_lines` count, inside 1,200 characters.
//

import Foundation
import SwiftData
import GoldLifeAI

@MainActor
struct MBGetTool: GLAIReadOnlyTool {
    let entry: GLAIManifest.Tool
    let env: MBToolEnvironment

    var name: String { entry.name }
    var summary: String { entry.summary }
    var parameters: GLAISchema { entry.parameters }
    var area: GLAIToolArea { entry.area }

    /// At most this many lines on one page, whatever fits (keeps a page readable).
    static let maxLinesPerPage = 30
    static let onDeviceLines = 5

    /// Header arrays trimmed first (least important last-resort order) when a header alone is big.
    static let headerTrimOrder = ["attachments", "change_orders", "payments", "recent_hours", "recent_work",
                                  "recent_paychecks", "estimates", "contracts", "invoices", "jobs", "receipts", "projects",
                                  "holidays", "days_off", "overrides", "time_off", "groups", "lines"]

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        guard context.isStillCurrent, let store = env.context() else { return MBToolFailure.unavailable }
        let args = MBArguments(json: call.arguments)
        guard let kindName = args.string("kind"), let kind = MBRecordKind(rawValue: kindName) else {
            return MBToolFailure.invalid("kind must be a record kind, business, work_schedule, app_settings, gold_life_id or device_info.")
        }
        let page = max(1, args.int("page") ?? 1)
        let budget = MBOutputFit.budget(context)
        let onDevice = context.outputCharacterLimit != nil
        let dto = MBRecordDTO(env: env, context: store)
        let id = args.string("id")

        if kind.isSingleton {
            let profile = MBRecordLookup.businessProfile(in: store)
            let object: [String: GLAIJSON]
            switch kind {
            case .business: object = dto.business(profile)
            case .workSchedule: object = dto.workSchedule(dto.schedule)
            case .goldLifeID: object = dto.goldLifeID()
            case .deviceInfo: object = dto.deviceInfo()
            default: object = dto.appSettings(profile)
            }
            return .result(MBOutputFit.fit(onDevice ? Self.compactHeader(object) : object,
                                           trimming: Self.headerTrimOrder, budget: budget))
        }
        guard id != nil else { return MBToolFailure.invalid("id is required for kind \(kind.rawValue). Use find to get it.") }

        func lookup<T: PersistentModel>(_ type: T.Type) -> T? {
            MBRecordLookup.record(kind, id: id, as: type, in: store)
        }

        let header: [String: GLAIJSON]
        var lines: [GLAIJSON]?
        switch kind {
        case .customer: guard let r = lookup(Customer.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .estimate:
            guard let r = lookup(Estimate.self) else { return MBToolFailure.notFound(kind) }
            header = dto.detail(r, context: store); lines = dto.lines(r)
        case .contract:
            guard let r = lookup(Contract.self) else { return MBToolFailure.notFound(kind) }
            header = dto.detail(r); lines = dto.lines(r)
        case .invoice:
            guard let r = lookup(Invoice.self) else { return MBToolFailure.notFound(kind) }
            header = dto.detail(r); lines = dto.lines(r)
        case .changeOrder: guard let r = lookup(ChangeOrder.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .job: guard let r = lookup(ScheduledJob.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .receipt: guard let r = lookup(Receipt.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .priceItem: guard let r = lookup(PriceSheetItem.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .employee: guard let r = lookup(Employee.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .subcontractor: guard let r = lookup(Subcontractor.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .project: guard let r = lookup(Project.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .payment: guard let r = lookup(InvoicePayment.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .timeEntry: guard let r = lookup(TimeEntry.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .paycheck: guard let r = lookup(Paycheck.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .subPayment: guard let r = lookup(SubPayment.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .attachment: guard let r = lookup(JobAttachment.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .document: guard let r = lookup(CustomerDocument.self) else { return MBToolFailure.notFound(kind) }; header = dto.detail(r)
        case .business, .workSchedule, .appSettings, .goldLifeID, .deviceInfo: return MBToolFailure.invalid("unreachable")
        }

        guard let lines else {
            return .result(MBOutputFit.fit(onDevice ? Self.compactHeader(header) : header,
                                           trimming: Self.headerTrimOrder, budget: budget))
        }

        if onDevice {
            var object = Self.compactHeader(header)
            object["lines"] = .array(lines.prefix(Self.onDeviceLines).map(Self.compactLine))
            if lines.count > Self.onDeviceLines { object["more_lines"] = .number(Double(lines.count - Self.onDeviceLines)) }
            return .result(MBOutputFit.fit(object, trimming: ["lines", "groups"], budget: budget))
        }

        // Page 1's budget is what the header leaves; later pages carry only a small wrapper.
        let fittedHeader = MBOutputFit.fit(header, trimming: Self.headerTrimOrder, budget: budget)
        let headerObject = fittedHeader.objectValue ?? header
        let wrapper: [String: GLAIJSON] = ["kind": header["kind"] ?? .null, "id": header["id"] ?? .null,
                                           "number": header["number"] ?? .null]
        let pages = Self.paginate(lines, firstBudget: budget.limit - Self.size(of: headerObject, budget) - 120,
                                  laterBudget: budget.limit - Self.size(of: wrapper, budget) - 120, budget: budget)
        guard page <= pages.count else {
            return MBToolFailure.invalid("page \(page) doesn't exist; this record has \(pages.count) page(s) of lines.")
        }
        var object = page == 1 ? headerObject : wrapper
        object["page"] = .number(Double(page))
        object["pages"] = .number(Double(pages.count))
        object["line_count"] = .number(Double(lines.count))
        object["lines"] = .array(pages[page - 1])
        if page < pages.count { object["next_page"] = .number(Double(page + 1)) }
        return .result(MBOutputFit.fit(object, trimming: ["lines"] + Self.headerTrimOrder, budget: budget))
    }

    static func size(of object: [String: GLAIJSON], _ budget: MBOutputFit.Budget) -> Int {
        budget.size(of: .object(object))
    }

    /// Greedy, deterministic pages: each page takes lines in order while they fit its budget (at
    /// least one line per page, at most `maxLinesPerPage`). Always at least one (maybe empty) page.
    static func paginate(_ lines: [GLAIJSON], firstBudget: Int, laterBudget: Int,
                         budget: MBOutputFit.Budget) -> [[GLAIJSON]] {
        var pages: [[GLAIJSON]] = [[]]
        var used = 2                      // "[]"
        var limit = max(0, firstBudget)
        for line in lines {
            let size = budget.size(of: line) + 1
            let last = pages.count - 1
            let startNewPage: Bool
            if pages[last].isEmpty {
                // Only page 1 can be left without a line: a header so big it leaves no room for
                // even one — page 1 is then the header alone and the lines start on page 2.
                startNewPage = last == 0 && used + size > limit
            } else {
                startNewPage = used + size > limit || pages[last].count >= maxLinesPerPage
            }
            if startNewPage {
                pages.append([])
                used = 2
                limit = max(0, laterBudget)
            }
            pages[pages.count - 1].append(line)
            used += size
        }
        return pages
    }

    // MARK: - On device

    static let onDeviceHeaderKeys: Set<String> = [
        "kind", "id", "number", "title", "name", "first_name", "last_name", "business", "business_name", "status",
        "customer_name", "vendor", "date", "total", "totals", "amount", "balance_due", "owes", "owed", "due_date",
        "valid_until", "start_date", "end_date", "paid", "paid_in_full", "gross", "pay_date", "phone", "email",
        "mobile_phone", "billing", "next_payday", "unit_price", "weekdays", "language", "appearance",
    ]

    static func compactHeader(_ object: [String: GLAIJSON]) -> [String: GLAIJSON] {
        var out = object.filter { onDeviceHeaderKeys.contains($0.key) && $0.value != .null }
        if let customer = object["customer"]?["name"] { out["customer"] = customer }
        return out
    }

    static func compactLine(_ line: GLAIJSON) -> GLAIJSON {
        guard case .object(let object) = line else { return line }
        return .object(object.filter { ["name", "quantity", "unit", "unit_price", "line_total"].contains($0.key) })
    }
}
