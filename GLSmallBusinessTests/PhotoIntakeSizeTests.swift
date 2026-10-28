//
//  PhotoIntakeSizeTests.swift
//  GLSmallBusinessTests
//
//  Photo Intake Memory Defense (REQUIREMENTS law 62): every picked photo is shrunk to at most
//  1024 px on its long edge, upright, OFF the main thread, before anything holds, crops or
//  stores it. 2026-10-03 audit F40: job and invoice photos were stored at 2048 px, avatar and
//  logo picks were fully decoded (a 48 MP pick is ~190 MB) and handed to the crop screen, a
//  contact's photo was re-encoded at full size, and a failed crop saved the uncropped original.
//  F157: My Business kept its own crop screen although `GLSquarePhotoCropper` is the fleet one.
//
//  The size facts are checked on real pixels. Which screen calls what is a fact about CALL
//  SITES (a missing call), so those are pinned with a source scan (`GLSource`).
//

import Testing
import Foundation
import Contacts
import ImageIO
import UIKit
import GoldLifeUI
@testable import GLSmallBusiness

struct PhotoIntakeSizeTests {

    /// A 4032 x 3024 photo (a 12 MP iPhone shot), as JPEG bytes.
    private func bigJPEG(width: Int = 4032, height: Int = 3024) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        }
        return try #require(image.jpegData(compressionQuality: 0.6))
    }

    /// Pixel size of encoded image bytes, read by ImageIO without decoding the picture.
    private func pixelSize(of data: Data) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let h = try #require(props[kCGImagePropertyPixelHeight] as? Int)
        return CGSize(width: w, height: h)
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    // MARK: - Sizes, on real pixels

    /// Job and invoice photos are stored as `intakeJPEG` hands them back: 1024 on the long edge.
    @Test func aJobOrInvoicePickIsStoredAt1024() async throws {
        let stored = try #require(await ImageDownsampler.intakeJPEG(from: try bigJPEG()))
        let size = try pixelSize(of: stored)
        #expect(max(size.width, size.height) <= 1024, "stored at \(size)")
        #expect(max(size.width, size.height) >= 1000, "shrunk far below the 1024 rule: \(size)")
    }

    /// Avatar, logo and receipt picks go to the cropper / form as `intakeImage`: never the full
    /// 12 MP decode.
    @Test func anAvatarOrLogoPickReachesTheCropperAt1024() async throws {
        let image = try #require(await ImageDownsampler.intakeImage(from: try bigJPEG()))
        let size = pixelSize(of: image)
        #expect(max(size.width, size.height) <= 1024, "handed to the cropper at \(size)")
    }

    /// A contact's picture is stored at 1024 or less, not re-encoded at full size.
    @Test func aContactPhotoIsStoredAt1024OrLess() throws {
        let contact = CNMutableContact()
        contact.givenName = "Big"
        contact.imageData = try bigJPEG()
        let stored = try #require(ContactsBridge.draft(from: contact as CNContact).imageData)
        let size = try pixelSize(of: stored)
        #expect(max(size.width, size.height) <= 1024, "a contact photo was stored at \(size)")
    }

    /// A cropped avatar or logo is saved at the crop screen's 600 px square: a 12 MP pick goes
    /// in through the intake, the square comes out at 600 x 600 and is stored as such.
    @Test func aCroppedAvatarOrLogoIsStoredAt600() async throws {
        let picked = try #require(await ImageDownsampler.intakeImage(from: try bigJPEG()))
        let rendered = await GLSquareCropRenderer.renderDetached(picked, crop: .centered,
                                                                maxSide: ImageDownsampler.croppedSide)
        let square = try #require(rendered)
        let stored = try #require(square.jpegData(compressionQuality: 0.85))
        #expect(try pixelSize(of: stored) == CGSize(width: 600, height: 600))
    }

    /// A list row's avatar is decoded small, off the main thread: a full-size stored photo (an
    /// old crop that fell back to the original) is never decoded at 12 MP per row.
    @Test func aRowAvatarIsDecodedAtThreeTimesItsSize() async throws {
        let image = try #require(await ProfileAvatar.thumbnail(from: try bigJPEG(), size: 48))
        let size = pixelSize(of: image)
        #expect(max(size.width, size.height) <= ProfileAvatar.pixelSide(for: 48), "decoded at \(size)")
        #expect(ProfileAvatar.pixelSide(for: 48) == 144)
    }

    // MARK: - Call sites (source scan)

    /// Every screen that takes a photo pick routes it through the 1024 px intake, and none
    /// decodes the pick at full size or keeps the old 2048 px storage size.
    @Test func everyPhotoPickGoesThroughTheIntake() throws {
        let sites: [(file: String, intake: String)] = [
            ("Screens/JobDetailScreen.swift", "ImageDownsampler.intakeJPEG(from:"),
            ("Screens/InvoiceDetailScreen.swift", "ImageDownsampler.intakeJPEG(from:"),
            ("Screens/CustomerDetailScreen.swift", "ImageDownsampler.intakeImage(from:"),
            ("Screens/EmployeeDetailScreen.swift", "ImageDownsampler.intakeImage(from:"),
            ("Screens/SubcontractorDetailScreen.swift", "ImageDownsampler.intakeImage(from:"),
            ("Screens/MenuScreen.swift", "ImageDownsampler.intakeImage(from:"),
            ("Screens/ReceiptFormScreen.swift", "ImageDownsampler.intakeImage(from:"),
            ("Screens/ZelleConnectScreen.swift", "ImageDownsampler.intakeJPEG(from:"),
        ]
        for site in sites {
            let code = try #require(GLSource.code(site.file), "\(site.file) is missing")
            let routes = code.contains(site.intake)
            let keeps2048 = code.contains("maxPixelSize: 2048")
            // The pick's own guard (from loading the bytes to its `else`) never decodes them whole.
            let decodesFull = code.components(separatedBy: "loadTransferable(type: Data.self)").dropFirst()
                .contains { $0.components(separatedBy: "else").first?.contains("UIImage(data:") == true }
            #expect(routes, "\(site.file) does not route its pick through \(site.intake)")
            #expect(!keeps2048, "\(site.file) still stores picks at 2048 px")
            #expect(!decodesFull, "\(site.file) decodes a pick at full size on the main actor")
        }
    }

    /// One crop screen for the fleet: My Business's own `ImageCropView` is gone and every crop
    /// (customer, employee, subcontractor photo; the business logo; the assistant's logo
    /// handoff) uses GoldLifeUI's `GLSquarePhotoCropper`, whose failure keeps the screen open
    /// instead of saving the uncropped original.
    @Test func theAppUsesTheFleetCropper() throws {
        #expect(GLSource.file("UIComponents/ImageCropView.swift") == nil, "My Business still ships its own crop screen")
        let offenders = GLSource.codeFiles().filter { $0.text.contains("ImageCropView(") }.map(\.path)
        #expect(offenders.isEmpty, "still uses ImageCropView: \(offenders)")
        for file in ["Screens/CustomerDetailScreen.swift", "Screens/EmployeeDetailScreen.swift",
                     "Screens/SubcontractorDetailScreen.swift", "Screens/MenuScreen.swift",
                     "AI/MBAIHandoffHost.swift"] {
            let code = try #require(GLSource.code(file), "\(file) is missing")
            let usesFleetCropper = code.contains("GLSquarePhotoCropper(")
            #expect(usesFleetCropper, "\(file) does not use the fleet cropper")
        }
    }
}
