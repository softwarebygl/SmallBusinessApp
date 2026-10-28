//
//  GLCertificateStatus.swift — is this certificate still good?
//
//  Added 2026-09-01 after an IA audit found the app asserting coverage it could not
//  support: a COI that expired in March still drew a gold verified seal and still
//  merged silently into an outgoing Contractor Package. A GC rejects an expired
//  certificate on the spot, so "is mine current" is a weekly question — but the
//  model only knew PRESENCE (`hasCOI` is a Bool), never validity.
//
//  One rule, in one place, so every certificate slot answers it identically:
//  General Liability, Workers' Comp, a subcontractor's COI, the WC exemption, and
//  the contractor licence.
//

import Foundation

nonisolated enum GLCertificateStatus {

    /// How close to expiry still counts as "renew this soon".
    static let warningWindowDays = 30

    /// UNKNOWN IS NOT EXPIRED. A nil date means the owner never typed one in — for
    /// every row that predates this feature, that is all of them. Treating nil as
    /// expired would paint the whole app red on first launch after updating and
    /// train people to ignore the warning, which is worse than not having one.
    static func isExpired(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date < Calendar.current.startOfDay(for: .now)
    }

    /// Still valid, but not for long.
    static func isExpiringSoon(_ date: Date?) -> Bool {
        guard let date, !isExpired(date) else { return false }
        guard let edge = Calendar.current.date(byAdding: .day, value: warningWindowDays, to: .now) else { return false }
        return date <= edge
    }

    /// The caption under a certificate's filename. Nil when there is nothing honest
    /// to say — an unknown date gets no claim in either direction.
    /// @MainActor: mbLoc reads the observed language (zero-warnings pass, 2026-09-01).
    @MainActor
    static func caption(_ date: Date?) -> String? {
        guard let date else { return nil }
        let when = date.formatted(.dateTime.month(.abbreviated).day().year().locale(MBLocalization.currentLocale))
        if isExpired(date) { return String(format: mbLoc("Expired %@"), when) }
        if isExpiringSoon(date) { return String(format: mbLoc("Expires %@"), when) }
        return String(format: mbLoc("Good through %@"), when)
    }
}
