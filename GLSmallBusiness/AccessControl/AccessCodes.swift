//
//  AccessCodes.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  ☆ The access-code registry — THIS is the file you edit to mint new codes. ☆
//

import Foundation

/// How long a redeemed code grants its flag.
enum Grant {
    case lifetime        // never expires
    case until(Date)     // expires on a fixed date
    case days(Int)       // expires N days after it's redeemed (good for trials)
}

/// The code → flag registry.
///
/// To mint a new code, add an `Entry` with the code, the flag it unlocks, and how long it
/// lasts. Matching ignores case, dashes, and spaces — so `GL-7H4K-9TMQ`, `gl7h4k9tmq`, and
/// `GL 7H4K 9TMQ` are all the same code.
enum AccessCodes {
    struct Entry {
        let code: String
        let flag: String
        let grant: Grant
    }

    static let registry: [Entry] = [
        // ── Lifetime unlocks ───────────────────────────────────────────────
        Entry(code: "GL-7H4K-9TMQ", flag: AccessFlag.unlimitedLifeAccess, grant: .lifetime),  // Owner (you)
        Entry(code: "GL-3F8R-2WNP", flag: AccessFlag.unlimitedLifeAccess, grant: .lifetime),  // Family (shared)

        // ── Examples for later (uncomment / copy) ──────────────────────────
        // Hand a prospect 30 days of full access:
        // Entry(code: "TRY-GL-30", flag: AccessFlag.unlimitedLifeAccess, grant: .days(30)),
    ]

    /// Strips everything but letters/numbers and uppercases — so dashes/spaces/case don't matter.
    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Finds the registry entry matching the user's input, if any.
    static func match(_ input: String) -> Entry? {
        let needle = normalize(input)
        guard !needle.isEmpty else { return nil }
        return registry.first { normalize($0.code) == needle }
    }
}
