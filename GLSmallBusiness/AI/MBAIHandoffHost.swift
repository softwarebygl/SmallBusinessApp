//
//  MBAIHandoffHost.swift
//  GLSmallBusiness — AI
//
//  The sheets the handoff presenter raises, and what happens when they close. Mounted once, on the
//  assistant screen's own container (`.mbAIHandoffs(_:)`), which stays on screen for the whole
//  request.
//
//  A picked photo, file or scan is SAVED through the same services the screens use — `ReceiptService`,
//  `DocumentService`, `CustomerService.setPhoto`, `BusinessProfileService.setLogo`,
//  `ContactsBridge` + `CustomerService.create` — so a file the assistant asked for and one the
//  person imported by tapping land in the same place, the same way.
//
//  Picked photos are downsampled to 1024 px OFF the main thread, one at a time, before anything
//  else holds them (Photo Intake Memory Defense) — never ten full-size images decoded on the main
//  actor. A logo goes through the SAME crop step as My Business Details (GoldLifeUI's
//  `GLSquarePhotoCropper`, rounded-rectangle guide, the logo's own light or dark ground) before
//  it is saved.
//

import SwiftUI
import SwiftData
import Contacts
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import GoldLifeAI
import GoldLifeUI

extension View {
    /// Mounts the assistant's handoff UI. Put it on a view that stays on screen for the whole
    /// request — an `open` handoff navigates away. `owner` is the screen's claim token: several
    /// assistant screens can be alive at once, and only the one on top presents, so a composer
    /// can never come up behind a tab nobody is looking at.
    func mbAIHandoffs(_ presenter: MBAIHandoffPresenter, owner: UUID) -> some View {
        modifier(MBAIHandoffHost(presenter: presenter, owner: owner))
    }
}

struct MBAIHandoffHost: ViewModifier {
    @Bindable var presenter: MBAIHandoffPresenter
    let owner: UUID

