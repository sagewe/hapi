import Observation
import SwiftUI
import UIKit

/// Configurable keyboard shortcut action identifiers.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case newSession
    case quickSwitch
    case focusSearch
    case toggleSidebar
    case refresh
    case focusComposer
    case toggleScratchlist
    case jumpToLatest
    case jumpToMessage
    case previousMessage
    case nextMessage
    case sessionSettings
    case sessionFiles
    case remoteTerminal
    case webPreview
    case markUnread
    case archiveOrReopen
    case renameSession
    case exportConversation
    case stopTurn
    case previousSession
    case nextSession

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .newSession: "New Session"
        case .quickSwitch: "Quick Switch Session"
        case .focusSearch: "Find Sessions"
        case .toggleSidebar: "Toggle Sidebar"
        case .refresh: "Refresh"
        case .focusComposer: "Focus Composer"
        case .toggleScratchlist: "Toggle Scratchlist"
        case .jumpToLatest: "Jump to Latest Message"
        case .jumpToMessage: "Jump to Message…"
        case .previousMessage: "Previous User Message"
        case .nextMessage: "Next User Message"
        case .sessionSettings: "Session Settings"
        case .sessionFiles: "Session Files"
        case .remoteTerminal: "Remote Terminal"
        case .webPreview: "Web Preview"
        case .markUnread: "Mark as Unread"
        case .archiveOrReopen: "Archive / Reopen Session"
        case .renameSession: "Rename Session"
        case .exportConversation: "Export Conversation"
        case .stopTurn: "Stop Current Turn"
        case .previousSession: "Previous Session"
        case .nextSession: "Next Session"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .newSession: .init(key: "n", command: true)
        case .quickSwitch: .init(key: "k", command: true)
        case .focusSearch: .init(key: "f", command: true)
        case .toggleSidebar: .init(key: "s", command: true, control: true)
        case .refresh: .init(key: "r", command: true)
        case .focusComposer: .init(key: "l", command: true)
        case .toggleScratchlist: .init(key: "d", command: true, shift: true)
        case .jumpToLatest: .init(key: "downArrow", command: true, shift: true)
        case .jumpToMessage: .init(key: "j", command: true)
        case .previousMessage: .init(key: "upArrow", option: true)
        case .nextMessage: .init(key: "downArrow", option: true)
        case .sessionSettings: .init(key: "i", command: true)
        case .sessionFiles: .init(key: "o", command: true, shift: true)
        case .remoteTerminal: .init(key: "t", command: true)
        case .webPreview: .init(key: "p", command: true, shift: true)
        case .markUnread: .init(key: "u", command: true, shift: true)
        case .archiveOrReopen: .init(key: "e", command: true)
        case .renameSession: .init(key: "r", command: true, shift: true)
        case .exportConversation: .init(key: "e", command: true, shift: true)
        case .stopTurn: .init(key: ".", command: true)
        case .previousSession: .init(key: "[", command: true, shift: true)
        case .nextSession: .init(key: "]", command: true, shift: true)
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: String
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if shift { result.insert(.shift) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        return result
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "upArrow": return .upArrow
        case "downArrow": return .downArrow
        case "leftArrow": return .leftArrow
        case "rightArrow": return .rightArrow
        case "return": return .return
        case "escape": return .escape
        case "delete": return .delete
        case "tab": return .tab
        case "space": return .space
        default:
            guard let char = key.lowercased().first else { return nil }
            return KeyEquivalent(char)
        }
    }

    var displayString: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        switch key {
        case "upArrow": out += "↑"
        case "downArrow": out += "↓"
        case "leftArrow": out += "←"
        case "rightArrow": out += "→"
        case "return": out += "↩"
        case "escape": out += "⎋"
        case "delete": out += "⌫"
        case "tab": out += "⇥"
        case "space": out += "Space"
        default: out += key.uppercased()
        }
        return out
    }
}

@MainActor
@Observable
final class ShortcutPrefs {
    static let shared = ShortcutPrefs()

    private static let bindingsKey = "hapi.shortcuts.bindings.v1"
    private static let bareReturnKey = "hapi.shortcuts.bareReturnSends.v1"

