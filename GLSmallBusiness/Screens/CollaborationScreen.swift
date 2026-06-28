//
//  CollaborationScreen.swift
//  GLSmallBusiness
//
//  The OWNER side of CloudKit Sharing: mint (or manage) the one business-wide CKShare and hand it to the
//  system invite sheet (`UICloudSharingController`). Reachable from Settings only when the sharing engine
//  is on, so Release users never see a half-wired row.
//

import SwiftUI
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

struct CollaborationScreen: View {
    @State private var share: CKShare?
    @State private var presentingShareSheet = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Invite your other phone — a different Apple ID — or a trusted person to see and edit this business's data live. They install My Business, open your invite, and they're in. Full read-and-write.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await startSharing() }
                } label: {
                    if working {
                        ProgressView()
                    } else {
                        Label(share == nil ? "Invite a device or person" : "Manage invite",
                              systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(working)
            } footer: {
                if let share, case let names = participantNames(share), !names.isEmpty {
                    Text("Shared with \(names.joined(separator: ", ")).")
                }
            }
        }
        .glFormBackground()
        .navigationTitle("Collaborate")
        .task {
            // Surface the existing invite and fold any records added since it was sent into the share.
            share = CloudKitSyncEngine.currentShare()
            if let share { await CloudKitSyncEngine.addUnsharedRecords(to: share) }
        }
        .sheet(isPresented: $presentingShareSheet) {
            #if canImport(UIKit)
            if let share {
                CloudSharingSheet(share: share, container: CloudKitSyncEngine.ckContainer)
                    .ignoresSafeArea()
            }
            #endif
        }
        .alert("Sharing", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func startSharing() async {
        working = true
        defer { working = false }
        do {
            share = try await CloudKitSyncEngine.shareEverything()
            presentingShareSheet = true
        } catch {
            errorMessage = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    private func participantNames(_ share: CKShare) -> [String] {
        let formatter = PersonNameComponentsFormatter()
        return share.participants
            .filter { $0.role != .owner }
            .compactMap { $0.userIdentity.nameComponents }
            .map { formatter.string(from: $0) }
            .filter { !$0.isEmpty }
    }
}

#if canImport(UIKit)
/// Wraps the system invite/manage sheet. A CKShare already minted by `NSPersistentCloudKitContainer`
/// is handed straight in (no preparation handler needed).
private struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
}
#endif
