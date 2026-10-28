//
//  ColorHexTests.swift
//  GLSmallBusinessTests
//
//  Color(hex:) underpins the whole palette — every brand token is a hex string — yet had no tests.
//

import Testing
import SwiftUI
import UIKit
@testable import GLSmallBusiness

@MainActor
struct ColorHexTests {
    private func rgb(_ color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }
    private func sameColor(_ a: Color, _ b: Color) -> Bool {
        let x = rgb(a), y = rgb(b)
        return close(x.0, y.0) && close(x.1, y.1) && close(x.2, y.2)
    }

    @Test func parsesSixDigitHex() {
        let (r, g, b) = rgb(Color(hex: "9C7A2E"))   // brand --gold
        #expect(close(r, Double(0x9C) / 255))
        #expect(close(g, Double(0x7A) / 255))
        #expect(close(b, Double(0x2E) / 255))
    }

    @Test func ignoresLeadingHashAndSurroundingWhitespace() {
        #expect(sameColor(Color(hex: "  #F9F6EF "), Color(hex: "F9F6EF")))
    }

    @Test func isCaseInsensitive() {
        #expect(sameColor(Color(hex: "abcdef"), Color(hex: "ABCDEF")))
    }

    @Test func pureChannelsParseToExtremes() {
        #expect(sameColor(Color(hex: "FF0000"), Color(red: 1, green: 0, blue: 0)))
        #expect(sameColor(Color(hex: "00FF00"), Color(red: 0, green: 1, blue: 0)))
        #expect(sameColor(Color(hex: "0000FF"), Color(red: 0, green: 0, blue: 1)))
        #expect(sameColor(Color(hex: "FFFFFF"), Color(red: 1, green: 1, blue: 1)))
    }

    @Test func malformedHexFallsBackToBlack() {
        let (r, g, b) = rgb(Color(hex: "not-a-color"))
        #expect(close(r, 0))
        #expect(close(g, 0))
        #expect(close(b, 0))
    }
}