    private let defaults: UserDefaults
    private(set) var customBindings: [ShortcutAction: ShortcutBinding] = [:]
    private(set) var bareReturnSends: Bool = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.bareReturnKey) != nil {
            self.bareReturnSends = defaults.bool(forKey: Self.bareReturnKey)
        }
        if let data = defaults.data(forKey: Self.bindingsKey),
           let raw = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            var loaded: [ShortcutAction: ShortcutBinding] = [:]
            for (k, v) in raw {
                if let action = ShortcutAction(rawValue: k) {
                    loaded[action] = v
                }
            }
            self.customBindings = loaded
        }
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        customBindings[action] ?? action.defaultBinding
    }

    func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        // Clear any other action that had this exact binding to prevent conflicts.
        for other in ShortcutAction.allCases where other != action {
            if self.binding(for: other) == binding {
                customBindings[other] = other.defaultBinding
            }
        }
        if binding == action.defaultBinding {
            customBindings.removeValue(forKey: action)
        } else {
            customBindings[action] = binding
        }
        persistBindings()
    }

    func setBareReturnSends(_ enabled: Bool) {
        bareReturnSends = enabled
        defaults.set(enabled, forKey: Self.bareReturnKey)
    }

    func resetAll() {
        customBindings.removeAll()
        bareReturnSends = true
        defaults.removeObject(forKey: Self.bindingsKey)
        defaults.set(true, forKey: Self.bareReturnKey)
    }

    private func persistBindings() {
        let raw = Dictionary(uniqueKeysWithValues: customBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.bindingsKey)
        }
    }
}

extension View {
    @ViewBuilder
    func configurableShortcut(_ action: ShortcutAction, prefs: ShortcutPrefs = .shared) -> some View {
        let binding = prefs.binding(for: action)
        if let key = binding.keyEquivalent {
            self.keyboardShortcut(key, modifiers: binding.eventModifiers)
        } else {
            self
        }
    }
}

// MARK: - Settings UI

struct KeyboardShortcutsSettingsView: View {
    @State private var prefs = ShortcutPrefs.shared
    @State private var recordingAction: ShortcutAction?

    var body: some View {
        List {
            Section {
                Toggle(
                    "Press Return to send message",
                    isOn: Binding(
                        get: { prefs.bareReturnSends },
                        set: { prefs.setBareReturnSends($0) }
                    )
                )
            } header: {
                Text("Composer")
            } footer: {
                Text(
                    prefs.bareReturnSends
                        ? "Return or ⌘Return sends; Shift+Return inserts a newline."
                        : "⌘Return sends; bare Return inserts a newline."
                )
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    let isRecording = recordingAction == action
                    let current = prefs.binding(for: action)
                    HStack {
                        Text(action.title)
                        Spacer()
                        Button {
                            recordingAction = isRecording ? nil : action
                        } label: {
                            Text(isRecording ? String(localized: "Press shortcut…") : current.displayString)
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.14))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click any shortcut badge and press a new key combination (must include ⌘, ⌃, or ⌥). Press Escape to cancel.")
            }

            Section {
                Button("Reset All Shortcuts to Defaults", role: .destructive) {
                    recordingAction = nil
                    prefs.resetAll()
                }
            }
        }
        .navigationTitle("Keyboard Shortcuts")
        .background {
            if let action = recordingAction {
                ShortcutKeyCaptureView(
                    onCapture: { captured in
                        prefs.setBinding(captured, for: action)
                        recordingAction = nil
                    },
                    onCancel: {
                        recordingAction = nil
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        }
    }
}

private struct ShortcutKeyCaptureView: UIViewRepresentable {
    let onCapture: (ShortcutBinding) -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> CaptureUIView {
        let view = CaptureUIView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: CaptureUIView, context: Context) {
        uiView.onCapture = onCapture
        uiView.onCancel = onCancel
        if !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }

    final class CaptureUIView: UIView {
        var onCapture: ((ShortcutBinding) -> Void)?
        var onCancel: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let key = presses.first?.key else {
                super.pressesBegan(presses, with: event)
                return
            }
            let flags = key.modifierFlags
            if key.keyCode == .keyboardEscape,
               flags.intersection([.command, .control, .alternate, .shift]).isEmpty {
                onCancel?()
                return
            }
            let hasPrimaryModifier = flags.contains(.command) || flags.contains(.control) || flags.contains(.alternate)
            guard hasPrimaryModifier, let token = Self.keyToken(for: key) else {
                return
            }
            let binding = ShortcutBinding(
                key: token,
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.alternate),
                control: flags.contains(.control)
            )
            onCapture?(binding)
        }

        private static func keyToken(for key: UIKey) -> String? {
            switch key.keyCode {
            case .keyboardUpArrow: return "upArrow"
            case .keyboardDownArrow: return "downArrow"
            case .keyboardLeftArrow: return "leftArrow"
            case .keyboardRightArrow: return "rightArrow"
            case .keyboardReturnOrEnter, .keypadEnter: return "return"
            case .keyboardDeleteOrBackspace: return "delete"
            case .keyboardTab: return "tab"
            case .keyboardSpacebar: return "space"
            default:
                let chars = key.charactersIgnoringModifiers.lowercased()
                guard let first = chars.first, !first.isWhitespace else { return nil }
                return String(first)
            }
        }
    }
}
