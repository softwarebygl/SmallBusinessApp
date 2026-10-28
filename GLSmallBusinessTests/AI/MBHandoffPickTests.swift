//
//  MBHandoffPickTests.swift
//  GLSmallBusinessTests — AI
//
//  Audit 2026-10-03 C72 (F65–F67), dormant assistant: a pick that ends meanwhile saves nothing;
//  a picture chosen from Files is shrunk to the fleet's 1024 px before it is held or stored; a
//  multi-page scan lands as ONE stitched upright image with every page in it.
//

import Foundation
import SwiftData
import Testing
import UIKit
import GoldLifeAI
@testable import GLSmallBusiness

@Suite(.serialized)
@MainActor
struct MBHandoffPickTests {

    private func solid(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.lightGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A raised pick request (the customer-photo picker) and the token of the host that owns it.
    private func raisedPick(_ world: MBWriteWorld) async throws
        -> (presenter: MBAIHandoffPresenter, token: UUID, answer: Task<GLAIHandoffOutcome, Never>) {
        let presenter = MBAIHandoffPresenter(environment: MBToolHarness.environment(world.context))
        let token = UUID()
        presenter.claim(token) { _ in }
        let handoff = GLAIHandoff(kind: "pick_media", payload: [
            "kind": "photo", "target": "customer_photo", "id": .string(world.customerID),
        ])
        let answer = Task { await presenter.present(handoff) }
        for _ in 0..<50 where presenter.presentationID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(presenter.presentationID != nil, "the pick should have been raised")
        return (presenter, token, answer)
    }

    // MARK: F65 — a pick that ended meanwhile saves nothing

    @Test func aPickThatWasCancelledWhileLoadingSavesNothing() async throws {
        let world = try MBWriteWorld()
        let (presenter, token, answer) = try await raisedPick(world)
        let startedAs = presenter.presentationID

        // The person closes it (or the session ends) while the picture is still loading.
        presenter.cancelPending()
        _ = await answer.value

        var saved = false
        presenter.commitPick(startedAs: startedAs, owner: token) { _ in
            saved = true
            return .cancelled()
        }
        #expect(!saved, "a request that ended must not be saved after the fact")
        #expect(presenter.presentation == nil)
    }

    @Test func aNewerRequestIsNotAnsweredByAnOlderPicksLateFinish() async throws {
        let world = try MBWriteWorld()
        let (presenter, token, first) = try await raisedPick(world)
        let oldID = presenter.presentationID
        presenter.cancelPending()
        _ = await first.value

        // A newer request takes over the screen.
        let handoff = GLAIHandoff(kind: "pick_media", payload: [
            "kind": "photo", "target": "customer_photo", "id": .string(world.customerID),
        ])
        let second = Task { await presenter.present(handoff) }
        for _ in 0..<50 where presenter.presentationID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let newID = presenter.presentationID
        #expect(newID != nil && newID != oldID)

        var saved = false
        presenter.commitPick(startedAs: oldID, owner: token) { _ in
            saved = true
            return .cancelled()
        }
        #expect(!saved, "the older pick must not save into the newer request")
        #expect(presenter.presentationID == newID, "the newer request is still waiting")

        presenter.cancelPending()
        _ = await second.value
    }

    @Test func aPickThatIsStillCurrentSaves() async throws {
        let world = try MBWriteWorld()
        let (presenter, token, answer) = try await raisedPick(world)
        var saved = false
        presenter.commitPick(startedAs: presenter.presentationID, owner: token) { _ in
            saved = true
            return .cancelled(message: "test")
        }
        #expect(saved)
        _ = await answer.value
        #expect(presenter.presentation == nil)
    }

    // MARK: F66 — a file picture is shrunk at intake

    @Test func aFilePictureIsStoredAtTheFleetSizeAndADocumentKeepsItsBytes() async throws {
        let big = solid(4032, 3024)
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("c72-\(UUID().uuidString).jpg")
        try #require(big.jpegData(compressionQuality: 0.8)).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let picked = try #require(await MBPickCommit.intakeFile(at: imageURL))
        #expect(picked.isImage)
        let stored = try #require(UIImage(data: picked.data))
        let longEdge = max(stored.size.width, stored.size.height) * stored.scale
        #expect(longEdge <= 1024, "a 4032 px file picture was stored at \(longEdge) px")

        let textURL = FileManager.default.temporaryDirectory.appendingPathComponent("c72-\(UUID().uuidString).txt")
        let bytes = Data("a quote".utf8)
        try bytes.write(to: textURL)
        defer { try? FileManager.default.removeItem(at: textURL) }
        let text = try #require(await MBPickCommit.intakeFile(at: textURL))
        #expect(!text.isImage)
        #expect(text.data == bytes)
    }

    // MARK: F67 — every page of a scan

    @Test func aThreePageScanIsStitchedIntoOneUprightImage() async throws {
        let pages = [solid(800, 1000), solid(800, 1000), solid(800, 1000)]
        let read = try #require(await MBPickCommit.readScan(pages))
        let stored = try #require(UIImage(data: read.data))
        let height = stored.size.height * stored.scale
        #expect(height >= 2900, "only part of the scan was kept (\(height) px tall)")
        #expect(stored.size.width * stored.scale <= 1024)
    }

    // MARK: C73 — share files protected, sanitized and cleaned up

    @Test func theYearEndReportFilesAreWrittenWithCompleteProtection() throws {
        let sub = TS.subcontractor(first: "Luis", last: "Mendoza", business: "Mendoza Plumbing")
        TS.paySub(sub, 2_400, date: TS.day(2026, 5, 1), detail: "Rough-in")
        let files = SubPayExport.files(subcontractors: [sub], year: 2026, business: nil)
        defer { SharedTempFiles.remove(files) }
        #expect(files.count == 2)
        for url in files {
            #expect(FileManager.default.fileExists(atPath: url.path))
            #if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete,
                    "\(url.lastPathComponent) is not protected at rest")
            #endif
        }
    }

