//
//  GLTestHost.swift
//  GLSmallBusinessTests — Harness
//
//  THE one way a test puts a screen on screen, and the one way it takes it down again.
//
//  1. **One harness instead of nine.** Every coverage suite had grown its own private
//     `host()` — eleven of them, 224 lines of the same UIHostingController + UIWindow
//     boilerplate, because they were written in parallel without a shared harness. A
//     test that needs to reach a screen uses this; it does not grow another one.
//
//  2. **Be honest about what hosting can and cannot prove.** Hosting catches crashes,
//     SIGTRAPs from a missing @Environment object, layout traps, and anything that
//     throws while a body evaluates. It CANNOT check what the screen displays: SwiftUI
//     renders no UILabels and builds no accessibility tree without a live accessibility
//     client, so text is unreadable from a unit test (measured — label scrape,
//     accessibilityElementCount traversal, recursiveDescription, and a retry after
//     forcing a draw all returned zero strings). Content regressions are caught by
//     DesignSnapshotTests (pixel hashes) and by asserting on the models that drive the
//     screen — not here. A render-only test is a SMOKE test; do not mistake it for a
//     guard on what the screen says.
//
//  3. **Settle by draining, not by sleeping.** After layout the run loop is turned until it
//     has nothing left to do (bounded, so a chatty screen cannot hang the process), then
//     given one short timed turn for the deferred work SwiftUI schedules with a delay.
//     A fixed sleep was either too short for the iPad split view or wasted time on every
//     other screen.
//
//  Rendering is always torn down (see GLTestWindow) and every container is retained by
//  TestStore — together those stop SwiftData's SwiftUI observers trapping when a later
//  test saves. See project_swiftdata_test_process_trap.
//

import SwiftUI
import SwiftData
import UIKit
@testable import GLSmallBusiness

@MainActor
enum GLTestHost {
    nonisolated static let phone = CGSize(width: 393, height: 852)
    static let pad = CGSize(width: 1024, height: 1366)

    /// Host `view`, force layout, and let `.task`/`.onAppear` run. Both environment
    /// objects are always injected: a screen reading a missing `@Environment` object
    /// SIGTRAPs and takes the whole test process with it.
    ///
    /// - `sizeClass`: when non-nil, injected as `\.horizontalSizeClass` — what the iPad
    ///   screens actually branch on. Applied through the SwiftUI environment only: forcing
    ///   the matching UIKit trait makes NavigationSplitView build a real three-column
    ///   UISplitViewController whose transition coordinator can stall a headless window.
    /// - `probe`: handed the live hosting controller after the screen has settled and
    ///   before teardown — the only way into private `@State` from a test.
    /// - `settle`: the one timed run-loop turn after the drain (see the header).
    static func render<V: View>(
        _ view: V,
        container: ModelContainer,
        auth: GoldLifeAuth? = nil,
        scheme: UIUserInterfaceStyle = .dark,
        typeSize: DynamicTypeSize = .large,
        size: CGSize = phone,
        sizeClass: UserInterfaceSizeClass? = nil,
        inNavigationStack: Bool = true,
        settle: TimeInterval = 0.005,
        probe: ((UIViewController) -> Void)? = nil
    ) {
        let hosted = host(view, container: container, auth: auth, scheme: scheme, typeSize: typeSize,
                          size: size, sizeClass: sizeClass, inNavigationStack: inNavigationStack)
        drain(settle: settle)
        probe?(hosted.controller)
        GLTestWindow.tearDown(hosted.window)
    }

    /// Render the same view dark AND light. The whole app paints through
    /// `GLColor…render(in:)`, so both are real code paths.
    static func renderBothSchemes<V: View>(_ view: V, container: ModelContainer,
                                           auth: GoldLifeAuth? = nil,
                                           size: CGSize = phone) {
        render(view, container: container, auth: auth, scheme: .dark, size: size)
        render(view, container: container, auth: auth, scheme: .light, size: size)
    }

