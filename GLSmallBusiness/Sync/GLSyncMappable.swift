//
//  GLSyncMappable.swift
//  GLSmallBusiness
//
//  The payload contract between our @Models and gl-business-api (platform Phase 3).
//  See GLSYNC-SPEC.md §6 for the rules and gl-business-api/sync-manifest.json for the
//  server's per-type enforcement — the `glSyncType` strings MUST match manifest keys.
//
//  Deliberately hand-written, no reflection: this layer has to stay readable by one person
//  with no AI help. The regression net that keeps it honest is the round-trip test plus the
//  property-count guard (GLSYNC-SPEC.md §8) — add a stored property to a @Model without
//  mapping it here and the suite fails.
//

import Foundation
import SwiftData

/// A JSON-ready payload. Values are restricted to what `JSONSerialization` accepts:
/// `String`, `Double`, `Int`, `Bool`, `[String: Any]`, `[Any]`, `NSNull`.
typealias GLSyncPayload = [String: Any]

protocol GLSyncMappable: AnyObject {
    /// The manifest key (snake_case) — must exist in gl-business-api/sync-manifest.json.
    static var glSyncType: String { get }
    /// The CASCADE parent's record id, when this type has one. Nullify-style references
    /// (a job's customer, a receipt's job) are ordinary payload fields, not the parent.
    var glSyncParentID: UUID? { get }
    /// The stable record identity (the Phase 0 `syncID`).
    var glSyncID: UUID? { get set }

    /// EVERY stored property, JSON-ready. Derived values (totals, balances) are never
    /// included — the server recomputes them and a stale total must not be able to land.
    func glSyncPayload() -> GLSyncPayload
    /// Apply a payload from the server. Unknown keys are ignored (payloads are additive);
    /// unknown enum values degrade to the default case, never crash.
    func glSyncApply(_ payload: GLSyncPayload, in context: ModelContext)
}

// MARK: - Value coding helpers
//
// One place per value kind, so 23 mappers cannot drift into 23 dialects. Every read helper
// is total: a missing, null, or wrong-typed value yields the supplied default rather than
// throwing, because a payload written by a newer build must never brick an older one.

enum GLSyncValue {

    // ---- write ------------------------------------------------------------------

    static func string(_ value: String) -> Any { value }
    static func double(_ value: Double) -> Any { value }
    static func int(_ value: Int) -> Any { value }
    static func bool(_ value: Bool) -> Any { value }

    static func optional(_ value: String?) -> Any { value ?? NSNull() }
    static func optional(_ value: Double?) -> Any { value ?? NSNull() }
    static func optional(_ value: Int?) -> Any { value ?? NSNull() }

    /// Dates ride as unix milliseconds — integer math, no locale, no ISO parsing drift. A date
    /// past what an Int holds (no picker makes one) is clamped, never converted with a trap.
    static func date(_ value: Date?) -> Any {
        guard let value else { return NSNull() }
        let millis = value.timeIntervalSince1970 * 1000
        if let exact = integer(millis) { return exact }
        if millis.isNaN { return NSNull() }
        return millis < 0 ? Int.min : Int.max
    }

    /// UUIDs ride as lowercase strings (the server keys rows on these).
    static func uuid(_ value: UUID?) -> Any {
        value.map { $0.uuidString.lowercased() } ?? NSNull()
    }

    /// `Address` rides as a JSON OBJECT — never flattened columns (GLSYNC-SPEC §6).
    static func address(_ value: Address?) -> Any {
        guard let value else { return NSNull() }
        return [
            "street1": value.street1,
            "street2": value.street2 ?? NSNull(),
            "city": value.city,
            "state": value.state,
            "postalCode": value.postalCode,
        ] as GLSyncPayload
    }

    /// A blob reference. The bytes go to `/attachments`; only the hash and label ride here.
    static func blobRef(sha256: String?, name: String?) -> Any {
        guard let sha256, !sha256.isEmpty else { return NSNull() }
        return ["sha256": sha256, "name": name ?? ""] as GLSyncPayload
    }

