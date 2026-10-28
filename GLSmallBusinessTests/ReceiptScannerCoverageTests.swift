//
//  ReceiptScannerCoverageTests.swift
//
//  Receipt OCR and the heuristics that turn recognized lines into a vendor, a
//  date and a total. This file was 0% covered — nothing exercised the parser at
//  all, even though every extraction rule in it is a guess that can be wrong in
//  a way that quietly puts the WRONG NUMBER on an expense.
//
//  The heuristics are private, so these drive the real entry point, `parse`, over
//  rendered receipts. Vision's text recognition runs on the Simulator (only the
//  camera doesn't), so this is a genuine end-to-end pass, not a stub.
//
//  Assertions are written to be robust against ordinary OCR wobble: they check
//  the DECISIONS the parser makes (which amount wins, whether a subtotal is
//  rejected) rather than demanding a perfect character-for-character read.
//

import Testing
import Foundation
import UIKit
@testable import GLSmallBusiness

struct ReceiptScannerCoverageTests {

    // MARK: - Fixtures

    /// Renders receipt-like text as a crisp black-on-white image — what the OCR
    /// path actually consumes.
    private func receipt(_ lines: [String], width: CGFloat = 700) -> UIImage {
        let lineHeight: CGFloat = 46
        let size = CGSize(width: width, height: lineHeight * CGFloat(lines.count) + 60)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 30, y: 30 + CGFloat(i) * lineHeight),
                    withAttributes: attributes)
            }
        }
    }

    private func blankImage(_ size: CGSize = CGSize(width: 400, height: 400)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Error cases

    /// An image with no CoreGraphics backing (a filter output that was never
    /// rendered) can't be OCR'd. It must come back EMPTY rather than trapping —
    /// this is reachable from a photo picked out of an editing app.
    @Test func imageWithoutCGImageYieldsAnEmptyResult() async {
        let ciOnly = UIImage(ciImage: CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(ciOnly.cgImage == nil, "fixture is only meaningful without a CGImage backing")

        let result = await ReceiptScanner.parse(ciOnly)
        #expect(result.vendor.isEmpty)
        #expect(result.total == nil)
        #expect(result.date == nil)
        #expect(result.recognizedText.isEmpty)
    }

    /// A blank page — a photo of the back of a receipt, or a picture of a desk.
    /// Nothing is invented: no vendor, no total.
    @Test func blankImageFindsNothing() async {
        let result = await ReceiptScanner.parse(blankImage())
        #expect(result.vendor.isEmpty)
        #expect(result.total == nil)
    }

    /// A zero-area image must not crash the parser.
    @Test func degenerateImageIsSurvivable() async {
        let tiny = blankImage(CGSize(width: 1, height: 1))
        let result = await ReceiptScanner.parse(tiny)
        #expect(result.total == nil)
    }

    // MARK: - End-to-end OCR (the real Vision path)

    /// A genuine end-to-end pass: render a receipt, OCR it, and check the pipeline
    /// produced something. Deliberately loose — this asserts that recognition and
    /// extraction are WIRED TOGETHER, not that Vision reads every glyph perfectly.
    /// The exact extraction rules are pinned deterministically below.
    @Test func endToEndOCRReadsARenderedReceipt() async {
        let result = await ReceiptScanner.parse(receipt([
            "HOME DEPOT",
            "GROUT SANDED 25LB      18.97",
            "TOTAL                  25.11",
        ]))
        #expect(!result.recognizedText.isEmpty, "OCR recognized nothing at all")
        #expect(!result.vendor.isEmpty, "no vendor line was recognized")
        #expect(result.total != nil, "no amount was extracted from a receipt with a total")
    }

    // MARK: - Extraction rules (deterministic — no OCR in the loop)

    /// The ordinary receipt: vendor at the top, total at the bottom.
    @Test func readsVendorAndTotalFromAnOrdinaryReceipt() {
        let result = ReceiptScanner.parse(lines: [
            "HOME DEPOT",
            "1234 APALACHEE PKWY",
            "GROUT SANDED 25LB      18.97",
            "TILE SPACERS            4.50",
            "SUBTOTAL               23.47",
            "TAX                     1.64",
            "TOTAL                  25.11",
        ])
        #expect(result.vendor == "HOME DEPOT")
        #expect(result.total == 25.11)
    }

    /// The rule that costs real money if it breaks: a SUBTOTAL line must never be taken
    /// as the total. Here the subtotal is LARGER than the total, so a parser that simply
    /// took the biggest number would fail.
    @Test func subtotalNeverWinsOverTotal() {
        let result = ReceiptScanner.parse(lines: [
            "FLOOR & DECOR",
            "SUBTOTAL              940.00",
            "DISCOUNT             -100.00",
            "TOTAL                 840.00",
        ])
        #expect(result.total == 840.00)
    }

    /// "SUB TOTAL" as two words is excluded too — receipt printers write it both ways,
    /// and only one spelling being handled is the kind of gap that survives review.
    @Test func spacedSubTotalIsAlsoExcluded() {
        let result = ReceiptScanner.parse(lines: [
            "LOWES",
            "SUB TOTAL             500.00",
            "TOTAL                 535.00",
        ])
        #expect(result.total == 535.00)
    }

    /// Case doesn't matter — receipts print "Total", "TOTAL" and "total".
    @Test func totalMatchingIsCaseInsensitive() {
        for spelling in ["Total", "TOTAL", "total", "Grand Total"] {
            let result = ReceiptScanner.parse(lines: ["SHOP", "\(spelling)   42.00", "ITEM  99.00"])
            #expect(result.total == 42.00, "\(spelling) was not recognized as the total")
        }
    }

    /// With no line saying "total", the largest amount is the fallback.
    @Test func fallsBackToTheLargestAmountWhenNoTotalLineExists() {
        let result = ReceiptScanner.parse(lines: [
            "CORNER HARDWARE",
            "THINSET                12.00",
            "TROWEL                 31.25",
        ])
        #expect(result.total == 31.25)
    }

    /// Thousands separators are stripped, so a big material order reads as 1234.56 and
    /// not 1.00 — a parse error that would understate an expense by three orders of
    /// magnitude.
    @Test func commaThousandsAreParsedAsOneAmount() {
        let result = ReceiptScanner.parse(lines: ["STONE SUPPLY CO", "TOTAL   1,234.56"])
        #expect(result.total == 1234.56)
    }

    /// Multiple totals on one receipt (a reprint, or a split tender) take the largest,
    /// which is the one that represents the whole sale.
    @Test func theLargestTotalWinsWhenSeveralAreLabelled() {
        let result = ReceiptScanner.parse(lines: [
            "SUPPLY HOUSE", "TOTAL   40.00", "TOTAL   60.00",
        ])
        #expect(result.total == 60.00)
    }

    /// A date anywhere in the text is picked up, so the expense dates itself.
    @Test func findsTheReceiptDate() throws {
        let result = ReceiptScanner.parse(lines: [
            "TILE OUTLET", "03/14/2026  10:42 AM", "TOTAL   60.00",
        ])
        let found = try #require(result.date)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: found)
        #expect(parts.year == 2026)
        #expect(parts.month == 3)
        #expect(parts.day == 14)
    }

    /// A receipt with no date leaves the field nil rather than defaulting to today — a
    /// silently-wrong date is worse than an empty one the owner fills in.
    @Test func missingDateStaysNil() {
        #expect(ReceiptScanner.parse(lines: ["QUICK MART", "TOTAL   9.99"]).date == nil)
    }

    /// The vendor is the first line with real letters, so a receipt opening with a store
    /// or phone number doesn't become the vendor.
    @Test func vendorSkipsLeadingNumericLines() {
        let result = ReceiptScanner.parse(lines: [
            "0451", "8503551234", "SUMMIT TILE", "TOTAL   75.00",
        ])
        #expect(result.vendor == "SUMMIT TILE")
    }

    /// Two letters isn't a name; three is. Pins the threshold the rule actually uses.
    @Test func vendorNeedsAtLeastThreeLetters() {
        #expect(ReceiptScanner.parse(lines: ["12", "AB", "ACE HARDWARE"]).vendor == "ACE HARDWARE")
        #expect(ReceiptScanner.parse(lines: ["AB", "12"]).vendor.isEmpty)
    }

    /// The vendor is trimmed, so leading receipt padding doesn't ride along into the
    /// expense's name field.
    @Test func vendorIsTrimmed() {
        #expect(ReceiptScanner.parse(lines: ["    SUMMIT TILE   "]).vendor == "SUMMIT TILE")
    }

    /// Amounts without two decimal places aren't currency — a quantity or a store number
    /// must not be read as the total.
    @Test func nonCurrencyNumbersAreIgnored() {
        let result = ReceiptScanner.parse(lines: [
            "PAINT DEPOT", "QTY 12", "STORE 4501", "TOTAL   18.00",
        ])
        #expect(result.total == 18.00)
    }

    /// A receipt with no amounts at all yields no total rather than zero — "$0.00" would
    /// look like a real, free purchase.
    @Test func aReceiptWithNoAmountsHasNoTotal() {
        #expect(ReceiptScanner.parse(lines: ["THANK YOU FOR SHOPPING"]).total == nil)
    }

    /// No lines at all — the empty case the OCR path hands over when it recognizes
    /// nothing.
    @Test func emptyLinesProduceAnEmptyReceipt() {
        let result = ReceiptScanner.parse(lines: [])
        #expect(result.vendor.isEmpty)
        #expect(result.total == nil)
        #expect(result.date == nil)
        #expect(result.recognizedText.isEmpty)
    }

    /// The recognized text is preserved verbatim so the owner can check what was read.
    @Test func recognizedTextKeepsEveryLine() {
        let lines = ["ACE HARDWARE", "TOTAL   10.00"]
        #expect(ReceiptScanner.parse(lines: lines).recognizedText == lines.joined(separator: "\n"))
    }

    // MARK: - Scan pages and orientation (law 62 receipt ruling, F41/F151)

    /// A letter page as VisionKit hands it over: 1700 × 2200 px (200 dpi), with `lines` in big
    /// black type at the top.
    private func scannedPage(_ lines: [String]) -> UIImage {
        let size = CGSize(width: 1700, height: 2200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 80, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 80, y: 120 + CGFloat(i) * 130), withAttributes: attributes)
            }
        }
    }

    private func pixelSize(ofJPEG data: Data) throws -> CGSize {
        let image = try #require(UIImage(data: data))
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// F41: four scanned pages are stored 1024 px wide, each page at its full readable height
    /// (about 1325 px for a letter page), and the total on the LAST page still reads. HEAD
    /// shrank the whole stack by its long edge to a ~386 px-wide strip nobody could read.
    @Test func aFourPageScanIsStoredAtTheRuledWidthAndStaysLegible() async throws {
        let pages = [
            scannedPage(["HOME DEPOT", "PAGE 1"]),
            scannedPage(["THINSET   41.00"]),
            scannedPage(["GROUT     18.97"]),
            scannedPage(["TOTAL     88.30"]),
        ]
        let scan = try #require(await ReceiptScanPages.prepared(pages))
        let stored = try pixelSize(ofJPEG: scan.jpeg)
        let pageHeight = 2200 * ReceiptScanPages.pageWidth / 1700
        #expect(ReceiptScanPages.pageWidth == 1024)
        #expect(stored.width == ReceiptScanPages.pageWidth, "stored \(stored)")
        #expect(abs(stored.height - 4 * pageHeight) <= 4, "stored \(stored), each page should keep ~\(pageHeight) px")
        let read = await ReceiptScanner.parse(try #require(UIImage(data: scan.jpeg)))
        #expect(read.recognizedText.contains("88.30"), "the last page's total did not read: \(read.recognizedText)")
    }

    /// Law 62: one scanned page keeps the fleet's 1024 px long edge (the per-page width rule is
    /// the exception for multi-page receipts only).
    @Test func aOnePageScanKeepsTheFleetLongEdge() async throws {
        let scan = try #require(await ReceiptScanPages.prepared([scannedPage(["TOTAL  9.99"])]))
        let stored = try pixelSize(ofJPEG: scan.jpeg)
        #expect(max(stored.width, stored.height) <= 1024, "stored \(stored)")
        #expect(max(stored.width, stored.height) >= 1023, "a page was shrunk further than law 62 asks: \(stored)")
    }

    /// A narrower page is never blown up to the ruled width, and a sideways page is drawn upright.
    @Test func stitchedPagesAreUprightAndNeverEnlarged() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        let cg = try #require(scannedPage(["TOTAL 1.00"]).cgImage)
        let sideways = UIImage(cgImage: cg, scale: 1, orientation: .right)   // shows as 2200 × 1700
        let stitched = try #require(ReceiptScanPages.stitched([sideways, small]))
        let size = CGSize(width: stitched.size.width * stitched.scale, height: stitched.size.height * stitched.scale)
        #expect(size.width == 1024, "canvas \(size)")
        // The sideways page lands 1024 wide and 791 tall (upright); the small page keeps its 800.
        #expect(abs(size.height - (1700 * 1024 / 2200 + 800)) <= 2, "canvas \(size)")
    }

    /// F151: a photo whose pixels are stored turned (an iPhone photo carries the turn as its EXIF
    /// orientation) still reads its total, whichever way the camera was held. HEAD handed Vision
    /// the raw pixels with no orientation.
    @Test(arguments: [(UIImage.Orientation.right, UIImage.Orientation.left),
                      (.left, .right),
                      (.down, .down)])
    func ocrReadsAPhotoStoredTurned(turn: UIImage.Orientation, shownWith tag: UIImage.Orientation) async throws {
        let upright = receipt(["HOME DEPOT", "GROUT SANDED      18.97", "TOTAL             25.11"])
        // Draw the receipt turned (its stored pixels are sideways or upside down)…
        let turned = UIImage(cgImage: try #require(upright.cgImage), scale: 1, orientation: turn)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let turnedPixels = UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in
            turned.draw(at: .zero)
        }
        // …then tag those pixels with the orientation that shows them upright, as a camera does.
        let photo = UIImage(cgImage: try #require(turnedPixels.cgImage), scale: 1, orientation: tag)
        #expect(photo.size.width == upright.size.width * upright.scale, "fixture must display upright")
        let result = await ReceiptScanner.parse(photo)
        #expect(result.total == 25.11, "read: \(result.recognizedText)")
        // Lines come back top of the receipt first, so the store name is the vendor.
        #expect(result.vendor == "HOME DEPOT", "read: \(result.recognizedText)")
    }

    /// F41/F151 call sites: the receipt screens never decode a stored photo with `UIImage(data:)`
    /// in a view body, the list stitches through the shared off-main helper, and the form never
    /// re-encodes a scan in its initializer (it was re-run on every re-creation of the view).
    @Test func receiptScreensDecodeAndStitchOffTheMainThread() throws {
        for file in ["Screens/ReceiptFormScreen.swift", "Screens/ReceiptDetailScreen.swift",
                     "Screens/ReceiptsListScreen.swift"] {
            let code = try #require(GLSource.code(file), "\(file) is missing")
            #expect(!code.contains("UIImage(data:"), "\(file) decodes a stored photo on the main thread")
        }
        let list = try #require(GLSource.code("Screens/ReceiptsListScreen.swift"))
        #expect(list.contains("ReceiptScanPages.prepared("), "the list does not use the shared stitcher")
        #expect(!list.contains("stitchedScan"), "the list keeps its own stitcher")
        let form = try #require(GLSource.code("Screens/ReceiptFormScreen.swift"))
        #expect(!form.contains("ReceiptService.photoData(from: $0)"), "the form re-encodes the scan in init")
    }
}
