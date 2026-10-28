//
//  GLGoldLifeIDSync.swift — My Business's one door to the person's Gold Life ID.
//
//  Law 48 / 48a (audit 2026-10-03 F19, F70): the person's name, contact, address, photo
//  and signature live ONLY in the shared Gold Life ID (GoldLifeID package). Screens read
//  them through `MBIdentity.shared`, and the signature is saved through the package's
//  engine (`updateIdentity`), never onto a local row.
//
//  A signature is shrunk to what the Gold Life ID server takes (`signatureForUpload`) before
//  it is saved. Pinned by GLSmallBusinessTests/IdentitySourceTests and SignatureUploadSizeTests.
//

import Foundation
import GoldLifeID
import ImageIO
import SwiftData
import UIKit

enum GLGoldLifeIDSync {

    /// The most a signature may weigh on its way to the Gold Life ID. The server refuses a
    /// `signature_png` over 1,400,000 base64 characters (about 1.05 MB); this leaves room.
    nonisolated static let signatureByteLimit = 1_000_000

    /// A signature that fits the Gold Life ID: a PNG (transparency kept) at most
    /// `ImageDownsampler.intakeMaxEdge` px on its long edge (law 62) and at most
    /// `signatureByteLimit` bytes. Data that already fits is returned unchanged; ImageIO
    /// thumbnailing shrinks the rest without decoding the full image. nil only when it
    /// can't be made to fit (not a picture, and too big to send as it is).
    nonisolated static func signatureForUpload(_ data: Data) -> Data? {
        let limit = signatureByteLimit
        let maxEdge = Double(ImageDownsampler.intakeMaxEdge)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            // Not a picture: it goes as it is if it fits, as before.
            return data.count <= limit ? data : nil
        }
        let longEdge = max(width, height)
        if data.count <= limit, longEdge <= maxEdge { return data }
        // PNG size follows the pixel count, so each try shrinks the edge by the square root of
        // how far over it is, a little more for margin; never past half or less than a tenth.
        var edge = min(longEdge, maxEdge).rounded(.down)
        for _ in 0..<8 {
            guard let image = ImageDownsampler.thumbnail(from: data, maxPixelSize: CGFloat(edge)),
                  let png = image.pngData() else { return nil }
            if png.count <= limit { return png }
            let step = min(0.9, max(0.5, (Double(limit) / Double(png.count)).squareRoot() * 0.95))
            edge = (edge * step).rounded(.down)
            guard edge >= 64 else { return nil }
        }
        return nil
    }
}

/// Why a signature couldn't be saved before it ever reached the Gold Life ID.
enum MBSignatureError: Error, Equatable {
    /// It can't be shrunk to what the Gold Life ID takes.
    case tooLarge
}

/// The signed-in person's Gold Life ID, as My Business reads and writes it. Sample data shows
/// the fleet's sample person (`GoldLifeIdentity.demo`) and keeps a signature in memory only:
/// nothing done in sample data reaches the real Gold Life ID.
@MainActor
@Observable
final class MBIdentity {
    static let shared = MBIdentity()

    /// The signature drawn while exploring sample data. Never sent anywhere.
    private var sampleSignature: Data?

    #if DEBUG
    /// DEBUG only (tests, simulator proof): a stand-in identity, launched with
    /// `-mbStubIdentityFirstName <name>`. Saves land on it, never on the server.
    var standIn: GoldLifeIdentity?
    #endif

    private init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-mbStubIdentityFirstName"), args.indices.contains(flag + 1) {
            var stub = GoldLifeIdentity.demo
            stub.firstName = args[flag + 1]
            standIn = stub
        }
        #endif
    }

    /// Sample data is showing (the demo launch flag or the person's "Explore sample data").
    var isSampleData: Bool { DemoMode.isActive || UserDemoMode.shared.isDemoActive }

    /// Who the person is right now.
    var current: GoldLifeIdentity {
        #if DEBUG
        if let standIn { return standIn }
        #endif
        if isSampleData {
            var sample = GoldLifeIdentity.demo
            sample.signatureData = sampleSignature
            return sample
        }
        return GoldLifeID.shared.identity
    }

    /// The saved signature (a transparent PNG), or nil.
    var signatureData: Data? { current.signatureData }

    /// Saves (`data`) or deletes (`nil`) the signature in the Gold Life ID. The signature is first
    /// shrunk to what the Gold Life ID takes (`signatureForUpload`); `MBSignatureError.tooLarge`
    /// when it can't be. Throws when the Gold Life ID refuses or can't be reached; nothing is
    /// changed then.
    func saveSignature(_ data: Data?, legacyIn context: ModelContext? = nil) async throws {
        var fitted: Data?
        if let data {
            fitted = await Task.detached(priority: .userInitiated) {
                GLGoldLifeIDSync.signatureForUpload(data)
            }.value
            guard fitted != nil else { throw MBSignatureError.tooLarge }
        }
        #if DEBUG
        if standIn != nil {
            standIn?.signatureData = fitted
            return
        }
        #endif
        if isSampleData {
            sampleSignature = fitted
            return
        }
        var edit = GoldLifeIdentityEdit()
        edit.signature = fitted.map { .set($0) } ?? .cleared
        _ = try await GoldLifeID.shared.updateIdentity(edit)
    }
}
