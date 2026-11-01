//
//  SentinelChatListColumn.swift
//  GLSmallBusiness
//
//  iPad 3-column split view middle column: Chat sessions list for Sentinel.
//  Hosts the prominent "+ New Chat" action, in-list search, and past sessions
//  with active session switching and swipe-to-delete.
//

import SwiftUI
import GoldLifeAI
import GoldLifeUI

struct SentinelChatListColumn: View {
    @Binding var selectedSessionID: UUID?
    @ObservedObject private var chatService = AIChatService.shared
    @State private var searchText = ""
    @State private var pendingDelete: [ChatSession]?

    private var filteredSessions: [ChatSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return chatService.sessions
        }
        return chatService.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query) ||
            session.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        List(selection: $selectedSessionID) {
            newChatButton
            
            GLInListSearchHeader(text: $searchText, prompt: mbLoc("Search chats…")).asPlainListRow

            if chatService.sessions.isEmpty {
                ContentUnavailableView {
                    Label(mbLoc("No Chats"), systemImage: "sparkles")
                } description: {
                    Text(mbLoc("Tap New Chat to start a conversation."))
                }
                .listRowBackground(Color.clear)
            } else if filteredSessions.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredSessions) { session in
                    Button {
                        selectedSessionID = session.id
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                    .tag(session.id)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .confirmFirstDeleteSwipe { pendingDelete = [session] }
                }
            }
        }
        .swipeDeleteConfirmation($pendingDelete, title: "Delete this chat?") {
            delete($0)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .dismissesKeyboardOnInteraction()
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(mbLoc("Sentinel"))), for: .scrollContent)
        .mbSystemBanners()
        .containerBackground(for: .navigation) {
            GLTheme.background.ignoresSafeArea()
        }
        .navigationTitle(GLScript.padded(mbLoc("Sentinel")))
        .toolbarTitleDisplayMode(.large)
        .onAppear {
            if selectedSessionID == nil {
                selectedSessionID = chatService.activeSessionId
            }
        }
    }

    // MARK: - Subviews

    private var newChatButton: some View {
        Button {
            MBAssistantSession.shared.controller?.stop()
            chatService.startNewConversation()
            let newID = chatService.activeSessionId
            selectedSessionID = newID
            if let newSession = chatService.sessions.first(where: { $0.id == newID }) ?? chatService.sessions.first {
                Task {
                    await MBAssistantSession.shared.loadSession(
                        newSession,
                        force: true
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(GLTheme.accent)
                Text(mbLoc("New Chat"))
                    .font(.glBody.weight(.semibold))
                    .foregroundStyle(GLTheme.accent)
                Spacer()
            }
            .padding(.horizontal, GLLayout.rowContentPadding)
            .padding(.vertical, 10)
            .background(GLTheme.cardFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(GLTheme.accent.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, GLLayout.rowCardInset)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let isSelected = selectedSessionID == session.id
        let isDefaultTitle = session.title.isEmpty || session.title == "New Conversation" || session.title == AIChatService.newConversationTitle
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AIProviderIcon(provider: provider(for: session), size: 14)
                Text(isDefaultTitle ? mbLoc("New Conversation") : session.title)
                    .font(.glBody.weight(.semibold))
                    .foregroundStyle(GLTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(formattedDate(session.updatedAt))
                    .font(.glCaption)
                    .foregroundStyle(GLTheme.textTertiary)
            }
            if let lastMessage = session.messages.last?.content, !lastMessage.isEmpty {
                Text(lastMessage)
                    .font(.glCaption)
                    .foregroundStyle(GLTheme.textSecondary)
                    .lineLimit(2)
            } else {
                Text(mbLoc("No messages"))
                    .font(.glCaption)
                    .foregroundStyle(GLTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, GLLayout.rowContentPadding)
        .padding(.vertical, 10)
        .background(isSelected ? GLTheme.surfaceRaised : GLTheme.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? GLTheme.accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, GLLayout.rowCardInset)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func delete(_ items: [ChatSession]) {
        let wasSelected = items.contains { $0.id == selectedSessionID }
        if wasSelected {
            MBAssistantSession.shared.controller?.stop()
        }
        for item in items {
            chatService.deleteSession(id: item.id)
        }
        if wasSelected {
            selectedSessionID = chatService.activeSessionId
            if let next = chatService.sessions.first(where: { $0.id == chatService.activeSessionId }) {
                Task {
                    await MBAssistantSession.shared.loadSession(next, force: true)
                }
            }
        }
    }

    private func provider(for session: ChatSession) -> AIProvider {
        if let match = AIProvider.allCases.flatMap(\.availableModels).first(where: { $0.id == session.modelId }) {
            return match.provider
        }
        return .appleIntelligence
    }

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return mbLoc("Yesterday")
        } else {
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(MBLocalization.currentLocale))
        }
    }
}
