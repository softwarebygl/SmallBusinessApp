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
        GeometryReader { proxy in
            ZStack {
                GLColor.backgroundPrimary.render(in: colorScheme)
                Image("glLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFill()
                    .foregroundStyle(GLColor.gold.render(in: colorScheme))
                    .opacity(0.2)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    PrimaryBackground()
}
