//
//  GLSyncStatus.swift
//  GLSmallBusiness
//
//  The one thing the sync layer says OUT LOUD, and the one thing a person can say back.
//
//  `GLSyncEngine` is an actor and nothing in the UI can observe it. That was survivable while
//  the only states were "syncing" and "idle" — those are nobody's business (§4: never a nag,
//  never a badge). It stopped being survivable for the mass-delete circuit breaker: that state
//  stops the backup indefinitely, and a stopped backup the owner cannot see or clear is a
//  device that quietly stops protecting a business's books.
//
//  So exactly one state crosses over: paused-by-the-breaker, with the number that caused it,
//  and a way to continue. Everything else stays quiet.
//
//  QA 2026-10-03 F87 added a second: what the SERVER said no to. A refused or contested edit
//  is a person's work that did not back up, and law 6 says they hear about it (once, in a plain
//  alert) and the developer sees a log line (the engine writes it). Network weather stays
//  quiet: offline, rate limits and retries are still nobody's business.
//

import Foundation
import SwiftUI
import SwiftData
import GoldLifeUI

@MainActor
@Observable
final class GLSyncStatus {

    static let shared = GLSyncStatus()

    private init() {}

    /// Non-nil while the mass-delete breaker is holding this device. Restored from disk on the
    /// first cycle after launch, so it survives a relaunch exactly as the pause itself does.
    private(set) var pausedByMassDelete: GLSyncBreakerTrip?

    /// A "continue" is in flight. The button disables itself rather than letting two overrides
    /// be armed for one pause.
    private(set) var isResuming = false

    /// The sentence to show. Plain English, and it names what to do about it.
    var pausedMessage: String? {
        pausedByMassDelete.map { GLSyncEngine.pauseMessage(deletions: $0.deletions) }
    }

    func setPausedByMassDelete(_ trip: GLSyncBreakerTrip) {
        pausedByMassDelete = trip
    }

    func clear() {
        pausedByMassDelete = nil
        isResuming = false
    }

    // MARK: The server's refusals (QA 2026-10-03 F87)

    /// Sentences from the server not shown yet, oldest first. A sentence already waiting is
    /// not queued twice, so thirty edits refused for one reason are one alert.
    private(set) var pendingMessages: [String] = []

    func post(_ texts: [String]) {
        for text in texts where !text.isEmpty && !pendingMessages.contains(text) {
            pendingMessages.append(text)
        }
    }

    /// The next sentence to show, removed as it is handed out so it is shown exactly once.
    func takeMessage() -> String? {
        pendingMessages.isEmpty ? nil : pendingMessages.removeFirst()
    }

    /// Sign-out: the next person on this phone must never read the previous person's refusals.
    func clearMessages() {
        pendingMessages = []
    }

    /// The person read it and asked to carry on. Arms a ONE-TIME override and syncs — a second
    /// unexpected wave stops again, because "yes, that was me" was an answer about one page,
    /// not a setting.
    func resume() {
        guard !isResuming, let engine = GLSyncEngine.current else { return }
        isResuming = true
        Task {
            await engine.resumeAfterReview()
            isResuming = false
        }
    }
}

// MARK: - The Settings surface

/// Shown in Settings only while the backup is paused. There is no idle state and no badge:
/// a backup that is working is not something to be told about.
/// The QUIET, PERMANENT backup row.
///
/// The design note above ("a backup that is working is not something to be told
/// about") is right about badges and wrong about existence: before this, the only
/// evidence the Gold Life backup existed at all was a warning that appeared when
/// it BROKE. A contractor whose phone is his filing cabinet cannot confirm his
/// records are safe, and "is my stuff backed up" is the single most reassuring
/// thing this screen can answer. One line, no badge, no colour, no alarm.
///
/// It names what is still on this device (QA 2026-10-03 F88): "1 change waiting" (not sent
/// yet, or held for a lapsed subscription) or "1 change not backed up" (the server refused it
/// or another device's edit won) instead of the last backup time, which is only stamped when a
/// cycle leaves nothing but parked rows behind.
struct GLSyncBackupRow: View {

    @Query private var syncStates: [GLSyncState]
    /// Read so the row redraws when the outbox changes; counted by `MBSessionPurge`, the same
    /// count the sign-out warning gives.
    @Query private var outbox: [GLSyncOutboxEntry]
    @Environment(\.modelContext) private var modelContext
    @State private var status = GLSyncStatus.shared

