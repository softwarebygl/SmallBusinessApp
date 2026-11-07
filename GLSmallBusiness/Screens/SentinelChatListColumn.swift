//
//  SentinelChatListColumn.swift
//  GLSmallBusiness
//
//  Thin host wrapper around GoldLifeAI's canonical `GLAIChatSessionsListColumn` (Law 58).
//

import SwiftUI
import GoldLifeAI
import GoldLifeUI

struct SentinelChatListColumn: View {
    @Binding var selectedSessionID: UUID?

    var body: some View {
        GLAIChatSessionsListColumn(
            selectedSessionID: $selectedSessionID,
            title: mbLoc("Sentinel"),
            onStopActiveTurn: {
                MBAssistantSession.shared.controller?.stop()
            },
            onSelectSession: { session in
                Task {
                    await MBAssistantSession.shared.loadSession(session)
                }
            },
            onNewChat: { newSession in
                Task {
                    await MBAssistantSession.shared.loadSession(newSession, force: true)
                }
            },
            onDeleteSelectedSession: { nextSession in
                if let next = nextSession {
                    Task {
                        await MBAssistantSession.shared.loadSession(next, force: true)
                    }
                }
            },
            bannerContent: {
                MBSystemBannerInset()
            }
        )
    }
}
