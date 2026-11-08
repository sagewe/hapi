import SwiftUI

/// Actions the focused home window offers to the menu bar (Mac) and the
/// hardware-keyboard shortcut overlay (iPad).
struct HomeCommandActions {
    var newSession: () -> Void
    var openSettings: () -> Void
    /// Nil when the window has no sidebar to toggle (iPhone stack).
    var toggleSidebar: (() -> Void)?
    /// Opens the ⌘K quick session switcher palette.
    var openQuickSwitcher: (() -> Void)?
    /// Focuses the sidebar session search bar.
    var focusSearch: (() -> Void)?
    /// Refreshes the session list.
    var refresh: (() -> Void)?
    /// Selects the row above (-1) or below (+1) the open session.
    var selectAdjacentSession: ((Int) -> Void)?
    /// Selects the visible session row at 0-based index (0..<9 for ⌘1…⌘9).
    var selectSessionAtIndex: ((Int) -> Void)?
}

/// Actions of the chat shown in the focused window.
struct ChatCommandActions {
    var focusComposer: (() -> Void)?
    var toggleScratchlist: (() -> Void)?
    var jumpToLatest: (() -> Void)?
    var jumpToMessage: (() -> Void)?
    var previousMessage: (() -> Void)?
    var nextMessage: (() -> Void)?
    var openSessionSettings: () -> Void
    var openFiles: () -> Void
    var openTerminal: (() -> Void)?
    var openWebPreview: (() -> Void)?
    var markUnread: (() -> Void)?
    var archiveOrReopen: (() -> Void)?
    var isArchivedOrInactive = false
    var rename: () -> Void
    var export: (() -> Void)?
    var refreshChat: (() -> Void)?
    /// Nil unless the agent is mid-turn.
    var stop: (() -> Void)?
}

private struct HomeCommandActionsKey: FocusedValueKey {
    typealias Value = HomeCommandActions
}

private struct ChatCommandActionsKey: FocusedValueKey {
    typealias Value = ChatCommandActions
}

extension FocusedValues {
    var homeCommands: HomeCommandActions? {
        get { self[HomeCommandActionsKey.self] }
        set { self[HomeCommandActionsKey.self] = newValue }
    }

    var chatCommands: ChatCommandActions? {
        get { self[ChatCommandActionsKey.self] }
        set { self[ChatCommandActionsKey.self] = newValue }
    }
}

struct HapiCommands: Commands {
    @FocusedValue(\.homeCommands) private var home
    @FocusedValue(\.chatCommands) private var chat
    @Environment(\.openURL) private var openURL
    private var shortcuts = ShortcutPrefs.shared

