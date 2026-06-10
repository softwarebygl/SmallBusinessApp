//
//  AccessCodes.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  ☆ The access-code registry — THIS is the file you edit to mint new codes. ☆
//
//  Codes are stored as SHA-256 HASHES, never as plaintext, so the real codes do not
//  exist anywhere in the source or the shipped app binary — they can't be extracted by
//  inspecting the app. To add a code, store the hash of its normalized form: just tell me
//  the code and I'll generate the hash (or call `AccessCodes.hash("YOUR-CODE")`).
//

import Foundation
import CryptoKit

/// How long a redeemed code grants its flag.
enum Grant {
    case lifetime        // never expires
    case until(Date)     // expires on a fixed date
    case days(Int)       // expires N days after it's redeemed (good for trials)
}

/// The code → flag registry.
///
/// Each entry stores the SHA-256 hash of a code (not the code itself). Matching ignores
/// case, dashes, and spaces — so `GL-7H4K-9TMQ`, `gl7h4k9tmq`, and `GL 7H4K 9TMQ` all match.
enum AccessCodes {
    struct Entry {
        let codeHash: String   // SHA-256 (hex) of the normalized code
        let flag: String
        let grant: Grant
    }

    static let registry: [Entry] = [
        // ── Lifetime unlocks ───────────────────────────────────────────────
        // Owner (you)
        Entry(codeHash: "ac39ef8292e7569f7cc048e3fb988bb53259e41db944a6ff84ddcab4b73a4c3a",
              flag: AccessFlag.unlimitedLifeAccess, grant: .lifetime),
        // Family (shared)
        Entry(codeHash: "0d31cf1e3f6e6137392b416e9f296fe04db522f67bd28f3b6abc398b4fdf06c1",
              flag: AccessFlag.unlimitedLifeAccess, grant: .lifetime),

        // ── Examples for later (give me the code, I'll add the hash) ────────
        // A 30-day trial code for a prospect:
        // Entry(codeHash: "…", flag: AccessFlag.unlimitedLifeAccess, grant: .days(30)),
    ]

    /// Strips everything but letters/numbers and uppercases — so dashes/spaces/case don't matter.
    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// SHA-256 (hex) of the normalized code — how entries are stored.
    static func hash(_ code: String) -> String {
        SHA256.hash(data: Data(normalize(code).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Finds the registry entry matching the user's input, if any.
    static func match(_ input: String) -> Entry? {
        guard !normalize(input).isEmpty else { return nil }
        let h = hash(input)
        return registry.first { $0.codeHash == h }
    }
}
