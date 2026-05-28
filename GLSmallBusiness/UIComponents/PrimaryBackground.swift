//
//  PrimaryBackground.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/27/26.
//

import SwiftUI

struct PrimaryBackground: View {
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            GLColor.backgroundPrimary.render(in: colorScheme)
            Image("glLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFill()
                .foregroundStyle(GLColor.gold.render(in: colorScheme))
                .opacity(0.2)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    PrimaryBackground()
}