    private static let guideURL = URL(string: "https://hapi.run/docs/guide/native-apps")

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { home?.newSession() }
                .configurableShortcut(.newSession, prefs: shortcuts)
                .disabled(home == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { home?.openSettings() }
                .keyboardShortcut(",")
                .disabled(home == nil)
        }
        // The composer is plain text; Format › Bold/Italic would also
        // shadow ⌘I.
        CommandGroup(replacing: .textFormatting) {}
        // Not a document app and no customizable toolbar.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .toolbar) {
            Button("Toggle Sidebar") { home?.toggleSidebar?() }
                .configurableShortcut(.toggleSidebar, prefs: shortcuts)
                .disabled(home?.toggleSidebar == nil)
            Button("Refresh") {
                home?.refresh?()
                chat?.refreshChat?()
            }
            .configurableShortcut(.refresh, prefs: shortcuts)
            .disabled(home?.refresh == nil && chat?.refreshChat == nil)
        }
        CommandGroup(replacing: .help) {
            if let url = Self.guideURL {
                Button("HAPI Guide") { openURL(url) }
            }
        }
        CommandMenu("Session") {
            Button("Quick Switch Session…") { home?.openQuickSwitcher?() }
                .configurableShortcut(.quickSwitch, prefs: shortcuts)
                .disabled(home?.openQuickSwitcher == nil)
            Button("Focus Composer") { chat?.focusComposer?() }
                .configurableShortcut(.focusComposer, prefs: shortcuts)
                .disabled(chat?.focusComposer == nil)
            Button("Toggle Scratchlist") { chat?.toggleScratchlist?() }
                .configurableShortcut(.toggleScratchlist, prefs: shortcuts)
                .disabled(chat?.toggleScratchlist == nil)
            Button("Jump to Message…") { chat?.jumpToMessage?() }
                .configurableShortcut(.jumpToMessage, prefs: shortcuts)
                .disabled(chat?.jumpToMessage == nil)
            Button("Previous User Message") { chat?.previousMessage?() }
                .configurableShortcut(.previousMessage, prefs: shortcuts)
                .disabled(chat?.previousMessage == nil)
            Button("Next User Message") { chat?.nextMessage?() }
                .configurableShortcut(.nextMessage, prefs: shortcuts)
                .disabled(chat?.nextMessage == nil)
            Button("Jump to Latest Message") { chat?.jumpToLatest?() }
                .configurableShortcut(.jumpToLatest, prefs: shortcuts)
                .disabled(chat?.jumpToLatest == nil)
            Button("Find Sessions…") { home?.focusSearch?() }
                .configurableShortcut(.focusSearch, prefs: shortcuts)
                .disabled(home?.focusSearch == nil)
            Divider()
            Button("Session Settings…") { chat?.openSessionSettings() }
                .configurableShortcut(.sessionSettings, prefs: shortcuts)
                .disabled(chat == nil)
            Button("Session Files") { chat?.openFiles() }
                .configurableShortcut(.sessionFiles, prefs: shortcuts)
                .disabled(chat == nil)
            Button("Remote Terminal") { chat?.openTerminal?() }
                .configurableShortcut(.remoteTerminal, prefs: shortcuts)
                .disabled(chat?.openTerminal == nil)
            Button("Web Preview…") { chat?.openWebPreview?() }
                .configurableShortcut(.webPreview, prefs: shortcuts)
                .disabled(chat?.openWebPreview == nil)
            Divider()
            Button("Mark as Unread") { chat?.markUnread?() }
                .configurableShortcut(.markUnread, prefs: shortcuts)
                .disabled(chat?.markUnread == nil)
            Button(chat?.isArchivedOrInactive == true ? "Reopen Session" : "Archive Session") {
                chat?.archiveOrReopen?()
            }
            .configurableShortcut(.archiveOrReopen, prefs: shortcuts)
            .disabled(chat?.archiveOrReopen == nil)
            Button("Rename…") { chat?.rename() }
                .configurableShortcut(.renameSession, prefs: shortcuts)
                .disabled(chat == nil)
            Button("Export Conversation…") { chat?.export?() }
                .configurableShortcut(.exportConversation, prefs: shortcuts)
                .disabled(chat?.export == nil)
            Divider()
            Button("Stop") { chat?.stop?() }
                .configurableShortcut(.stopTurn, prefs: shortcuts)
                .disabled(chat?.stop == nil)
            Divider()
            Button("Previous Session") { home?.selectAdjacentSession?(-1) }
                .configurableShortcut(.previousSession, prefs: shortcuts)
                .disabled(home?.selectAdjacentSession == nil)
            Button("Next Session") { home?.selectAdjacentSession?(1) }
                .configurableShortcut(.nextSession, prefs: shortcuts)
                .disabled(home?.selectAdjacentSession == nil)
            Button("Previous Session (Arrow)") { home?.selectAdjacentSession?(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(home?.selectAdjacentSession == nil)
            Button("Next Session (Arrow)") { home?.selectAdjacentSession?(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(home?.selectAdjacentSession == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Select Session \(number)") {
                    home?.selectSessionAtIndex?(number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(home?.selectSessionAtIndex == nil)
            }
        }
    }
}
