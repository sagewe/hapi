import SwiftUI
#if targetEnvironment(macCatalyst)
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

    var body: some View {
        @Bindable var navigation = navigation
        // Observe selection here, not only inside the lazy stack root. That
        // root may be hidden behind a Boolean/item-based file destination.
        let selectedSessionId = navigation.selectedSessionId
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
                    // A stable native tab container retains the selected chat's
                    // SwiftUI graph and collection cells between visits. Hidden
                    // tabs receive normal disappearance/appearance callbacks.
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
            // Mac keeps its native navigation container while replacing the
            // selected chat. Touch layouts retain the existing stack reset.
            #if !targetEnvironment(macCatalyst)
            .id(selectedSessionId)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if targetEnvironment(macCatalyst)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            navigation.releaseInactiveDetails()
        }
        #endif
    }
}
