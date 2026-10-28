//
//  AppearanceScreen.swift
//  GLSmallBusiness
//
//  The APP-LEVEL appearance picker.
//

import SwiftUI
import GoldLifeUI

struct AppearanceScreen: View {
    @State private var appearance = AppearanceStore.shared

    var body: some View {
        GLAppearanceScreen(
            selection: Binding(
                get: { appearance.pref.rawValue },
                set: { AppSettingsService.setAppearance(AppearancePref(rawValue: $0) ?? .goldLife) }
            ),
            title: mbLoc("Appearance"),
            footer: mbLoc("Gold Life ID Setting follows the appearance saved to your Gold Life ID. Your choice here applies in this app only. System follows your device’s Light or Dark setting.")
        )
        .mbSystemBanners()
    }
}
