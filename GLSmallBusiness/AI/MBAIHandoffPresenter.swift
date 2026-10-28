//
//  MBAIHandoffPresenter.swift
//  GLSmallBusiness — AI
//
//  The app's half of every `.handoff` (contract §4, A5): the assistant's tool says WHAT to put in
//  front of the person, and this presenter shows it — Mail, Messages, the share sheet, the photo
//  picker, the file importer, the scanner, the phone-contact picker, the new-contact card, or a
//  push to a record or screen — and answers the loop with the REAL outcome. A `.sent` row appears
//  only for an actual send; a dismissed composer is `{cancelled:true}`.
//
//  Mounted with `.mbAIHandoffs(...)` on a view that STAYS ON SCREEN for the whole request (the
//  assistant screen's own container), because an `open` handoff navigates away and a sheet hung on
//  a view that left never reports back. Stop still ends the request at once: GoldLifeAI races the
//  presenter against cancellation.
//
//  Law 45 is kept here, not in the model: a compose sheet checks `canSendMail()` / `canSendText()`,
//  that there is a recipient, and that the business profile is complete, and refuses in plain words
//  when it can't. Face ID stays here too — the W-9 and 1099-NEC print a full Tax ID, so nothing
//  TIN-bearing is rendered until `BiometricGate` says yes. The model never sees any of it.
//

import SwiftUI
import SwiftData
import Contacts
import MessageUI
import PhotosUI
import UIKit
import VisionKit
import GoldLifeAI
import GoldLifeUI

// MARK: - What the host shows

/// One piece of UI the presenter is showing, with everything it needs to finish.
struct MBHandoffPresentation: Identifiable {
    let id = UUID()
    let ui: MBHandoffUI
}

enum MBHandoffUI {
    case mail(MBComposeContent)
    case message(MBComposeContent)
    case share(urls: [URL], activity: GLAIActivity?)
    case photos(MBPickPlan)
    case files(MBPickPlan)
    case scan(MBPickPlan)
    case contactPicker(MBPickPlan)
    case newContact(contact: CNMutableContact, name: String)

    /// Everything but the photo picker and the file importer, which are modifiers the host raises
    /// on itself rather than sheet content.
    var isSheet: Bool {
        switch self {
        case .photos, .files: return false
        default: return true
        }
    }
}

/// Either a piece of UI to show, or the answer the loop gets straight away (a refusal). `Result`
/// can't carry a `GLAIHandoffOutcome`, which isn't an `Error` — and shouldn't be: a refusal is a
/// normal answer here, not a thrown failure.
enum MBHandoffStep<Value> {
    case value(Value)
    case answer(GLAIHandoffOutcome)
}

/// A compose sheet's filled-in content plus what the activity row says once it really sends.
struct MBComposeContent {
    var recipients: [String]
    var subject: String
    var body: String
    var isHTML: Bool
    var preferredSendingEmail: String?
    var attachmentURL: URL?
    var extraAttachments: [MailAttachment] = []
    var messageAttachmentURLs: [URL] = []
    var record: GLAIRecordRef?
    var activityTitle: LocalizedStringResource
    var activityDetail: String?
    var channel: String
}

/// Where a picked photo, file, scan or contact is going.
struct MBPickPlan {
    var target: MBPickTarget
    /// The owning record's id (its `syncID`), when the target hangs on one.
    var recordID: String?
}

// MARK: - The presenter

@MainActor
@Observable
final class MBAIHandoffPresenter: GLAIHandoffPresenter {
    /// What the host is showing right now. Nil when nothing is pending.
    private(set) var presentation: MBHandoffPresentation?

    /// Where the tools read records from — the same environment the toolbox uses.
    @ObservationIgnored var environment: MBToolEnvironment

