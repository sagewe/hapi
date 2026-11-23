import HapiClient
import SwiftUI
import UIKit

/// Observe menu dependencies in their own view. A toast, reading-position change
/// or transcript update must not rebuild the native Mac toolbar menu.
struct ChatActionsMenu: View {
    #if targetEnvironment(macCatalyst) && DEBUG
    static weak var nativeMenuButton: UIButton?
    #endif
    struct State: Equatable {
        let parentID: String?
        let parentTitle: String?
        let canJump: Bool
        let assistant: Bool
        let terminalAvailable: Bool
        let active: Bool
        let scratchlistCount: Int
        let canFork: Bool
        let historyActionPending: Bool
        let canRewind: Bool
        let exporting: Bool
        let sessionActive: Bool?
        let sessionOperationPending: Bool

        @MainActor init(model: ChatModel, session: HubSession) {
            parentID = model.header.isParentNavigable ? model.header.parentSessionId : nil
            parentTitle = model.header.parentTitle
            canJump = !model.userTurnItems.isEmpty || !model.allMessageNavItems.isEmpty
            assistant = session.isAssistantMode
            terminalAvailable = session.sessionStore.detail(for: model.sessionId)?.metadata?.capabilities?.terminal != false
            active = model.header.active
            scratchlistCount = model.interactor.scratchlistCount
            canFork = model.interactor.canForkCurrentConversation
            historyActionPending = model.interactor.historyActionPending
            canRewind = !model.historyPointMessages.isEmpty
            exporting = model.isExporting
            sessionActive = model.sessionIsActive
            sessionOperationPending = model.interactor.sessionOpPending
        }
    }

    let state: State
    let model: ChatModel
    let session: HubSession
    var onOpenParentSession: ((String) -> Void)?
    @Binding var jumpOpen: Bool
    @Binding var previewPortOpen: Bool
    @Binding var terminalOpen: Bool
    @Binding var filesOpen: Bool
    @Binding var forkConfirmOpen: Bool
    @Binding var historyOpen: Bool
    @Binding var exportFormatOpen: Bool
    @Binding var renameOpen: Bool
    @Binding var deleteOpen: Bool
    var onCrossCheck: (() -> Void)? = nil

