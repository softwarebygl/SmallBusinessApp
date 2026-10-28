//
//  MBReadToolQuarantineTests.swift
//  GLSmallBusinessTests — AI
//
//  THE QUARANTINE TEST (contract §5). A store with a fully populated record of every kind —
//  every blob set (certificates, photos, scans, logos, the W-9, the master agreement, the
//  signature), every quarantined text field planted with a sentinel (owner name, W-9 fields, the
//  tax ID, the card-payments account id and claim, the pay-link ids, the subcontractor's tax key,
//  the whole Gold Life ID person) — and every read tool's every output, online and on device:
//  find for every kind, get for every record (every page) and every singleton, every report,
//  every help section. It fails on:
//    • a key matching /tin|ssn|w9|signature|photo|image|logo|scan|stripe|token|claim|owner(First|Last)Name/i;
//    • a value that looks like an encoded blob (a long unbroken base64 run);
//    • any sentinel, the planted tax ID digits, or the blob's base64 anywhere in the text.
//

import Foundation
import SwiftData
import Testing
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBReadToolQuarantineTests {

    static let forbiddenKey = "tin|ssn|w9|signature|photo|image|logo|scan|stripe|token|claim|owner_?(first|last)_?name"
    static let base64Run = "^[A-Za-z0-9+/_-]{40,}={0,2}$"

    static func isForbiddenKey(_ key: String) -> Bool {
        key.range(of: forbiddenKey, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeBlob(_ value: String) -> Bool {
        value.range(of: base64Run, options: .regularExpression) != nil
    }

    @Test func noReadToolOutputCarriesAQuarantinedFieldOrABlob() async throws {
        let world = try MBToolWorld()
        let cards = FakeCardPayments()
        cards.answer = .success(StripePayLinkStatusResponse(status: "paid", amountPaidCents: 20_000, paidAt: 1_790_000_000_000))
        let box = try MBToolHarness.toolbox(world.context, cards: cards,
                                            pause: GLSyncBreakerTrip(deletions: 40, threshold: 25, at: MBToolHarness.now))
        var outputs: [(String, GLAIJSON)] = []

        for onDevice in [false, true] {
            let mode = onDevice ? "on device" : "online"
            // find, every kind — and every id it hands out, through get.
            for kind in MBRecordKind.allCases where !kind.isSingleton {
                let found = MBToolHarness.output(await MBToolHarness.run(box, "find", ["kind": .string(kind.rawValue)], onDevice: onDevice))
                outputs.append(("find \(kind.rawValue) \(mode)", found))
                #expect(!MBToolHarness.ids(found).isEmpty, "the world has a \(kind.rawValue) (\(mode))")
                for id in MBToolHarness.ids(found) {
                    var page = 1
                    repeat {
                        let got = MBToolHarness.output(await MBToolHarness.run(
                            box, "get", ["kind": .string(kind.rawValue), "id": .string(id), "page": .number(Double(page))],
                            onDevice: onDevice))
                        outputs.append(("get \(kind.rawValue) p\(page) \(mode)", got))
                        guard let next = got["next_page"]?.intValue else { break }
                        page = next
                    } while page < 50
                }
            }
            for kind in [MBRecordKind.business, .workSchedule, .appSettings] {
                outputs.append(("get \(kind.rawValue) \(mode)", MBToolHarness.output(await MBToolHarness.run(
                    box, "get", ["kind": .string(kind.rawValue)], onDevice: onDevice))))
            }
            let jobID = world.job.syncID?.uuidString ?? ""
            let invoiceID = world.invoice.syncID?.uuidString ?? ""
            let reports: [GLAIJSON] = [
                ["kind": "money_summary", "date_from": "2026-01-01", "date_to": "2026-12-31", "query": "tile"],
                ["kind": "owed_to_me"], ["kind": "i_owe"],
                ["kind": "schedule", "date_from": "2026-09-20", "date_to": "2026-09-30"],
                ["kind": "openings"], ["kind": "expiring_documents"], ["kind": "estimate_pipeline"],
                ["kind": "job_profit", "id": .string(jobID)], ["kind": "backup_status"],
            ] + (onDevice ? [] : [["kind": "payments_setup"], ["kind": "card_payment_status", "id": .string(invoiceID)]])
            for args in reports {
                outputs.append(("report \(args["kind"]?.stringValue ?? "") \(mode)",
                                MBToolHarness.output(await MBToolHarness.run(box, "report", args, onDevice: onDevice))))
            }
        }
        for section in ["how_to", "whats_new", "about"] {
            outputs.append(("help \(section)", MBToolHarness.output(await MBToolHarness.run(
                box, "help", ["question": "how do I set my tax details and logo", "section": .string(section)]))))
        }
        #expect(cards.calls.count == 1, "the card-payment report asked the Worker once")
        #expect(outputs.count > 80)

        for (label, output) in outputs {
            let text = output.serializedString
            for key in Self.keys(in: output) {
                #expect(!Self.isForbiddenKey(key), "\(label): quarantined key \(key)")
            }
            for value in output.allStrings {
                #expect(!Self.looksLikeBlob(value), "\(label): blob-like value \(value.prefix(60))")
            }
            #expect(!text.contains(MBToolWorld.sentinel), "\(label): a quarantined field leaked: \(text)")
            #expect(!text.contains(MBToolWorld.taxID), "\(label): the tax ID leaked")
            #expect(!text.contains(MBToolWorld.blobBase64Prefix), "\(label): a blob leaked")
            #expect(output.serializedByteCount <= GLAIWire.maxToolOutputBytes, "\(label): over 8 KB")
            if label.hasSuffix("on device") {
                #expect(text.count <= 1_200, "\(label): over the on-device budget (\(text.count))")
            }
        }
    }

    /// The quarantine regex itself: it would catch what it is for (so a green run means something).
    @Test func theTripwireCatchesWhatItIsFor() {
        for key in ["tin_key", "w9_name", "owner_first_name", "ownerLastName", "logo_data", "scan_data",
                    "stripe_account", "account_claim", "photo", "signature_data", "session_token", "ssn"] {
            #expect(Self.isForbiddenKey(key), "\(key)")
        }
        #expect(Self.looksLikeBlob(MBToolWorld.blob.base64EncodedString()))
        #expect(!Self.looksLikeBlob(UUID().uuidString), "ids are not blobs")
    }

    static func keys(in value: GLAIJSON) -> [String] {
        switch value {
        case .object(let object): return object.keys.map { $0 } + object.values.flatMap(keys(in:))
        case .array(let array): return array.flatMap(keys(in:))
        default: return []
        }
    }
}
