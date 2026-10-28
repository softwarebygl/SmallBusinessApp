//
//  AssistantPaywallIntakeHelpTests.swift
//  GLSmallBusinessTests
//
//  Three assistant surfaces around the chat:
//  - its Upgrade opens a paywall that says Pro + AI and sells ONLY the Pro + AI plans (plain Pro
//    never opens the assistant), and never draws an empty store when those plans aren't there;
//  - photos it asks for are downsampled to 1024 px off the main thread before anything holds
//    them, and a logo is saved only after the crop step;
//  - its help points the model at the App guide's steps.
//

import Foundation
import GoldLifeAI
import SwiftData
import Testing
import UIKit
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct AssistantPaywallIntakeHelpTests {

    // MARK: - The assistant's paywall

    @Test func theAssistantsPaywallUsesStandardSubscribeCopyBecauseAIIsBYOK() {
        let saved = MBLocalization.shared.language
        defer { MBLocalization.shared.language = saved }
        MBLocalization.shared.language = .en
        #expect(PaywallSheet.headline(context: .assistant, isLapsed: false) == "Subscribe to My Business")
        #expect(PaywallSheet.headline(context: .assistant, isLapsed: true) == "Your subscription ended")
        #expect(!PaywallSheet.subline(context: .assistant, isLapsed: false).contains("Pro + AI"))

        MBLocalization.shared.language = .es
        #expect(PaywallSheet.headline(context: .assistant, isLapsed: false) == "Suscríbete a My Business")

        // The other doorways are unchanged.
        MBLocalization.shared.language = .en
        #expect(PaywallSheet.headline(context: .atCap, isLapsed: false) == "You’ve reached the free limit")
        #expect(PaywallSheet.headline(context: .upgrade, isLapsed: true) == "Your subscription ended")
    }

    @Test func theAssistantsPaywallSellsNothingAndRegularPaywallsSellOnlyPro() {
        #expect(PaywallSheet.productIDs(for: .assistant).isEmpty)
        // The assistant is 100% free via BYOK, so the regular paywalls sell only Pro.
        let sold: Set<String> = [SubscriptionManager.monthlyID, SubscriptionManager.annualID]
        for context in [PaywallContext.atCap, .upgrade] {
            #expect(Set(PaywallSheet.productIDs(for: context)) == sold)
        }
    }

    /// Plain Pro alone in the storefront is NOTHING to sell on `.assistant` (since no AI plan is
    /// sold) — never an empty SubscriptionStoreView with no way out.
    @Test func aStorefrontWithoutProPlusAIIsNothingToSellOnTheAssistantsSheet() {
        let ai = PaywallSheet.productIDs(for: .assistant)
        let proOnly: Set<String> = [SubscriptionManager.monthlyID, SubscriptionManager.annualID]
        #expect(PaywallSheet.presentation(loadState: .loaded, loadedIDs: proOnly, selling: ai) == .nothingToSell)
        #expect(PaywallSheet.presentation(loadState: .failed, loadedIDs: proOnly, selling: ai) == .unreachable)
        #expect(PaywallSheet.presentation(loadState: .loading, loadedIDs: [], selling: ai) == .store)
        // The cap paywall sells Pro from the storefront.
        #expect(PaywallSheet.presentation(loadState: .loaded, loadedIDs: proOnly,
                                          selling: PaywallSheet.productIDs(for: .atCap)) == .store)
    }

    @Test func theAssistantPresentsItsOwnPaywallAndNeverPopsItOnItsOwn() throws {
        let screen = try #require(GLSource.file("Screens/AssistantScreen.swift"))
        #expect(screen.contains(".paywallSheet(isPresented: $showingPaywall, context: .assistant)"))
        // Upgrade is the only way to it: no automatic presentation off an error or a retry.
        #expect(screen.components(separatedBy: "showingPaywall = true").count == 2,
                "only onUpgrade may open the paywall")
        #expect(!screen.contains("messages.count"))
    }

    // MARK: - Photo intake

    private func bigPhoto(width: CGFloat = 3_000, height: CGFloat = 1_500) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func aPickedPhotoIsDownsampledTo1024BeforeAnythingHoldsIt() async throws {
        let original = bigPhoto()
        let jpeg = try #require(await ImageDownsampler.intakeJPEG(from: original))
        let decoded = try #require(UIImage(data: jpeg))
        #expect(max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale) <= ImageDownsampler.intakeMaxEdge)
        #expect(ImageDownsampler.intakeMaxEdge == 1024)
        #expect(jpeg.count < original.count)

        let image = try #require(await ImageDownsampler.intakeImage(from: original))
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) <= 1024)

        // The assistant's host never decodes a full UIImage from what was picked.
        let host = try #require(GLSource.file("AI/MBAIHandoffHost.swift"))
        let load = try #require(GLSource.functionBody("loadPhotos", in: host))
        #expect(!load.contains("UIImage(data:"))
        #expect(load.contains("ImageDownsampler.intakeJPEG") && load.contains("ImageDownsampler.intakeImage"))
    }

    @Test func pickedPhotosAreStoredAsTheyArriveAndALogoOnlyAfterTheCrop() throws {
        let world = try MBWriteWorld()
        let jpeg = bigPhoto(width: 800, height: 600)
        let png = try #require(UIImage(data: jpeg)?.pngData())

        let photo = DomainState.subscribed.run {
            MBPickCommit.photos([jpeg], plan: MBPickPlan(target: .customerPhoto, recordID: world.customerID),
                                in: world.context)
        }
        #expect(!photo.isError)
        #expect(world.customer.profileImageData == jpeg, "stored as downsampled, not redrawn")

        // A logo never lands uncropped, by either door.
        let uncropped = DomainState.subscribed.run {
            MBPickCommit.photos([jpeg], plan: MBPickPlan(target: .businessLogo), in: world.context)
        }
        #expect(uncropped.isError)
        let uncroppedFile = DomainState.subscribed.run {
            MBPickCommit.file(jpeg, name: "logo.jpg", plan: MBPickPlan(target: .businessLogoDark), in: world.context)
        }
        #expect(uncroppedFile.isError)
        let profile = try #require(MBRecordLookup.businessProfile(in: world.context))
        #expect(profile.logoData == nil && profile.logoDataDark == nil)

        // Through the crop step it lands.
        let cropped = DomainState.subscribed.run {
            MBPickCommit.logo(png, plan: MBPickPlan(target: .businessLogo), in: world.context)
        }
        #expect(!cropped.isError)
        #expect(profile.logoData == png)
    }

    @Test func aLogoIsNeverScannedBecauseTheScannerCantHandOverToTheCrop() async throws {
        let world = try MBWriteWorld()
        let env = MBToolHarness.environment(world.context)
        let scan = GLAIHandoff(kind: "pick_media", payload: ["kind": "scan", "target": "business_logo"])
        let step = await DomainState.subscribed.runAsync { await MBHandoffBuilder.pick(scan, env: env) }
        guard case .answer(let outcome) = step else {
            Issue.record("expected a refusal")
            return
        }
        #expect(outcome.isError)

        let photo = GLAIHandoff(kind: "pick_media", payload: ["kind": "photo", "target": "business_logo"])
        let photoStep = await DomainState.subscribed.runAsync { await MBHandoffBuilder.pick(photo, env: env) }
        guard case .value = photoStep else {
            Issue.record("a logo photo goes to the picker (and then the crop)")
            return
        }
    }

    // MARK: - Help and the manifest

    @Test func helpPointsTheModelAtTheAppGuidesSteps() async throws {
        let world = try MBWriteWorld()
        let output = MBToolHarness.output(await MBToolHarness.run(world.box, "help",
                                                                   ["question": "How do I turn an estimate into an invoice?"]))
        let guides = try #require(output["guides"]?.stringValue)
        #expect(guides.contains("App guide"))
        #expect(guides.contains("how_to"))
        #expect(!guides.contains("Don't invent steps that aren't here"),
                "the old line told the model to withhold the guide's steps")
    }

    /// The model is never invited to promise what the phone refuses: the subcontractor's W-9 is
    /// on that subcontractor's own screen only.
    @Test func theManifestSaysTheSubcontractorsW9IsOnItsOwnScreenOnly() throws {
        let url = try #require(Bundle.main.url(forResource: "tools.mb-1", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let tools = try #require(root["tools"] as? [[String: Any]])
        func summary(_ name: String) throws -> String {
            try #require(tools.first { $0["name"] as? String == name }?["summary"] as? String)
        }
        for name in ["pick_media", "set_document", "share_document"] {
            let text = try summary(name)
            #expect(text.contains("subcontractor's W-9 is only") && text.contains("open subcontractor"),
                    "\(name) must send the W-9 to the subcontractor's screen: \(text)")
        }
        #expect(!(try summary("pick_media")).contains("a subcontractor's W-9, "))
        #expect(try summary("delete").contains("types the client's name"))
    }
}