    var body: some View {
        if state.assistant { assistantMenu } else {
        #if targetEnvironment(macCatalyst)
        MacMenu(owner: self)
        #else
        swiftUIMenu
        #endif
        }
    }
    private var assistantMenu: some View {
        Menu {
            Button("重命名与标签", systemImage: "tag") { renameOpen = true }
            Button("导出对话", systemImage: "square.and.arrow.up") { exportFormatOpen = true }
            Button("标为未读", systemImage: "circle.badge") { model.markUnread() }
            if state.sessionActive == true {
                Button("归档", systemImage: "archivebox") { model.interactor.archiveSession() }
            } else {
                Button("重新打开", systemImage: "arrow.clockwise") { model.interactor.reopenSession() }
            }
            Button("删除", systemImage: "trash", role: .destructive) { deleteOpen = true }
            Divider()
            Button("用 Codex 交叉核验", systemImage: "sparkle.magnifyingglass") { onCrossCheck?() }
        } label: { Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 44) }
        .accessibilityLabel("更多操作")
    }

    private var swiftUIMenu: some View {
        Menu {
            if !state.assistant, let parentId = state.parentID,
               let parentTitle = state.parentTitle,
               let onOpenParentSession {
                Button {
                    onOpenParentSession(parentId)
                } label: {
                    Label(
                        String(format: String(localized: "Parent: %@"), parentTitle),
                        systemImage: "arrow.turn.up.left"
                    )
                }
                Divider()
            }
            if !state.assistant {
            Button {
                jumpOpen = true
            } label: {
                Label("Jump to Message…", systemImage: "list.bullet.indent")
            }
            .disabled(!state.canJump)
            Divider()
            }
            if !state.assistant {
            Button("Web Preview", systemImage: "globe") { previewPortOpen = true }
            if state.terminalAvailable {
                Button { terminalOpen = true } label: { Label("Terminal", systemImage: "terminal") }
                    .disabled(!state.active)
            }
            }
            Button { model.markUnread() } label: { Label("Mark as Unread", systemImage: "circle.badge") }
            if !state.assistant {
            Button {
                filesOpen = true
            } label: {
                Label("Session files", systemImage: "folder")
            }
            Button {
                model.interactor.setComposerDestination(.scratchlist)
            } label: {
                let count = state.scratchlistCount
                if count > 0 {
                    Label(
                        String(format: String(localized: "Scratchlist (%lld)"), Int64(count)),
                        systemImage: "note.text"
                    )
                } else {
                    Label("Scratchlist", systemImage: "note.text")
                }
            }
            Divider()
            if state.canFork {
                Button {
                    forkConfirmOpen = true
                } label: {
                    Label("Fork Conversation", systemImage: "arrow.triangle.branch")
                }
                .disabled(state.historyActionPending)
            }
            if state.canRewind {
                Button {
                    historyOpen = true
                } label: {
                    Label("Rewind or Fork…", systemImage: "clock.arrow.circlepath")
                }
            }
            }
            Button {
                exportFormatOpen = true
            } label: {
                Label("Export Conversation…", systemImage: "square.and.arrow.up")
            }
            .disabled(state.exporting)
            Divider()
            Button {
                renameOpen = true
            } label: {
                Label("Rename & Tags…", systemImage: "tag")
            }
            if state.sessionActive == true {
                Button {
                    model.interactor.archiveSession()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(state.sessionOperationPending)
            } else if state.sessionActive == false {
                Button {
                    model.interactor.reopenSession()
                } label: {
                    Label("Reopen", systemImage: "arrow.clockwise")
                }
                .disabled(state.sessionOperationPending)
                Button(role: .destructive) {
                    deleteOpen = true
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .disabled(state.sessionOperationPending)
            }
            if state.assistant {
                Divider()
                Button("用 Codex 交叉核验", systemImage: "sparkle.magnifyingglass") { onCrossCheck?() }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More actions")
        .help("More actions")
    }

}

#if targetEnvironment(macCatalyst)
private extension ChatActionsMenu {
    enum Action {
        case parent, jump, preview, terminal, unread, files, scratchlist, fork, rewind, export, rename, archive, reopen, delete
    }

    func perform(_ action: Action) {
        switch action {
        case .parent: if let id = state.parentID { onOpenParentSession?(id) }
        case .jump: jumpOpen = true
        case .preview: previewPortOpen = true
        case .terminal: terminalOpen = true
        case .unread: model.markUnread()
        case .files: filesOpen = true
        case .scratchlist: model.interactor.setComposerDestination(.scratchlist)
        case .fork: forkConfirmOpen = true
        case .rewind: historyOpen = true
        case .export: exportFormatOpen = true
        case .rename: renameOpen = true
        case .archive: model.interactor.archiveSession()
        case .reopen: model.interactor.reopenSession()
        case .delete: deleteOpen = true
        }
    }

    /// SwiftUI's toolbar bridge recreates NSMenu even when its Menu subtree
    /// compares equal. Keep the native menu on a stable button and update only
    /// its capability snapshot; handlers always use the current bindings.
    struct MacMenu: UIViewRepresentable {
        let owner: ChatActionsMenu

        func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "ellipsis")
            button.configuration = configuration
            button.showsMenuAsPrimaryAction = true
            button.accessibilityLabel = String(localized: "More actions")
            button.accessibilityIdentifier = "chat.more-actions"
            #if DEBUG
            ChatActionsMenu.nativeMenuButton = button
            #endif
            updateUIView(button, context: context)
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            let coordinator = context.coordinator
            coordinator.owner = owner
            let hasParentHandler = owner.onOpenParentSession != nil
            guard coordinator.state != owner.state || coordinator.hasParentHandler != hasParentHandler else { return }
            coordinator.state = owner.state
            coordinator.hasParentHandler = hasParentHandler
            button.menu = coordinator.menu()
        }

        @MainActor final class Coordinator {
            var owner: ChatActionsMenu
            var state: State?
            var hasParentHandler: Bool?
            init(owner: ChatActionsMenu) { self.owner = owner }

            func menu() -> UIMenu {
                let state = owner.state
                func item(_ title: String, _ image: String, _ action: Action,
                          disabled: Bool = false, destructive: Bool = false) -> UIAction {
                    var attributes: UIMenuElement.Attributes = []
                    if disabled { attributes.insert(.disabled) }
                    if destructive { attributes.insert(.destructive) }
                    return UIAction(title: title, image: UIImage(systemName: image), attributes: attributes) { [weak self] _ in
                        self?.owner.perform(action)
                    }
                }
                var groups: [UIMenuElement] = []
                func group(_ elements: [UIMenuElement]) {
                    if !elements.isEmpty { groups.append(UIMenu(options: .displayInline, children: elements)) }
                }
                if state.parentID != nil, let title = state.parentTitle, owner.onOpenParentSession != nil {
                    group([item(String(format: String(localized: "Parent: %@"), title), "arrow.turn.up.left", .parent)])
                }
                group([item(String(localized: "Jump to Message…"), "list.bullet.indent", .jump, disabled: !state.canJump)])
                var navigation: [UIMenuElement] = []
                if !state.assistant {
                    navigation.append(item(String(localized: "Web Preview"), "globe", .preview))
                    if state.terminalAvailable {
                        navigation.append(item(String(localized: "Terminal"), "terminal", .terminal, disabled: !state.active))
                    }
                }
                navigation.append(item(String(localized: "Mark as Unread"), "circle", .unread))
                if !state.assistant {
                    navigation.append(item(String(localized: "Session files"), "folder", .files))
                    let scratchlist = state.scratchlistCount > 0
                        ? String(format: String(localized: "Scratchlist (%lld)"), Int64(state.scratchlistCount))
                        : String(localized: "Scratchlist")
                    navigation.append(item(scratchlist, "note.text", .scratchlist))
                }
                group(navigation)
                var history: [UIMenuElement] = []
                if !state.assistant {
                    if state.canFork { history.append(item(String(localized: "Fork Conversation"), "arrow.triangle.branch", .fork, disabled: state.historyActionPending)) }
                    if state.canRewind { history.append(item(String(localized: "Rewind or Fork…"), "clock.arrow.circlepath", .rewind)) }
                }
                history.append(item(String(localized: "Export Conversation…"), "square.and.arrow.up", .export, disabled: state.exporting))
                group(history)
                var lifecycle: [UIMenuElement] = [item(String(localized: "Rename & Tags…"), "tag", .rename)]
                if state.sessionActive == true {
                    lifecycle.append(item(String(localized: "Archive"), "archivebox", .archive, disabled: state.sessionOperationPending))
                } else if state.sessionActive == false {
                    lifecycle.append(item(String(localized: "Reopen"), "arrow.clockwise", .reopen, disabled: state.sessionOperationPending))
                    lifecycle.append(item(String(localized: "Delete…"), "trash", .delete, disabled: state.sessionOperationPending, destructive: true))
                }
                group(lifecycle)
                return UIMenu(children: groups)
            }
        }
    }
}
#endif