    @Environment(\.colorScheme) private var colorScheme
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var pendingPlan: MBPickPlan?
    /// A picked logo waiting in the crop step; the request finishes when it closes.
    @State private var logoCrop: MBLogoCrop?
    /// The request whose scan is being stitched and read: its scanner sheet is already gone.
    @State private var busyPresentation: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetItem) { pending in
                sheet(pending).glAppearance(colorScheme)
            }
            .photosPicker(isPresented: $showingPhotos, selection: $photoItems, maxSelectionCount: 10,
                          matching: .images)
            .fileImporter(isPresented: $showingFiles,
                          allowedContentTypes: [.pdf, .image, .plainText, .commaSeparatedText],
                          allowsMultipleSelection: false) { result in
                finishFiles(result)
            }
            // The Menu's logo crop step (MenuScreen's My Business Details), the same view and
            // guide, on the logo's own light or dark ground.
            .fullScreenCover(item: $logoCrop) { crop in
                GLSquarePhotoCropper(image: crop.image, guide: .roundedRect,
                                     windowBackground: GLTheme.resolved(GLTheme.background,
                                                                        in: crop.plan.target == .businessLogoDark ? .dark : .light),
                                     outputSide: ImageDownsampler.croppedSide, keepsTransparency: true) {
                    logoCrop = nil
                    presenter.finishIfCurrent(startedAs: crop.startedAs, owner: owner,
                                              .cancelled(message: "The user closed the crop without saving the logo."))
                } onCropped: { cropped in
                    logoCrop = nil
                    // The crop is a person-length step: a request that ended meanwhile (the
                    // session closed) must not have its logo saved after all.
                    guard let png = cropped.pngData() else {
                        presenter.finishIfCurrent(startedAs: crop.startedAs, owner: owner,
                                                  .failed(MBHandoffFailure.documentFailed))
                        return
                    }
                    presenter.commitPick(startedAs: crop.startedAs, owner: owner) {
                        MBPickCommit.logo(png, plan: crop.plan, in: $0)
                    }
                }
            }
            .onChange(of: presenter.presentation?.id) { _, _ in raisePickerIfNeeded() }
            // Taking over with something already pending (a sheet closed while a pick was up):
            // the new host raises it, since the id didn't move.
            .onChange(of: presenter.owner) { _, _ in raisePickerIfNeeded() }
            .onChange(of: showingPhotos) { was, now in
                // Dismissed without picking anything.
                if was, !now, photoItems.isEmpty, pendingPlan != nil { cancelPhotos() }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
    }

    // MARK: Sheets

    /// Only the presentations that really are a sheet. The photo picker and the file importer are
    /// modifiers, not sheets — presenting an empty sheet for them would put a blank card on screen
    /// behind the picker. A swipe-dismiss answers the loop as cancelled rather than leaving the
    /// request waiting forever.
    private var sheetItem: Binding<MBHandoffPresentation?> {
        Binding(
            get: {
                guard presenter.isOwner(owner) else { return nil }
                return presenter.presentation.flatMap {
                    $0.ui.isSheet && $0.id != busyPresentation ? $0 : nil
                }
            },
            set: { newValue in
                guard newValue == nil, presenter.isOwner(owner),
                      presenter.presentation?.ui.isSheet == true,
                      presenter.presentationID != busyPresentation else { return }
                presenter.finish(.cancelled(message: "The user closed it without finishing."))
            })
    }

    @ViewBuilder
    private func sheet(_ pending: MBHandoffPresentation) -> some View {
        switch pending.ui {
        case .mail(let content):
            MailComposeView(recipients: content.recipients, subject: content.subject,
                            body: content.body, isHTML: content.isHTML,
                            preferredSendingEmail: content.preferredSendingEmail,
                            attachmentURL: content.attachmentURL,
                            additionalAttachments: content.extraAttachments) { outcome in
                presenter.finish(MBSendOutcomeMapper.outcome(outcome, content: content))
            }
        case .message(let content):
            MessageComposeView(recipients: content.recipients, body: content.body,
                               attachmentURLs: content.messageAttachmentURLs) { outcome in
                presenter.finish(MBSendOutcomeMapper.outcome(outcome, content: content))
            }
        case .share(let urls, let activity):
            MBAIShareSheet(items: urls) { completed in
                presenter.finish(completed
                    ? .shared(activity: activity ?? MBSendOutcomeMapper.sharedRow)
                    : .cancelled(message: "The user chose not to share it."))
            }
        case .scan(let plan):
            DocumentScannerView(onComplete: { images in
                Task { await finishScan(images, plan: plan) }
            }, onCancel: {
                presenter.finish(.cancelled(message: "The user closed the scanner."))
            })
        case .contactPicker(let plan):
            ContactPickerView(onPick: { contact in
                finishContact(contact, plan: plan)
            }, onCancel: {
                presenter.finish(.cancelled(message: "The user closed the contact picker."))
            })
        case .newContact(let contact, let name):
            NewContactView(contact: contact) {
                presenter.finish(GLAIHandoffOutcome(
                    output: ["ok": true, "opened": true],
                    activity: [GLAIActivity(kind: .opened, symbol: MBWriteSymbol.customer,
                                            title: MBWriteStrings.openedContactCard, detail: name)]))
            }
        case .photos, .files:
            // Never reached: `sheetItem` keeps these out of the sheet (see `raisePickerIfNeeded`).
            Color.clear
        }
    }

    /// The photo picker and the file importer are modifiers, not sheets: they are raised from the
    /// host itself once the presenter has something for them.
    private func raisePickerIfNeeded() {
        guard presenter.isOwner(owner), let pending = presenter.presentation else { return }
        switch pending.ui {
        case .photos(let plan):
            pendingPlan = plan
            photoItems = []
            showingPhotos = true
        case .files(let plan):
            pendingPlan = plan
            showingFiles = true
        default:
            break
        }
    }

    // MARK: Finishing a pick

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard let plan = pendingPlan else { return }
        // Every await below can outlast the request (the person closes the picker, the session
        // ends): note which one this is, and answer it only if it is still on screen.
        let startedAs = presenter.presentationID
        // A logo is one picture that still has to be cropped; everything else is stored as it is.
        var logo: UIImage?
        var photos: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // Off the main thread, one at a time, at most 1024 px (see the header).
            if plan.target.isLogo {
                logo = await ImageDownsampler.intakeImage(from: data)
                break
            }
            if let jpeg = await ImageDownsampler.intakeJPEG(from: data) {
                photos.append(jpeg)
            }
        }
        photoItems = []
        showingPhotos = false
        pendingPlan = nil
        if plan.target.isLogo {
            guard let logo else {
                presenter.finishIfCurrent(startedAs: startedAs, owner: owner, .failed(MBHandoffFailure.documentFailed))
                return
            }
            guard presenter.presentationID == startedAs, presenter.isOwner(owner) else { return }
            logoCrop = MBLogoCrop(image: logo, plan: plan, startedAs: startedAs)
            return
        }
        // Something was picked but none of it could be read: a failure, not a "didn't pick".
        guard !photos.isEmpty else {
            presenter.finishIfCurrent(startedAs: startedAs, owner: owner, .failed(MBHandoffFailure.documentFailed))
            return
        }
        presenter.commitPick(startedAs: startedAs, owner: owner) { MBPickCommit.photos(photos, plan: plan, in: $0) }
    }

    private func cancelPhotos() {
        pendingPlan = nil
        presenter.finish(.cancelled(message: "The user didn't pick a photo."))
    }

    private func finishFiles(_ result: Result<[URL], Error>) {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        showingFiles = false
        guard case .success(let urls) = result, let url = urls.first else {
            presenter.finish(.cancelled(message: "The user didn't pick a file."))
            return
        }
        let startedAs = presenter.presentationID
        // Read and shrunk off the main thread: a 4032 px photo from Files is never decoded here
        // or stored full size (the same intake as a picked photo).
        Task {
            guard let picked = await MBPickCommit.intakeFile(at: url) else {
                presenter.finishIfCurrent(startedAs: startedAs, owner: owner, .failed(MBHandoffFailure.documentFailed))
                return
            }
            // A logo file is a picture to crop, like a picked photo (a PDF or text can't be one).
            if plan.target.isLogo {
                guard picked.isImage, let image = await ImageDownsampler.intakeImage(from: picked.data) else {
                    presenter.finishIfCurrent(startedAs: startedAs, owner: owner, .failed(MBHandoffFailure.documentFailed))
                    return
                }
                guard presenter.presentationID == startedAs, presenter.isOwner(owner) else { return }
                logoCrop = MBLogoCrop(image: image, plan: plan, startedAs: startedAs)
                return
            }
            let name = picked.isImage ? "Photo.jpg" : url.lastPathComponent
            presenter.commitPick(startedAs: startedAs, owner: owner) {
                MBPickCommit.file(picked.data, name: name, plan: plan, in: $0)
            }
        }
    }

    private func finishScan(_ images: [UIImage], plan: MBPickPlan) async {
        guard !images.isEmpty else {
            presenter.finish(.cancelled(message: "The user closed the scanner."))
            return
        }
        let startedAs = presenter.presentationID
        // Close the scanner BEFORE the pages are stitched and read (that takes a moment); the
        // work is off the main thread and saves nothing until it is done and the request is
        // still on.
        busyPresentation = startedAs
        defer { if busyPresentation == startedAs { busyPresentation = nil } }
        guard let read = await MBPickCommit.readScan(images) else {
            presenter.finishIfCurrent(startedAs: startedAs, owner: owner, .failed(MBHandoffFailure.documentFailed))
            return
        }
        presenter.commitPick(startedAs: startedAs, owner: owner) { MBPickCommit.commitScan(read, plan: plan, in: $0) }
    }

    private func finishContact(_ contact: CNContact, plan: MBPickPlan) {
        presenter.commitPick(startedAs: presenter.presentationID, owner: owner) {
            MBPickCommit.contact(contact, plan: plan, in: $0)
        }
    }
}

/// A picked logo on its way through the crop step.
struct MBLogoCrop: Identifiable {
    let id = UUID()
    let image: UIImage
    let plan: MBPickPlan
    /// The request this crop belongs to, so a crop finished after it ended saves nothing.
    var startedAs: UUID?
}

// MARK: - The share sheet

/// `UIActivityViewController` with its completion handler (contract A5: never a bare `ShareLink`
/// for a tool's share — the loop has to know whether it really went).
struct MBAIShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Send outcomes (A5)

@MainActor
enum MBSendOutcomeMapper {
    static var sharedRow: GLAIActivity {
        GLAIActivity(kind: .sent, symbol: MBWriteSymbol.sent, title: MBWriteStrings.sharedDocument)
    }

    static func outcome(_ result: SendOutcome, content: MBComposeContent) -> GLAIHandoffOutcome {
        switch result {
        case .sent:
            return .sent(channel: content.channel,
                         activity: GLAIActivity(kind: .sent, symbol: MBWriteSymbol.sent,
                                                title: content.activityTitle,
                                                detail: content.activityDetail, record: content.record))
        case .cancelled:
            return .cancelled()
        case .failed:
            return .sendFailed(record: content.record)
        }
    }
}
