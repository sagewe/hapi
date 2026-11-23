#if targetEnvironment(macCatalyst)
import HapiProtocol
import SwiftUI

/// Values and live bindings from a cached chat. Equality excludes the erased
/// controls/closures: unchanged chrome must not rebuild the native toolbar for
/// transcript/toast updates. Bindings stay attached to the retained chat state.
struct MacSessionChrome: Equatable {
    let sessionId: String
    let header: ChatHeaderUI
    let menuState: ChatActionsMenu.State
    let profile: ClientProfile?
    let status: AnyView?
    let modelPicker: AnyView?
    let actions: AnyView
    let commands: ChatCommandActions

    private var commandAvailability: [Bool] {
        [commands.focusComposer != nil, commands.toggleScratchlist != nil,
         commands.jumpToLatest != nil, commands.jumpToMessage != nil,
         commands.previousMessage != nil, commands.nextMessage != nil,
         commands.openTerminal != nil, commands.openWebPreview != nil,
         commands.markUnread != nil, commands.archiveOrReopen != nil,
         commands.isArchivedOrInactive, commands.export != nil,
         commands.refreshChat != nil, commands.stop != nil]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.header == rhs.header && lhs.menuState == rhs.menuState
            && lhs.profile == rhs.profile && lhs.commandAvailability == rhs.commandAvailability
    }
}

struct MacSessionChromeKey: PreferenceKey {
    static let defaultValue: [String: MacSessionChrome] = [:]
    static func reduce(value: inout [String: MacSessionChrome], nextValue: () -> [String: MacSessionChrome]) {
        value.merge(nextValue()) { _, new in new }
    }
}
#endif