    @Test func aSharedDocumentNameCannotLeaveTheTempFolderAndTheFileIsGoneWhenTheSheetCloses() async throws {
        let world = try MBWriteWorld()
        let profile = try #require(MBRecordLookup.businessProfile(in: world.context))
        profile.wcExemptionData = Data("exemption".utf8)
        profile.wcExemptionName = "../../evil.pdf"
        world.context.saveChanges()

        let presenter = MBAIHandoffPresenter(environment: MBToolHarness.environment(world.context))
        presenter.claim(UUID()) { _ in }
        let answer = Task {
            await presenter.present(GLAIHandoff(kind: "share_document",
                                                payload: ["document": "compliance_docs", "year": 2026]))
        }
        for _ in 0..<50 where presenter.presentationID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .share(let urls, _)? = presenter.presentation?.ui else {
            Issue.record("expected a share sheet")
            return
        }
        let url = try #require(urls.first)
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(url.standardizedFileURL.path.hasPrefix(temp), "the share file escaped the temp folder")
        #expect(!url.lastPathComponent.contains("/") && url.deletingLastPathComponent().standardizedFileURL.path
                    == FileManager.default.temporaryDirectory.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: url.path))

        presenter.finish(.cancelled(message: "closed"))
        _ = await answer.value
        #expect(!FileManager.default.fileExists(atPath: url.path), "the shared file was left on disk")
    }

    @Test func aFailedShareWriteIsAnHonestFailure() throws {
        // A folder where the file should go: the write fails, and nothing pretends it worked.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("c73-blocker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: blocker.appendingPathComponent("x"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blocker) }
        #expect((try? SharedTempFiles.write(Data("a".utf8), to: blocker.appendingPathComponent("x"))) == nil)
    }
}
