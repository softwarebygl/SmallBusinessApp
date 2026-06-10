//
//  AccessCodes.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC.
//
//  ☆ The access-code registry — THIS is the file you edit to mint new codes. ☆
//
//  Codes follow the format GL-XXXX-XXXX and are stored as SHA-256 HASHES, never as plaintext,
//  so the real codes do not exist anywhere in the source or the shipped binary. To add a code,
//  just tell me the code and I'll add its hash (or call `AccessCodes.hash("GL-XXXX-XXXX")`).
//

import Foundation
import CryptoKit

/// How long a redeemed code grants its flag.
enum Grant {
    case lifetime        // never expires
    case until(Date)     // expires on a fixed date
    case days(Int)       // expires N days after it's redeemed (good for trials)
}

/// The code → flag registry. Each entry stores the SHA-256 hash of the full `GL-XXXX-XXXX` code.
enum AccessCodes {
    struct Entry {
        let codeHash: String   // SHA-256 (hex) of the uppercased full code
        let flag: String
        let grant: Grant
    }

    static let registry: [Entry] = [
        // ── Lifetime unlocks ───────────────────────────────────────────────
        // Owner (you)
        Entry(codeHash: "826f64f6e0c694c911a611f007f0fb29be701b60e5759ed5fc889badf8f10fb6",
              flag: AccessFlag.unlimitedLifeAccess, grant: .lifetime),
        // Family (shared)
        Entry(codeHash: "c8d9cfde1c033ab5094613383911b4b21527c2cfa44ff63ffd1013ba857178e3",
              flag: AccessFlag.unlimitedLifeAccess, grant: .lifetime),

        // ── Examples for later (give me the code, I'll add the hash) ────────
        // A 30-day trial code for a prospect (format GL-XXXX-XXXX):
        // Entry(codeHash: "…", flag: AccessFlag.unlimitedLifeAccess, grant: .days(30)),
    ]

    /// SHA-256 (hex) of the uppercased code — how entries are stored. Uppercasing makes the match
    /// case-proof; the dashes are part of the hashed string.
    static func hash(_ code: String) -> String {
        SHA256.hash(data: Data(code.uppercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Finds the registry entry matching a full `GL-XXXX-XXXX` code, if any.
    static func match(_ fullCode: String) -> Entry? {
        let h = hash(fullCode)
        return registry.first { $0.codeHash == h }
    }
}