    /// Host `view`, let it settle, then run `mutate` WHILE the screen is live and pump the
    /// run loop so SwiftUI diffs the body against the mutated graph. This is how a test
    /// reaches the "data changed under an open screen" path — `@Query` re-fetches, a row
    /// disappears, a total re-renders — which a single render can never exercise.
    ///
    /// Make the edit through `container.mainContext` (that is the context the hosted graph
    /// observes) and save it there; the harness only guarantees the pump afterwards.
    static func renderAcross<V: View>(
        _ view: V,
        container: ModelContainer,
        auth: GoldLifeAuth? = nil,
        scheme: UIUserInterfaceStyle = .dark,
        typeSize: DynamicTypeSize = .large,
        size: CGSize = phone,
        sizeClass: UserInterfaceSizeClass? = nil,
        inNavigationStack: Bool = true,
        mutate: () -> Void
    ) {
        let hosted = host(view, container: container, auth: auth, scheme: scheme, typeSize: typeSize,
                          size: size, sizeClass: sizeClass, inNavigationStack: inNavigationStack)
        drain(settle: 0.005)
        mutate()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        GLTestWindow.tearDown(hosted.window)
    }

    // MARK: - Internals (shared by render and renderAcross — one hosting path, not two)

    /// Build the root, put it in a key window, and force one layout pass.
    private static func host<V: View>(
        _ view: V,
        container: ModelContainer,
        auth: GoldLifeAuth?,
        scheme: UIUserInterfaceStyle,
        typeSize: DynamicTypeSize,
        size: CGSize,
        sizeClass: UserInterfaceSizeClass?,
        inNavigationStack: Bool
    ) -> (window: UIWindow, controller: UIViewController) {
        let root = Group {
            if inNavigationStack { NavigationStack { view } } else { view }
        }
        .modelContainer(container)
        .environment(SubscriptionManager.shared)
        .environment(auth ?? GoldLifeAuth())
        .dynamicTypeSize(typeSize)
        .modifier(HorizontalSizeClassOverride(sizeClass: sizeClass))

        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = scheme

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            preconditionFailure("GLTestHost renders inside the host app, which always has a window scene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    /// Turn the run loop until it is idle (at most 50 turns — a screen that keeps
    /// scheduling work must not hang the process), then one short timed turn for the
    /// delayed work SwiftUI schedules after a body evaluates.
    private static func drain(settle: TimeInterval) {
        var turns = 0
        while RunLoop.current.run(mode: .default, before: .distantPast), turns < 50 { turns += 1 }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settle))
    }

    /// `.environment(\.horizontalSizeClass, nil)` would ERASE the inherited value, so the
    /// override is applied only when a size class was actually asked for.
    private struct HorizontalSizeClassOverride: ViewModifier {
        let sizeClass: UserInterfaceSizeClass?
        @ViewBuilder
        func body(content: Content) -> some View {
            if let sizeClass {
                content.environment(\.horizontalSizeClass, sizeClass)
            } else {
                content
            }
        }
    }
}

// MARK: - Teardown

/// Releasing a hosted window, deterministically.
///
/// A rendering test hosts a screen in a UIWindow to make its body evaluate. While that
/// window is alive, SwiftUI keeps the screen's SwiftData observers (`@Query`, and the
/// model context bridge) subscribed to SwiftData's change notifications — PROCESS-WIDE,
/// not scoped to the container the test built.
///
/// A window that is never torn down is never released, so those observers accumulate for
/// the whole test process. Once enough rendering tests have run, an ordinary
/// `modelContext.save()` in a completely unrelated test fans out to observers whose own
/// container is gone, and SwiftData traps (SIGTRAP) inside the notification. That is what
/// killed the full-suite run while every suite passed in isolation: the failure needs many
/// hosted views and one save, which only happens when everything runs together.
///
/// Tearing the window down at the end of each host call keeps observer lifetime tied to the
/// test that created it.
enum GLTestWindow {
    /// Release a hosted window and everything it retains. Call at the end of every helper
    /// that calls `makeKeyAndVisible()`.
    @MainActor
    static func tearDown(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
        // One short turn of the run loop so the teardown (and the observer removal it
        // triggers) actually completes before the next test starts saving.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
