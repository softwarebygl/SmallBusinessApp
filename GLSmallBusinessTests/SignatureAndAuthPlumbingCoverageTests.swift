//
//  SignatureAndAuthPlumbingCoverageTests.swift
//
//  Two pieces of plumbing that were nearly untested and that fail QUIETLY when
//  they fail — a signature that renders blank still gets attached to a contract,
//  and an auth error the UI can't distinguish sends the owner to the wrong fix.
//
//  SignatureKit was 27.5% covered and GoldLifeAPI 0%. These cover the pure
//  rendering paths (drawn / typed / imported-photo knockout) at their edges —
//  empty, degenerate, hairline, all-white, all-black, already-transparent — and
//  the auth error type's discrimination.
//

import Testing
import Foundation
import UIKit
import PencilKit
@testable import GLSmallBusiness

@MainActor
struct SignatureAndAuthPlumbingCoverageTests {

    // MARK: - Helpers

    /// A solid-colour image of a given size, used to drive the knockout threshold.
    private func image(_ size: CGSize, _ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Reads back the pixels of a rendered PNG so a test can assert on what a
    /// person would actually SEE, not merely that bytes came back.
    private func pixels(_ data: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 4 * w, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }

    /// A one-stroke PKDrawing spanning the given rect.
    private func drawing(width: CGFloat, height: CGFloat, penSize: CGFloat = 4) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0,
                          size: CGSize(width: penSize, height: penSize), opacity: 1,
                          force: 1, azimuth: 0, altitude: 0),
            PKStrokePoint(location: CGPoint(x: width, y: height), timeOffset: 0.1,
                          size: CGSize(width: penSize, height: penSize), opacity: 1,
                          force: 1, azimuth: 0, altitude: 0),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
    }

    // MARK: - Drawn signature

    /// An empty canvas must yield nil, NOT a blank PNG. A blank PNG would be
    /// attached to a signed contract as if it were a real signature.
    @Test func emptyDrawingRendersNothing() {
        #expect(SignatureRender.png(from: PKDrawing()) == nil)
    }

    /// The readiness predicate and the renderer must agree. They share one
    /// definition precisely so the Save button can never be tappable over input
    /// that renders nothing, or greyed out over input that would render fine.
    @Test func readinessPredicateMatchesTheRenderer() {
        let real = drawing(width: 200, height: 60)
        #expect(SignatureRender.hasDrawnInput(bounds: real.bounds))
        #expect(SignatureRender.png(from: real) != nil)

        let empty = PKDrawing()
        #expect(!SignatureRender.hasDrawnInput(bounds: empty.bounds))
        #expect(SignatureRender.png(from: empty) == nil)

        #expect(!SignatureRender.hasDrawnInput(bounds: .zero))
        #expect(!SignatureRender.hasDrawnInput(bounds: CGRect(x: 0, y: 0, width: 0.5, height: 40)))
        #expect(!SignatureRender.hasDrawnInput(bounds: CGRect(x: 0, y: 0, width: 40, height: 0.5)))
    }

    /// The extent guard, pinned at its boundary.
    ///
    /// A mutation replacing this guard with a bare `!bounds.isNull` SURVIVED the suite.
    /// Investigated rather than papered over: PencilKit clamps a stroke's bounds to the
    /// pen size, so even a 0.2pt pen with zero travel reports 4x4pt. A sub-1pt PKDrawing
    /// is therefore not constructible, both forms behave identically for every drawing a
    /// person can actually make, and the mutant is EQUIVALENT rather than a real hole.
    ///
    /// What remains worth pinning is the predicate itself, called directly - it is
    /// shared with the editor's Save gate, so a change here silently changes whether
    /// Save is tappable.
    @Test func extentGuardBoundary() {
        // Rejected: no extent at all, or hairline in either axis.
        #expect(!SignatureRender.hasDrawnInput(bounds: .null))
        #expect(!SignatureRender.hasDrawnInput(bounds: .zero))
        #expect(!SignatureRender.hasDrawnInput(bounds: CGRect(x: 0, y: 0, width: 1.0, height: 40)))
        #expect(!SignatureRender.hasDrawnInput(bounds: CGRect(x: 0, y: 0, width: 40, height: 1.0)))
        #expect(!SignatureRender.hasDrawnInput(bounds: CGRect(x: 0, y: 0, width: 0.9, height: 0.9)))

        // Accepted: over 1pt in both directions.
        #expect(SignatureRender.hasDrawnInput(bounds: CGRect(x: 0, y: 0, width: 1.5, height: 1.5)))
        #expect(SignatureRender.hasDrawnInput(bounds: CGRect(x: -2, y: -2, width: 4, height: 4)))

        // And the smallest real drawing PencilKit will produce clears it.
        let smallest = drawing(width: 0, height: 0, penSize: 0.2)
        #expect(smallest.bounds.width > 1 && smallest.bounds.height > 1,
                "PencilKit no longer clamps to the pen size — revisit the equivalence note above")
        #expect(SignatureRender.hasDrawnInput(bounds: smallest.bounds))
    }

    /// A single tap DOES produce a signature: the stroke's own width gives it
    /// bounds, so it clears the extent guard. Recorded as intended behaviour
    /// rather than a defect — the dot is drawn in the canvas in front of the
    /// person before they can save it, so it is visible, not silent.
    @Test func singleTapRendersAVisibleDot() {
        let dot = drawing(width: 0, height: 0)
        #expect(SignatureRender.hasDrawnInput(bounds: dot.bounds))
        #expect(SignatureRender.png(from: dot) != nil)
    }

    /// The typed gate rejects exactly what the typed renderer rejects.
    @Test func typedReadinessMatchesTheRenderer() {
        for blank in ["", " ", "\n\t "] {
            #expect(!SignatureRender.hasTypedInput(blank))
            #expect(SignatureRender.png(typed: blank) == nil)
        }
        for name in ["A", "Adrian Gutierrez"] {
            #expect(SignatureRender.hasTypedInput(name))
            #expect(SignatureRender.png(typed: name) != nil)
        }
    }

    /// A real drawn signature renders, and renders with actual ink — not a
    /// transparent rectangle of the right size.
    @Test func drawnSignatureRendersInk() throws {
        let data = try #require(SignatureRender.png(from: drawing(width: 200, height: 60)))
        #expect(!data.isEmpty)
        let px = try #require(pixels(data))
        #expect(px.width > 1 && px.height > 1)
        var opaque = 0
        var i = 3
        while i < px.rgba.count { if px.rgba[i] > 10 { opaque += 1 }; i += 4 }
        #expect(opaque > 0, "rendered signature has no visible ink")
    }

    // MARK: - Typed signature

    /// Empty and whitespace-only names must both yield nil. Whitespace matters:
    /// a name field holding " " is what a person leaves behind after clearing it,
    /// and it would otherwise render an empty script image.
    @Test func typedSignatureRejectsBlankNames() {
        #expect(SignatureRender.png(typed: "") == nil)
        #expect(SignatureRender.png(typed: "   ") == nil)
        #expect(SignatureRender.png(typed: "\n\t ") == nil)
    }

    /// A typed name renders visible glyphs. Guards the SnellRoundhand font name:
    /// a typo there fails soft (SwiftUI substitutes) but must still produce ink.
    @Test func typedSignatureRendersGlyphs() throws {
        let data = try #require(SignatureRender.png(typed: "Adrian Gutierrez"))
        let px = try #require(pixels(data))
        var inked = 0
        var i = 0
        while i < px.rgba.count {
            if px.rgba[i + 3] > 10 { inked += 1 }
            i += 4
        }
        #expect(inked > 0, "typed signature rendered no glyphs")
    }

    /// Long names must render. At a fixed 64pt they rasterized wider than the
    /// encoder would take and came back nil — which the editor could only show as
    /// a Save button greyed out for no stated reason. The point size now fits the
    /// name, so every plausible legal or business name renders.
    ///
    /// The 200-character case is the regression guard: it was nil before the fix.
    @Test func longNamesRenderAtAFittedSize() {
        let names = [
            "Adrian Gutierrez",
            "Bartholomew Wolfeschlegelsteinhausenbergerdorff",
            "Gutierrez Tile & Flooring Contracting Services of Miami LLC",
            String(repeating: "M", count: 200),
        ]
        for name in names {
            #expect(SignatureRender.png(typed: name) != nil, "failed to render a \(name.count)-character name")
        }
    }

    /// Non-ASCII names render — accents, tildes and apostrophes are ordinary in
    /// customer and owner names.
    @Test func typedSignatureHandlesUnicodeNames() {
        #expect(SignatureRender.png(typed: "José Ñuñez-O'Brien") != nil)
        #expect(SignatureRender.png(typed: "Zoë Müller") != nil)
    }

    /// Past a certain absurd length the fitted size hits its legibility floor and
    /// rendering still fails. That is a deliberate boundary, not an oversight: a
    /// 400-character "name" is a paste, and rendering it as an illegible smear
    /// would be worse than saying so. The editor now surfaces this as an alert
    /// ("try typing a shorter name") instead of an unexplained disabled button.
    @Test func absurdlyLongNamesFailLoudlyRatherThanSilently() {
        #expect(SignatureRender.png(typed: String(repeating: "M", count: 400)) == nil)
        // The gate still says "ready", which is what routes it to save() — and
        // save() is where the alert lives. If this ever flipped to false, the
        // failure would go back to being an unexplained greyed-out button.
        #expect(SignatureRender.hasTypedInput(String(repeating: "M", count: 400)))
    }

    // MARK: - Imported photo knockout

    /// The whole point of the knockout: a photo of a signature on white paper
    /// comes back with the paper GONE (alpha 0), so it sits on the signature line
    /// instead of covering it with a white card.
    @Test func whitePaperIsKnockedOutToTransparent() throws {
        let data = try #require(SignatureRender.transparentPNG(from: image(CGSize(width: 8, height: 8), .white)))
        let px = try #require(pixels(data))
        var i = 3
        while i < px.rgba.count { #expect(px.rgba[i] == 0, "white pixel survived the knockout"); i += 4 }
    }

    /// The ink itself must survive. A threshold bug that knocked out everything
    /// would produce a fully invisible signature — which looks like "it worked"
    /// until the contract is opened.
    @Test func inkSurvivesTheKnockout() throws {
        let data = try #require(SignatureRender.transparentPNG(from: image(CGSize(width: 8, height: 8), .black)))
        let px = try #require(pixels(data))
        var opaque = 0
        var i = 3
        while i < px.rgba.count { if px.rgba[i] > 200 { opaque += 1 }; i += 4 }
        #expect(opaque == px.width * px.height, "black ink was knocked out")
    }

    /// The threshold is > 225 on all three channels. Mid-gray must stay: pencil
    /// and ballpoint scans are gray, not black, and knocking them out would erase
    /// the signature.
    @Test func midGrayInkIsPreserved() throws {
        let gray = UIColor(white: 0.5, alpha: 1)
        let data = try #require(SignatureRender.transparentPNG(from: image(CGSize(width: 4, height: 4), gray)))
        let px = try #require(pixels(data))
        var i = 3
        while i < px.rgba.count { #expect(px.rgba[i] > 200, "mid-gray ink was knocked out"); i += 4 }
    }

    /// Already-transparent input is flattened onto white BEFORE thresholding —
    /// the documented reason being gray halos. A fully transparent image should
    /// therefore come back fully transparent, not gray.
    @Test func transparentInputFlattensToWhiteThenKnocksOut() throws {
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6)).image { _ in }
        let data = try #require(SignatureRender.transparentPNG(from: clear))
        let px = try #require(pixels(data))
        var i = 3
        while i < px.rgba.count { #expect(px.rgba[i] == 0, "transparent input left a gray halo"); i += 4 }
    }

    /// Dimensions are preserved end to end — a knockout that resized the image
    /// would stretch the signature on the contract.
    @Test func knockoutPreservesDimensions() throws {
        let source = image(CGSize(width: 12, height: 5), .white)
        let data = try #require(SignatureRender.transparentPNG(from: source))
        let px = try #require(pixels(data))
        #expect(px.width == Int(source.size.width * source.scale))
        #expect(px.height == Int(source.size.height * source.scale))
    }

    // MARK: - Auth error discrimination

    /// `notSignedIn` and a 401 must NOT be conflated: one sends the owner to the
    /// sign-in screen, the other is a stale session the app refreshes silently.
    /// The comment in GoldLifeAPI states this contract explicitly.
    @Test func authErrorsAreDistinguishable() {
        let notSignedIn = GoldLifeAPIError.notSignedIn
        let unauthorized = GoldLifeAPIError.badStatus(401)

        func isNotSignedIn(_ e: GoldLifeAPIError) -> Bool {
            if case .notSignedIn = e { return true }
            return false
        }
        func status(_ e: GoldLifeAPIError) -> Int? {
            if case .badStatus(let code) = e { return code }
            return nil
        }

        #expect(isNotSignedIn(notSignedIn))
        #expect(!isNotSignedIn(unauthorized))
        #expect(status(unauthorized) == 401)
        #expect(status(notSignedIn) == nil)
    }

    /// Every status the Worker can return survives the round trip intact — a
    /// dropped code makes support triage guesswork.
    @Test func badStatusCarriesItsCode() {
        for code in [400, 401, 403, 404, 409, 429, 500, 502, 503] {
            guard case .badStatus(let carried) = GoldLifeAPIError.badStatus(code) else {
                Issue.record("badStatus(\(code)) did not match .badStatus")
                continue
            }
            #expect(carried == code)
        }
    }

    /// The session-expired hook is optional and unwired by default, so a call in
    /// isolation must be a no-op rather than a crash. Restores whatever was there.
    @Test func sessionExpiredHookIsSafeWhenUnwired() async {
        let saved = GoldLifeAPI.onSessionExpired
        GoldLifeAPI.onSessionExpired = nil
        await GoldLifeAPI.onSessionExpired?()   // must not trap

        var fired = false
        GoldLifeAPI.onSessionExpired = { fired = true }
        await GoldLifeAPI.onSessionExpired?()
        #expect(fired, "the wired hook did not fire")

        GoldLifeAPI.onSessionExpired = saved
    }

    // MARK: - Error copy names its cause

    /// Rule: a user-facing error says WHY it happened, in words a non-technical
    /// person can act on. Offline is the one sign-in cause the code can actually
    /// determine, so it must be reported as such rather than folded into a generic
    /// "try again" that leaves someone toggling Wi-Fi on a hunch.
    @Test func signInFailureNamesTheOfflineCause() {
        let offline = URLError(.notConnectedToInternet)
        let message = GoldLifeAuth.signInFailureMessage(offline)
        #expect(message.contains("not connected to the internet"))
        #expect(message.lowercased().contains("check your connection"))

        let cellularOff = GoldLifeAuth.signInFailureMessage(URLError(.dataNotAllowed))
        #expect(cellularOff == message, "cellular-data-off is the same story to a person")
    }

    /// A timeout is a DIFFERENT cause from being offline — the connection exists but
    /// did not finish — and gets its own words.
    @Test func signInTimeoutIsDistinctFromOffline() {
        let timedOut = GoldLifeAuth.signInFailureMessage(URLError(.timedOut))
        #expect(timedOut.contains("timed out"))
        #expect(timedOut != GoldLifeAuth.signInFailureMessage(URLError(.notConnectedToInternet)))
    }

    /// When the cause genuinely is not knowable, the fallback still has to be plain
    /// English with a real next step — and must never leak an error type, a code, or
    /// bracketed diagnostics the way the DEBUG-only branch deliberately does.
    @Test func unknownSignInFailureStaysPlainEnglish() {
        struct Opaque: Error {}
        for error in [Opaque() as Error?, nil] {
            let message = GoldLifeAuth.signInFailureMessage(error)
            #expect(!message.isEmpty)
            #expect(!message.contains("Error"))
            #expect(!message.contains("["))
            #expect(!message.contains("Optional("))
            #expect(!message.contains("Stytch"))
            #expect(message.contains("try again"), "no next step offered: \(message)")
        }
    }

    /// Every branch must be non-technical: no type names, codes, or internals in any
    /// message this mapper can produce.
    @Test func noSignInMessageLeaksInternals() {
        let errors: [Error?] = [
            URLError(.notConnectedToInternet), URLError(.timedOut),
            URLError(.dataNotAllowed), URLError(.badServerResponse),
            NSError(domain: "com.stytch", code: 401), nil,
        ]
        for error in errors {
            let message = GoldLifeAuth.signInFailureMessage(error)
            for leak in ["URLError", "NSError", "domain", "code=", "nil", "Code."] {
                #expect(!message.contains(leak), "\(leak) leaked into: \(message)")
            }
        }
    }
}
