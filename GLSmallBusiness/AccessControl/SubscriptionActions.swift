//
//  SubscriptionActions.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/22/26.
//
//  Maps StoreKit failures (restore / redeem) to a plain, honest, user-facing message — so a tap on
//  Restore Purchases while offline says *why* nothing happened instead of silently spinning. The
//  mapping is a pure Error -> String? so it's unit-tested; `nil` means "user cancelled — no alert."
//  The messages go through `mbLoc`, so they follow the in-app language like every other string a
//  person reads (they used to be plain Swift literals, i.e. English for a Spanish user).
//

import Foundation
import StoreKit

enum SubscriptionActions {
    /// Message to show when `AppStore.sync()` (Restore Purchases) fails. `nil` = the user cancelled,
    /// so show nothing.
    static func restoreFailureMessage(for error: Error) -> String? {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
                return nil
            case .networkError:
                return mbLoc("Couldn’t reach the App Store. Check your internet connection and try again.")
            case .notAvailableInStorefront:
                return mbLoc("Subscriptions aren’t available in your App Store region.")
            default:
                return mbLoc("Couldn’t restore your purchases right now. Please try again in a moment.")
            }
        }
        return mbLoc("Couldn’t restore your purchases right now. Please try again in a moment.")
    }

    /// Message to show when offer-code redemption fails. `nil` = the user cancelled.
    static func redeemFailureMessage(for error: Error) -> String? {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
                return nil
            case .networkError:
                return mbLoc("Couldn’t reach the App Store to redeem your code. Check your internet connection and try again.")
            default:
                return mbLoc("Couldn’t redeem that code. Double-check the code and your connection, then try again.")
            }
        }
        return mbLoc("Couldn’t redeem that code. Double-check the code and your connection, then try again.")
    }
}
