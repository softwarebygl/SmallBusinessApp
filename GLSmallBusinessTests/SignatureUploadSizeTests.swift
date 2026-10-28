//
//  SignatureUploadSizeTests.swift — a saved signature always fits the Gold Life ID.
//
//  The Gold Life ID server refuses a signature_png over 1,400,000 base64 characters
//  (about 1 MB). A phone photo of a signature on ordinary paper keeps most of its pixels
//  after the white knockout, so a full-size import came out at 3-12 MB and every save was
//  refused; a 3.2 phone's saved photo signature was refused by the one-release upload too.
//  Audit 2026-10-03 C33 (repair). Law 62: a picked photo is shrunk to 1024 px as it comes in.
//

import Testing
import Foundation
import SwiftData
import UIKit
import ImageIO
import GoldLifeID
@testable import GLSmallBusiness

@Suite("Signature upload size", .serialized)
@MainActor
struct SignatureUploadSizeTests {

    // MARK: - Pictures

    /// A camera photo of a signature on paper: gray paper with per-pixel grain and a dark
    /// ink band, JPEG-encoded the way the photo library hands it over.
    private static func paperPhotoJPEG(width: Int, height: Int, paper: Int, grain: Int) -> Data? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let span = UInt64(2 * grain + 1)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<(width * height) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let x = index % width, y = index / width
                let ink = y > height * 45 / 100 && y < height * 55 / 100 && x > width / 5 && x < width * 4 / 5
                let value = ink ? UInt8(30) : UInt8(clamping: paper + Int(state % span) - grain)
                buffer[index * 4] = value
                buffer[index * 4 + 1] = value
                buffer[index * 4 + 2] = value
            }
        }
        return image(from: &pixels, width: width, height: height, alpha: .noneSkipLast)?
            .jpegData(compressionQuality: 0.9)
    }

    /// A PNG of pure color noise, which no encoder can shrink: about 4 bytes a pixel.
    private static func noisePNG(width: Int, height: Int) -> Data? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        pixels.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<(width * height) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                buffer[index * 4] = UInt8(truncatingIfNeeded: state)
                buffer[index * 4 + 1] = UInt8(truncatingIfNeeded: state >> 8)
                buffer[index * 4 + 2] = UInt8(truncatingIfNeeded: state >> 16)
            }
        }
        return image(from: &pixels, width: width, height: height, alpha: .premultipliedLast)?.pngData()
    }

    private static func image(from pixels: inout [UInt8], width: Int, height: Int,
                              alpha: CGImageAlphaInfo) -> UIImage? {
        let cg: CGImage? = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: alpha.rawValue)?.makeImage()
        }
        return cg.map { UIImage(cgImage: $0) }
    }

    /// The decoded picture inside `data`, or nil when it isn't one.
    private static func decoded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// How many pixels are fully transparent.
    private static func clearPixels(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] == 0 ? 1 : 0) }
    }

    private static let limit = GLGoldLifeIDSync.signatureByteLimit

    // MARK: - The import path

    @Test("A 12 MP phone photo of a signature on paper saves under the Gold Life ID's cap, transparency kept",
          arguments: [215, 232])
    func importedPhotoFits(paper: Int) async throws {
        let photo = try #require(Self.paperPhotoJPEG(width: 4032, height: 3024, paper: paper, grain: 6))

        // What SignatureEditorSheet does: shrink at intake, knock out the paper, then save.
        let picked = try #require(await SignatureEditorSheet.importedSignatureImage(from: photo))
        #expect(max(picked.size.width * picked.scale, picked.size.height * picked.scale) <= 1024,
                "the picked photo is held at full size (law 62: 1024 px at intake)")
        let knockedOut = try #require(SignatureRender.transparentPNG(from: picked))
        let sent = try #require(GLGoldLifeIDSync.signatureForUpload(knockedOut))

        #expect(sent.count <= Self.limit, "\(sent.count) bytes; the Gold Life ID refuses over about 1 MB")
        let image = try #require(Self.decoded(sent))
        #expect(max(image.width, image.height) <= 1024)
        #expect(Self.hasAlphaChannel(image), "the signature lost its transparency")
        if paper > 225 {
            #expect(Self.clearPixels(in: image) > 0, "white paper should be knocked out")
        }
    }

    @Test("A signature that already fits is sent exactly as it is")
    func fittingSignatureIsUnchanged() throws {
        let small = try #require(Self.noisePNG(width: 300, height: 120))
        #expect(small.count <= Self.limit)
        #expect(GLGoldLifeIDSync.signatureForUpload(small) == small)
        #expect(GLGoldLifeIDSync.signatureForUpload(Data([0x09])) == Data([0x09]),
                "small bytes that aren't a picture pass through as before")
    }

    @Test("Too big and not a picture: nothing is sent")
    func oversizedNonPictureIsRefused() {
        #expect(GLGoldLifeIDSync.signatureForUpload(Data(count: Self.limit + 1)) == nil)
    }

    // MARK: - Saving from the editor

    @Test("Saving an oversized signature sends one the Gold Life ID takes")
    func savedSignatureIsShrunk() async throws {
        let big = try #require(Self.noisePNG(width: 1100, height: 900))
        let identity = MBIdentity.shared
        identity.standIn = .demo
        defer { identity.standIn = nil }

        try await identity.saveSignature(big, legacyIn: nil)
        let sent = try #require(identity.signatureData)
        #expect(sent.count <= Self.limit, "\(sent.count) bytes; the Gold Life ID refuses over about 1 MB")
        let image = try #require(Self.decoded(sent))
        #expect(max(image.width, image.height) <= 1024)
    }

    @Test("A signature that can't be made to fit is refused honestly, and nothing changes")
    func unfittableSignatureThrows() async throws {
        let identity = MBIdentity.shared
        var held = GoldLifeIdentity.demo
        held.signatureData = Data([0x07])
        identity.standIn = held
        defer { identity.standIn = nil }

        await #expect(throws: MBSignatureError.tooLarge) {
            try await identity.saveSignature(Data(count: Self.limit + 1), legacyIn: nil)
        }
        #expect(identity.signatureData == Data([0x07]), "the saved signature was replaced or lost")
    }

    @Test("The editor tells the person the photo is too large, never to try again in a minute")
    func editorNamesTheTooLargeCase() throws {
        let code = try #require(GLSource.code("Screens/SignatureEditorSheet.swift"))
        #expect(code.contains("catch MBSignatureError.tooLarge"))
        #expect(code.contains("That photo is too large for a signature."))
    }
}
