import SwiftUI
#if targetEnvironment(macCatalyst)
import HapiUI
import UIKit
#endif

/// Keep the same split/stack hierarchy across size-class changes. SwiftUI
/// moves the detail controller when collapsing instead of creating a second
/// ChatView (and a second interactor/SSE subscription).
struct SessionSplitView<Sidebar: View, Detail: View>: View {
    let navigation: SessionNavigationState
    let onNewSession: () -> Void
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: (String) -> Detail

    #if targetEnvironment(macCatalyst)
    @State private var chromeBySession: [String: MacSessionChrome] = [:]
    #endif

    var body: some View {
        @Bindable var navigation = navigation
        // Observe selection here, not only inside the lazy stack root. That
        // root may be hidden behind a Boolean/item-based file destination.
        let selectedSessionId = navigation.selectedSessionId
        #if targetEnvironment(macCatalyst)
        let chrome = selectedSessionId.flatMap { chromeBySession[$0] }
        #endif
        NavigationSplitView(
            columnVisibility: $navigation.columnVisibility,
            preferredCompactColumn: $navigation.preferredCompactColumn
        ) {
            sidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
        } detail: {
            NavigationStack(path: $navigation.detailPath) {
                if let sessionId = selectedSessionId {
                    #if targetEnvironment(macCatalyst)
                    TabView(selection: Binding(get: { navigation.selectedSessionId },
                                               set: { if let id = $0 { navigation.open(id) } })) {
                        ForEach(navigation.recentSessionIds, id: \.self) { id in
                            detail(id).id(id).tag(Optional(id))
                        }
                    }
                    .toolbar(.hidden, for: .tabBar)
                    #else
                    detail(sessionId)
                    #endif
                } else {
                    ContentUnavailableView {
                        Label("Select a session", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Choose a session from the sidebar, or start a new one.")
                    } actions: {
                        Button("New Session", action: onNewSession)
                            .buttonStyle(.borderedProminent)
                    }
                    .accessibilityIdentifier("home.no-selection")
                }
            }
            #if targetEnvironment(macCatalyst)
            // TabView absorbs standard navigation preferences. Forward only the
            // selected chat's chrome to the stable outer navigation stack.
            .navigationTitle(Text(verbatim: chrome?.header.title ?? ""))
            .toolbar {
                if let chrome {
                    if let status = chrome.status {
                        ToolbarItem(id: "mac.chat.status", placement: .topBarTrailing) { status }
                    }
                    if let picker = chrome.modelPicker {
                        ToolbarItem(id: "mac.chat.model", placement: .topBarTrailing) { picker }
                    }
                    ToolbarItem(id: "mac.chat.actions", placement: .topBarTrailing) { chrome.actions }
                }
            }
            .focusedSceneValue(\.chatCommands, chrome?.commands)
            #endif
            // Mac keeps its native navigation container while replacing the
            // selected chat. Touch layouts retain the existing stack reset.
            #if !targetEnvironment(macCatalyst)
            .id(selectedSessionId)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if targetEnvironment(macCatalyst)
        .onPreferenceChange(MacSessionChromeKey.self) { entries in
            let allowed = Set(navigation.recentSessionIds)
            var next = chromeBySession.filter { allowed.contains($0.key) }
            next.merge(entries.filter { allowed.contains($0.key) }) { _, new in new }
            if next != chromeBySession { chromeBySession = next }
        }
        .onChange(of: navigation.recentSessionIds) {
            chromeBySession = chromeBySession.filter { navigation.recentSessionIds.contains($0.key) }
        }
        .onChange(of: selectedSessionId) {
            MacTextSelectionTracker.shared.clear()
            if selectedSessionId == nil { chromeBySession.removeAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            navigation.releaseInactiveDetails()
        }
        #endif
    }
}