    /// Which assistant screen is live. Up to three can exist at once (the tab root, the iPad
    /// column, a sparkles sheet), and only the newest one still on screen may push a record or
    /// raise a handoff sheet — a closure left behind by a dismissed sheet would push into a view
    /// nobody can see while `open` still answered `{opened:true}` (law 44).
    private(set) var owner: UUID?
    @ObservationIgnored private var routes: [UUID: (MBAssistantDestination) -> Void] = [:]
    /// Claim order, so releasing the newest hands the job back to the one underneath it.
    @ObservationIgnored private var claimOrder: [UUID] = []

    @ObservationIgnored private var continuation: CheckedContinuation<GLAIHandoffOutcome, Never>?

    init(environment: MBToolEnvironment) {
        self.environment = environment
    }

    // MARK: Who is on screen

    /// A screen appeared: it takes over routing and handoff presentation.
    func claim(_ token: UUID, route: @escaping (MBAssistantDestination) -> Void) {
        routes[token] = route
        claimOrder.removeAll { $0 == token }
        claimOrder.append(token)
        // Only the tab root, the iPad column and one sheet are ever live; anything older than that
        // is a rebuilt column nobody can reach, so it is dropped rather than kept forever.
        while claimOrder.count > 4 {
            routes[claimOrder.removeFirst()] = nil
        }
        owner = token
    }

    /// A screen went away: its closure goes with it, and whatever is still on screen takes over.
    func release(_ token: UUID) {
        routes[token] = nil
        claimOrder.removeAll { $0 == token }
        owner = claimOrder.last
    }

    /// True when this host is the one that should show a handoff sheet.
    func isOwner(_ token: UUID) -> Bool { owner == token }

    /// Pushes a record or screen onto the live assistant's navigation stack. Nil when no assistant
    /// screen is on screen — `open` then answers that it couldn't, instead of claiming it did.
    var route: ((MBAssistantDestination) -> Void)? { owner.flatMap { routes[$0] } }

    // MARK: GLAIHandoffPresenter

    func present(_ handoff: GLAIHandoff) async -> GLAIHandoffOutcome {
        guard let kind = MBHandoffKind(rawValue: handoff.kind) else {
            return .failed(MBHandoffFailure.notAvailable)
        }
        switch kind {
        case .open:
            return openNow(handoff)
        case .send:
            return await show(await MBHandoffBuilder.send(handoff, env: environment))
        case .shareDocument:
            return await show(await MBHandoffBuilder.share(handoff, env: environment))
        case .pickMedia:
            return await show(await MBHandoffBuilder.pick(handoff, env: environment))
        case .saveToContacts:
            return await show(await MBHandoffBuilder.contactCard(handoff, env: environment))
        case .contactDeveloper:
            return await show(await MBHandoffBuilder.developer(handoff, env: environment))
        }
    }

    /// A push happens now and answers now — nothing waits on the screen the person lands on.
    private func openNow(_ handoff: GLAIHandoff) -> GLAIHandoffOutcome {
        guard let store = environment.context(),
              let destination = MBAssistantDestination(handoff: handoff, in: store) else {
            return .failed(MBHandoffFailure.notAvailable)
        }
        guard let route else { return .failed(MBHandoffFailure.notAvailable) }
        route(destination)
        return .opened(activity: GLAIActivity(kind: .opened, symbol: destination.symbol,
                                              title: MBWriteStrings.openedScreen,
                                              detail: destination.label, record: handoff.record))
    }

