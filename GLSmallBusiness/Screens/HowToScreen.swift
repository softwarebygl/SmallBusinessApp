//
//  HowToScreen.swift
//  GLSmallBusiness
//
//  In-app "How To" guides.
//

import SwiftUI
import GoldLifeUI

struct HowToScreen: View {
    /// The guides' embed. A property (not a literal in `url`) so a test can hand in an address
    /// that isn't one and pin the no-crash path below.
    var address = "https://apps.softwarebygl.com/embed/my-business/how-to"

    private var url: URL? { MBLocalization.webURL(address) }

    var body: some View {
        if let url {
            GLHowToScreen(url: url, title: mbLoc("How To"), allowedHosts: MBLocalization.embedHosts) { MBSystemBannerInset() }
        } else {
            // Never with the app's own address; if it ever isn't one, the guides' own
            // "couldn't load" words instead of a crash.
            ContentUnavailableView {
                Label("Couldn’t load How To", systemImage: "wifi.slash")
            } description: {
                Text("Check your connection and try again.")
            }
            .navigationTitle(GLScript.padded(mbLoc("How To")))
            .toolbarTitleDisplayMode(.large)
            .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("How To"))), for: .scrollContent)
            .mbSystemBanners()
        }
    }
}