    /// Enums ride as raw strings.
    static func raw<T: RawRepresentable>(_ value: T?) -> Any where T.RawValue == String {
        value.map { $0.rawValue } ?? NSNull()
    }

    // ---- read -------------------------------------------------------------------

    static func string(_ payload: GLSyncPayload, _ key: String, default fallback: String = "") -> String {
        payload[key] as? String ?? fallback
    }

    static func optionalString(_ payload: GLSyncPayload, _ key: String) -> String? {
        payload[key] as? String
    }

    static func double(_ payload: GLSyncPayload, _ key: String, default fallback: Double = 0) -> Double {
        if let value = payload[key] as? Double { return value }
        if let value = payload[key] as? Int { return Double(value) }   // JSON 5 decodes as Int
        return fallback
    }

    static func optionalDouble(_ payload: GLSyncPayload, _ key: String) -> Double? {
        if let value = payload[key] as? Double { return value }
        if let value = payload[key] as? Int { return Double(value) }
        return nil
    }

    static func int(_ payload: GLSyncPayload, _ key: String, default fallback: Int = 0) -> Int {
        optionalInt(payload, key) ?? fallback
    }

    /// An integer, or nil when it's missing, not a number, or a Double outside Int's range
    /// (`Int(1e19)` traps, and the server doesn't range-check values — QA F64). An in-range
    /// Double truncates toward zero, as it always did.
    static func optionalInt(_ payload: GLSyncPayload, _ key: String) -> Int? {
        if let value = payload[key] as? Int { return value }
        if let value = payload[key] as? Double { return integer(value) }
        return nil
    }

    /// `value` truncated toward zero, or nil when it's NaN, infinite, or outside Int's range.
    static func integer(_ value: Double) -> Int? {
        Int(exactly: value.rounded(.towardZero))
    }

    static func bool(_ payload: GLSyncPayload, _ key: String, default fallback: Bool = false) -> Bool {
        payload[key] as? Bool ?? fallback
    }

    /// Nil for a value that isn't a whole-number range of milliseconds an Int holds, so a date
    /// read here can always be written back (`date(_:)`).
    static func date(_ payload: GLSyncPayload, _ key: String) -> Date? {
        guard let millis = optionalDouble(payload, key), integer(millis) != nil else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    static func uuid(_ payload: GLSyncPayload, _ key: String) -> UUID? {
        guard let raw = payload[key] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    static func address(_ payload: GLSyncPayload, _ key: String) -> Address? {
        guard let object = payload[key] as? GLSyncPayload else { return nil }
        return Address(
            street1: string(object, "street1"),
            street2: optionalString(object, "street2"),
            city: string(object, "city"),
            state: string(object, "state"),
            postalCode: string(object, "postalCode")
        )
    }

    /// The sha256 half of a blob reference (the bytes are fetched separately).
    static func blobSHA(_ payload: GLSyncPayload, _ key: String) -> String? {
        guard let object = payload[key] as? GLSyncPayload else { return nil }
        let sha = object["sha256"] as? String
        return (sha?.isEmpty ?? true) ? nil : sha
    }

    static func blobName(_ payload: GLSyncPayload, _ key: String) -> String {
        guard let object = payload[key] as? GLSyncPayload else { return "" }
        return object["name"] as? String ?? ""
    }

    /// Enum read that DEGRADES: an unknown raw value yields the supplied default rather
    /// than failing the record. Generalizes the shipped `PaymentMethod` → `.other` rule —
    /// no build from now on may ever reject a record written by a newer one.
    static func raw<T: RawRepresentable>(
        _ payload: GLSyncPayload, _ key: String, default fallback: T
    ) -> T where T.RawValue == String {
        guard let value = payload[key] as? String, let decoded = T(rawValue: value) else {
            return fallback
        }
        return decoded
    }
}