    /// Shows one piece of UI and waits for the person to finish with it.
    private func show(_ plan: MBHandoffStep<MBHandoffUI>) async -> GLAIHandoffOutcome {
        switch plan {
        case .answer(let outcome):
            return outcome
        case .value(let ui):
            // A second handoff while one is up can't happen (calls run in order), but never leave
            // a continuation hanging if it somehow does.
            finish(.cancelled())
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.presentation = MBHandoffPresentation(ui: ui)
            }
        }
    }

    /// The host calls this exactly once per presentation.
    func finish(_ outcome: GLAIHandoffOutcome) {
        // A share's files (a 1099 report carries Tax IDs) go the moment its sheet closes, however
        // it closed: shared, cancelled, swiped away or torn down with the session.
        if case .share(let urls, _)? = presentation?.ui { SharedTempFiles.remove(urls) }
        presentation = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }

    /// The id of the presentation on screen right now. A pick that loads for a while (photos, a
    /// file, a scan) notes it on the way in and hands it back on the way out.
    var presentationID: UUID? { presentation?.id }

    /// Finishes the request with `outcome` only if it is still the SAME request on screen, and
    /// `token`'s host still presents it. A person who closed the picker, a session that ended or
    /// a newer request that took over while a slow pick loaded must not have it answered (or
    /// saved) after the fact.
    func finishIfCurrent(startedAs id: UUID?, owner token: UUID, _ outcome: GLAIHandoffOutcome) {
        guard let id, presentation?.id == id, isOwner(token) else { return }
        finish(outcome)
    }

    /// Saves a finished pick through `build`, with the live store (`environment.context()`, the
    /// one the toolbox writes through), only while the request is still current (see
    /// `finishIfCurrent`). Nothing is saved for a request that ended meanwhile.
    func commitPick(startedAs id: UUID?, owner token: UUID,
                    _ build: (ModelContext) -> GLAIHandoffOutcome) {
        guard let id, presentation?.id == id, isOwner(token) else { return }
        guard let store = environment.context() else {
            finish(.failed(MBHandoffFailure.notAvailable))
            return
        }
        finish(build(store))
    }

    /// Sign-out, account switch or a store rebuild: nothing pending means anything any more.
    func cancelPending() {
        finish(.cancelled(message: "The app closed this before it finished."))
    }
}

// MARK: - Refusals

@MainActor
enum MBHandoffFailure {
    static var notAvailable: GLAIFailure {
        GLAIFailure(reason: "not_available",
                    message: "The app couldn't show this right now. Tell the user to try it from the screen.",
                    personReason: MBWriteStrings.handoffNotAvailable)
    }

    static var noMail: GLAIFailure {
        GLAIFailure(reason: "mail_unavailable",
                    message: "This phone has no email account set up. Offer to share it instead, or to text it.",
                    personReason: MBWriteStrings.mailUnavailable)
    }

    static var noMessages: GLAIFailure {
        GLAIFailure(reason: "messages_unavailable",
                    message: "This phone can't send texts. Offer to email it instead, or to share it.",
                    personReason: MBWriteStrings.messagesUnavailable)
    }

    static var noRecipient: GLAIFailure {
        GLAIFailure(reason: "no_recipient",
                    message: "There's no email or phone number on file for them. Ask for one and save it with save_customer first.",
                    personReason: MBWriteStrings.noRecipient)
    }

    static var profileIncomplete: GLAIFailure {
        GLAIFailure(reason: "business_profile_incomplete",
                    message: "The business profile needs a name and a phone or email before anything goes to a customer. Offer to open My Business Details.",
                    personReason: MBWriteStrings.profileIncomplete)
    }

    static var documentFailed: GLAIFailure {
        GLAIFailure(reason: "document_failed",
                    message: "The document couldn't be made. Tell the user plainly and offer to try again.",
                    personReason: MBWriteStrings.documentFailed)
    }

    static var faceIDRefused: GLAIFailure {
        GLAIFailure(reason: "not_unlocked",
                    message: "This one prints a tax ID, so it needs Face ID and that didn't pass. Offer to try again.",
                    personReason: MBWriteStrings.faceIDRefused)
    }

    static var onlyOnScreen: GLAIFailure {
        GLAIFailure(reason: "not_available",
                    message: "That one is only done on its own screen. Offer to open it.",
                    personReason: MBWriteStrings.documentOnlyOnScreen)
    }

    static func outcome(_ failure: GLAIFailure) -> GLAIHandoffOutcome { .failed(failure) }
}
