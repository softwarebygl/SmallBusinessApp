//
//  CustomerAvatar.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 5/28/26.
//

import SwiftUI

/// The circular customer profile image. Shows the saved photo when present,
/// otherwise a gold initials placeholder. The camera badge (an edit affordance)
/// is only shown where the avatar is tappable.
struct CustomerAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    let customer: Customer
    var size: CGFloat = 110
    var showsCameraBadge: Bool = false

    private var gold: Color { GLColor.gold.render(in: colorScheme) }

    var body: some View {
        ZStack {
            if let data = customer.profileImageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                GLColor.backgroundPrimary.render(in: colorScheme)
                gold.opacity(0.2)
                Text(customer.initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(gold)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(gold.opacity(0.4), lineWidth: size * 0.02))
        .overlay(alignment: .bottomTrailing) {
            if showsCameraBadge {
                Image(systemName: "camera.fill")
                    .font(.system(size: size * 0.12))
                    .foregroundStyle(.white)
                    .padding(size * 0.07)
                    .background(Circle().fill(gold))
            }
        }
    }
}
