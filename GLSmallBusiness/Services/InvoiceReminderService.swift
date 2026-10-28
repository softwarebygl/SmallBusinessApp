//
//  InvoiceReminderService.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  Automated Payment Reminders configuration, triggers, and no-reply email generator.
//

import Foundation

// MARK: - Reminder Start Trigger

nonisolated enum ReminderStartTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneWeekAfterSent
    case twoWeeksAfterSent
    case twoWeeksBeforeDue
    case oneWeekBeforeDue
    case threeDaysBeforeDue
    case onDueDate
    case threeDaysAfterDue
    case oneWeekAfterDue
    case twoWeeksAfterDue

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .oneWeekAfterSent: return mbLoc("1 week after sent")
        case .twoWeeksAfterSent: return mbLoc("2 weeks after sent")
        case .twoWeeksBeforeDue: return mbLoc("2 weeks before due date")
        case .oneWeekBeforeDue: return mbLoc("1 week before due date")
        case .threeDaysBeforeDue: return mbLoc("3 days before due date")
        case .onDueDate: return mbLoc("On due date")
        case .threeDaysAfterDue: return mbLoc("3 days past due")
        case .oneWeekAfterDue: return mbLoc("1 week past due")
        case .twoWeeksAfterDue: return mbLoc("2 weeks past due")
        }
    }

    var infoDescription: String {
        switch self {
        case .oneWeekAfterSent: return "Sends the first reminder 7 days after the invoice was originally sent."
        case .twoWeeksAfterSent: return "Sends the first reminder 14 days after the invoice was originally sent."
        case .twoWeeksBeforeDue: return "Sends the first reminder 14 days before the invoice payment is due."
        case .oneWeekBeforeDue: return "Sends the first reminder 7 days before the invoice payment is due."
        case .threeDaysBeforeDue: return "Sends the first reminder 3 days before the invoice payment is due."
        case .onDueDate: return "Sends the first reminder on the exact due date of the invoice."
        case .threeDaysAfterDue: return "Sends the first reminder 3 days after the due date passes if unpaid."
        case .oneWeekAfterDue: return "Sends the first reminder 7 days after the due date passes if unpaid."
        case .twoWeeksAfterDue: return "Sends the first reminder 14 days after the due date passes if unpaid."
        }
    }

    func calculateStartDate(sentAt: Date, dueDate: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .oneWeekAfterSent: return calendar.date(byAdding: .day, value: 7, to: sentAt) ?? sentAt
        case .twoWeeksAfterSent: return calendar.date(byAdding: .day, value: 14, to: sentAt) ?? sentAt
        case .twoWeeksBeforeDue: return calendar.date(byAdding: .day, value: -14, to: dueDate) ?? dueDate
        case .oneWeekBeforeDue: return calendar.date(byAdding: .day, value: -7, to: dueDate) ?? dueDate
        case .threeDaysBeforeDue: return calendar.date(byAdding: .day, value: -3, to: dueDate) ?? dueDate
        case .onDueDate: return calendar.startOfDay(for: dueDate)
        case .threeDaysAfterDue: return calendar.date(byAdding: .day, value: 3, to: dueDate) ?? dueDate
        case .oneWeekAfterDue: return calendar.date(byAdding: .day, value: 7, to: dueDate) ?? dueDate
        case .twoWeeksAfterDue: return calendar.date(byAdding: .day, value: 14, to: dueDate) ?? dueDate
        }
    }
}

// MARK: - Reminder Frequency

nonisolated enum ReminderFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily
    case every3Days
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .daily: return mbLoc("Daily")
        case .every3Days: return mbLoc("Every 3 days")
        case .weekly: return mbLoc("Weekly")
        case .biweekly: return mbLoc("Every 2 weeks")
        case .monthly: return mbLoc("Monthly")
        }
    }

    var daysInterval: Int {
        switch self {
        case .daily: return 1
        case .every3Days: return 3
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        }
    }
}

// MARK: - Invoice Reminder Service

enum InvoiceReminderService {
    /// Ruling 3: System no-reply address with no Reply-To header.
    static let systemNoReplyEmail = "noreply@softwarebygl.com"

    static func daysUntilDue(dueDate: Date) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let due = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: today, to: due).day ?? 0
    }

    static func reminderSubject(invoice: Invoice, business: BusinessProfile?) -> String {
        let bName = business?.businessName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = bName.isEmpty ? "Invoice" : "\(bName) Invoice"
        let days = daysUntilDue(dueDate: invoice.dueDate)
        if days > 0 {
            return "\(prefix) #\(invoice.number) Reminder: \(days) days until due"
        } else if days == 0 {
            return "\(prefix) #\(invoice.number) Reminder: Due today"
        } else {
            return "\(prefix) #\(invoice.number) Past Due Notice: \(abs(days)) days overdue"
        }
    }

    static func reminderBody(invoice: Invoice, business: BusinessProfile?) -> String {
        let bName = business?.businessName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bPhone = business?.phone.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let days = daysUntilDue(dueDate: invoice.dueDate)

        var timingSentence = ""
        if days > 1 {
            timingSentence = "This is a friendly reminder that invoice #\(invoice.number) is due in \(days) days on \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))."
        } else if days == 1 {
            timingSentence = "This is a friendly reminder that invoice #\(invoice.number) is due tomorrow on \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))."
        } else if days == 0 {
            timingSentence = "This is a reminder that invoice #\(invoice.number) is due today, \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))."
        } else if days == -1 {
            timingSentence = "Your invoice #\(invoice.number) was due yesterday on \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted)) and is currently 1 day past due."
        } else {
            timingSentence = "Your invoice #\(invoice.number) was due on \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted)) and is currently \(abs(days)) days past due."
        }

        var contactSentence = "Please contact us"
        if !bPhone.isEmpty {
            contactSentence += " by phone at \(bPhone)"
        }
        contactSentence += " to arrange payment."

        return """
        Hello \(invoice.customerDisplayName),

        \(timingSentence)

        • Invoice Number: \(invoice.number)
        • Balance Due: \(invoice.balanceDue.formatted(.appMoney))
        • Due Date: \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))

        \(contactSentence)

        ────────────────────────────────────────────
        Note: This is an automated notification sent from a no-reply address (\(systemNoReplyEmail)). Please do not reply directly to this email. Reach out to the business contact information above.

        Thank you,
        \(bName.isEmpty ? "The Team" : bName)
        """
    }
}