    var body: some View {
        // Silent while something is actually wrong — GLSyncPausedSection already
        // owns that case and two messages about one subject is worse than none.
        if status.pausedMessage == nil {
            HStack {
                // The checkmark only when it is true: beside "1 change waiting" it said the
                // opposite of the words next to it.
                Label("Backup", systemImage: Self.symbol(lastSyncAt: syncStates.first?.lastSyncAt,
                                                         changes: changes))
                Spacer()
                Text(detail)
                    .foregroundStyle(GLTheme.textSecondary)
            }
        }
    }

    private var changes: MBSessionPurge.UnsyncedChanges {
        outbox.isEmpty ? MBSessionPurge.UnsyncedChanges() : MBSessionPurge.unsyncedChanges(in: modelContext)
    }

    private var detail: String {
        Self.detail(lastSyncAt: syncStates.first?.lastSyncAt, changes: changes)
    }

    /// The row's symbol, in step with `detail`.
    static func symbol(lastSyncAt: Date?, changes: MBSessionPurge.UnsyncedChanges) -> String {
        if changes.parked > 0 { return "exclamationmark.icloud" }
        if changes.waiting > 0 || lastSyncAt == nil { return "icloud" }
        return "checkmark.icloud"
    }

    /// What the row says. Something still on this device outranks the last backup time:
    /// showing a time while edits wait would say they are backed up when they are not.
    static func detail(lastSyncAt: Date?, changes: MBSessionPurge.UnsyncedChanges) -> String {
        if changes.parked > 0 {
            return changes.parked == 1
                ? mbLoc("1 change not backed up")
                : mbLoc("\(changes.parked) changes not backed up")
        }
        if changes.waiting > 0 {
            return changes.waiting == 1
                ? mbLoc("1 change waiting")
                : mbLoc("\(changes.waiting) changes waiting")
        }
        guard let at = lastSyncAt else { return mbLoc("Not yet backed up") }
        // The time or day in the app's language (law 25), not the phone's (QA 2026-10-03 F44).
        let locale = MBLocalization.currentLocale
        return Calendar.current.isDateInToday(at)
            ? at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            : at.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }
}

struct GLSyncPausedSection: View {

    @State private var status = GLSyncStatus.shared

    var body: some View {
        if let message = status.pausedMessage {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(GLTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Button {
                    status.resume()
                } label: {
                    HStack {
                        Text("Continue and delete them here")
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if status.isResuming {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(status.isResuming)
                // The button dims itself and grows a spinner, and the spinner has no
                // name — so the only thing VoiceOver could say about a tap that IS
                // working is "dimmed". An empty value the rest of the time keeps one
                // view identity across the change.
                .accessibilityValue(status.isResuming ? Text("Continuing…") : Text(verbatim: ""))
            } header: {
                InfoLabel("Backup", info: "Your records back up to your Gold Life account. This device stopped because another one deleted an unusual number of items at once.", topic: "Backup")
            } footer: {
                Text("Nothing on this device has changed yet. If those deletions weren’t yours, sign in on the other device and check before continuing.")
            }
        }
    }
}

// MARK: - The server's refusals, on screen (QA 2026-10-03 F87)

/// Shows each sentence `GLSyncStatus` holds once, in a plain alert: a refused edit, a contested
/// one, a file the server would not take. Law 6's person half; the engine logs the other half.
/// Every host takes from the same queue, so a sentence shown in one place is gone from all.
struct GLSyncMessageAlert: ViewModifier {

    @State private var status = GLSyncStatus.shared
    @State private var shown: String?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: presentNext)
            .onChange(of: status.pendingMessages) { presentNext() }
            .onChange(of: shown) { if shown == nil { presentNext() } }
            .alert(mbLoc("Backup"), isPresented: Binding(
                get: { shown != nil },
                set: { if !$0 { shown = nil } })) {
                Button(mbLoc("OK"), role: .cancel) {}
            } message: {
                // Already localized where it was written (the engine is not on the MainActor).
                Text(verbatim: shown ?? "")
            }
    }

    private func presentNext() {
        guard shown == nil, let next = status.takeMessage() else { return }
        shown = next
    }
}
