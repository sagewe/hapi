import HapiClient
import HapiProtocol
import HapiUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class ComposerMentionPresentationTests: XCTestCase {
    private struct OfflineHTTP: HTTPPerforming {
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    private func makeInteractor() throws -> ChatInteractor {
        let url = try XCTUnwrap(URL(string: "https://mentions.invalid"))
        let http = OfflineHTTP()
        let auth = AuthManager(baseURL: url, credentialStore: InMemoryCredentialStore(), performer: http)
        let api = APIClient(baseURL: url, authManager: auth, performer: http)
        let store = SessionListStore(api: api)
        for (id, title) in [("current", "Current"), ("peer", "会话参考"), ("other", "Another session")] {
            let session = Session(hasConversationContent: true, id: id, namespace: "default", seq: 1,
                createdAt: 1, updatedAt: 2, active: true, activeAt: 0,
                metadata: SessionMetadata(path: "/repo", host: "host", name: title, flavor: "claude"),
                metadataVersion: 1, agentStateVersion: 1, thinking: false, thinkingAt: 0)
            store.applySessionEvent(.sessionUpdated(namespace: nil, sessionId: id, data: .session(session)))
        }
        return ChatInteractor(sessionId: "current", api: api, sessionStore: store,
                              windows: MessageWindowControllers(provider: api))
    }

    @Observable fileprivate final class ComposerLayout {
        var height: CGFloat = 0
    }

    private struct ComposerHarness: View {
        let interactor: ChatInteractor
        let layout: ComposerLayout

        var body: some View {
            VStack {
                Spacer()
                ChatComposerView(interactor: interactor)
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { layout.height = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in layout.height = height }
                    })
            }
            .hapiTypography()
        }
    }

    func testTypingAtShowsThePickerAtTheCaretAndPreservesFocus() async throws {
        let interactor = try makeInteractor()
        let layout = ComposerLayout()
        let window = try host(ComposerHarness(interactor: interactor, layout: layout))
        defer { window.isHidden = true }
        try await settle()
        let input = try textView(in: window)
        input.becomeFirstResponder()
        input.insertText("😀 请参考 @会话Old, thanks")
        input.selectedRange = NSRange(location: "😀 请参考 @会话".utf16.count, length: 0)
        try await settle()
        let hits = interactor.mentionSuggestions(selection: input.selectedRange)
        XCTAssertEqual(hits.map(\.id), ["session:peer"])
        XCTAssertTrue(input.isFirstResponder, "Expanding the compact composer retains focus")
        let pickerHeight = layout.height
        input.selectedRange = NSRange(location: 0, length: 0)
        try await settle()
        // SwiftUI does not vend its virtual accessibility tree to app-hosted
        // XCTest. Measure the real production picker, not an AX test probe.
        XCTAssertGreaterThan(pickerHeight, layout.height + 50)
        XCTAssertEqual(interactor.composerText, "😀 请参考 @会话Old, thanks")
        XCTAssertTrue(input.isFirstResponder)
    }

    func testSelectedTextMarkedTextBlurAndScratchlistSuppressThePicker() async throws {
        let interactor = try makeInteractor()
        let layout = ComposerLayout()
        let window = try host(ComposerHarness(interactor: interactor, layout: layout))
        defer { window.isHidden = true }
        try await settle()
        let input = try textView(in: window)
        input.becomeFirstResponder()
        input.insertText("@")
        try await settle()
        let shortlistHeight = layout.height
        input.setMarkedText("会话", selectedRange: NSRange(location: 2, length: 0))
        try await settle()
        XCTAssertNotNil(input.markedTextRange)
        let hiddenHeight = layout.height
        XCTAssertGreaterThan(shortlistHeight, hiddenHeight + 100,
                             "IME candidates must not compete with HAPI suggestions")
        input.unmarkText()
        try await settle()
        XCTAssertGreaterThan(layout.height, hiddenHeight + 50)
        input.selectedRange = NSRange(location: 1, length: 1)
        try await settle()
        XCTAssertEqual(layout.height, hiddenHeight, accuracy: 2)
        input.selectedRange = NSRange(location: input.text.utf16.count, length: 0)
        input.resignFirstResponder()
        try await settle()
        XCTAssertEqual(layout.height, hiddenHeight, accuracy: 2)
        input.becomeFirstResponder()
        try await settle()
        XCTAssertGreaterThan(layout.height, hiddenHeight + 50)
        interactor.setComposerDestination(.scratchlist)
        try await settle()
        // Saving a draft has a taller action than Send, especially on Mac.
        // Assert the suggestions disappear without coupling to that toolbar.
        XCTAssertLessThan(layout.height, shortlistHeight - 50)
        XCTAssertEqual(interactor.composerText, "@会话")
    }

    func testProgrammaticPrefillAndSlashCommandKeepTheCaretAtTheEnd() async throws {
        let interactor = try makeInteractor()
        let window = try host(ChatComposerView(interactor: interactor).hapiTypography())
        defer { window.isHidden = true }
        try await settle()
        let input = try textView(in: window)
        input.becomeFirstResponder()
        input.insertText("old")
        try await settle()
        interactor.setComposerText("A restored 😀 draft")
        try await settle()
        XCTAssertEqual(input.selectedRange, NSRange(location: interactor.composerText.utf16.count, length: 0))
        interactor.selectSlashCommand(.init(name: "compact", source: "builtin"))
        try await settle()
        XCTAssertEqual(input.text, "/compact ")
        XCTAssertEqual(input.selectedRange, NSRange(location: 9, length: 0))
        XCTAssertTrue(input.isFirstResponder)
        input.insertText("x")
        interactor.setComposerText("A prefill arriving in the same turn as typing")
        try await settle()
        XCTAssertEqual(input.selectedRange.location, interactor.composerText.utf16.count)
        interactor.setComposerText("")
        try await settle()
        XCTAssertEqual(input.selectedRange, NSRange(location: 0, length: 0))
    }

    @Observable fileprivate final class TextDriver {
        var text = ""
        var selection = NSRange(location: 0, length: 0)
        var focused = false
        var composing = false
    }

    private struct EditorHarness: View {
        @Bindable var driver: TextDriver
        var body: some View {
            ComposerTextView(text: $driver.text, selection: $driver.selection,
                isFocused: $driver.focused, isComposing: $driver.composing,
                font: .systemFont(ofSize: 16), accessibilityLabel: "Message")
        }
    }

    func testPrefillKeepsDistinctUnicodeRepresentationsAndCaret() async throws {
        let driver = TextDriver()
        let window = try host(VStack { EditorHarness(driver: driver); Spacer() })
        defer { window.isHidden = true; window.rootViewController = nil }
        driver.text = "\u{e9}"
        try await settle()
        let input = try textView(in: window)
        driver.text = "e\u{301}"
        driver.selection = NSRange(location: 2, length: 0)
        try await settle()
        XCTAssertEqual(Array(input.text.utf16), [0x65, 0x301])
        XCTAssertEqual(input.selectedRange.location, 2)
    }

    func testMentionEditHonorsTheExplicitMidDraftCaretAndSupportsAnotherMention() async throws {
        let driver = TextDriver()
        let window = try host(VStack { EditorHarness(driver: driver); Spacer() })
        defer { window.isHidden = true }
        try await settle()
        let input = try textView(in: window)
        input.becomeFirstResponder()
        input.insertText("😀 看 @peerOld, thanks")
        input.selectedRange = NSRange(location: "😀 看 @pe".utf16.count, length: 0)
        try await settle()
        let hit = ComposerMentionSuggestion(id: "session:peer", text: "[Peer](/sessions/peer)",
            label: "@Peer", detail: "peer", source: .session(active: true))
        let edit = try XCTUnwrap(ComposerMentionSuggestions.inserting(hit, into: driver.text, selection: driver.selection))
        driver.text = edit.text
        driver.selection = edit.selection
        try await settle()
        XCTAssertEqual(input.text, "😀 看 [Peer](/sessions/peer) , thanks")
        XCTAssertEqual(input.selectedRange, edit.selection)
        XCTAssertTrue(input.isFirstResponder)
        input.insertText("@")
        try await settle()
        XCTAssertEqual(ComposerMentionSuggestions.query(in: driver.text, selection: driver.selection)?.search, "")
        XCTAssertTrue(input.text.hasSuffix(", thanks"))
    }

    func testEditorGrowsToItsPlatformLimitAndScrollsWithoutLosingTheSelection() async throws {
        let driver = TextDriver()
        let window = try host(VStack { EditorHarness(driver: driver); Spacer() })
        defer { window.isHidden = true }
        try await settle()
        let input = try textView(in: window)
        let oneLine = input.bounds.height
        XCTAssertGreaterThan(oneLine, 15)
        driver.text = "one\ntwo\nthree"
        try await settle()
        XCTAssertGreaterThan(input.bounds.height, oneLine + (input.font?.lineHeight ?? 0))
        XCTAssertFalse(input.isScrollEnabled)
        driver.text = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        try await settle()
        #if targetEnvironment(macCatalyst)
        let maximumLines: CGFloat = 12
        #else
        let maximumLines: CGFloat = 8
        #endif
        XCTAssertLessThanOrEqual(input.bounds.height, ceil(try XCTUnwrap(input.font).lineHeight * maximumLines) + 1)
        XCTAssertTrue(input.isScrollEnabled)
        driver.selection = NSRange(location: 5, length: 0)
        try await settle()
        XCTAssertEqual(input.selectedRange.location, 5)
        driver.text = "short"
        try await settle()
        XCTAssertEqual(input.bounds.height, oneLine, accuracy: 1)
    }

    #if targetEnvironment(macCatalyst)
    func testMacProductionEditorPreservesIMEUndoAndEmojiDeletion() async throws {
        let driver = TextDriver()
        let window = try host(VStack { EditorHarness(driver: driver); Spacer() })
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle()
        let input = try XCTUnwrap(try textView(in: window) as? ComposerTextView.NativeTextView)
        XCTAssertNil(input.textLayoutManager, "The production Mac composer must initialize its selected engine directly")
        XCTAssertTrue(input.becomeFirstResponder())
        input.insertText("前缀 😀 e\u{301} ")
        input.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0))
        try await settle()
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertTrue(driver.composing)
        var submissions = 0
        input.onReturn = { submissions += 1; return true }
        XCTAssertFalse(input.handleMacKeyPress(keyCode: .keyboardReturnOrEnter, modifiers: []))
        XCTAssertEqual(submissions, 0)
        input.insertText("中文")
        input.unmarkText()
        try await settle()
        let base = "前缀 😀 e\u{301} 中文"
        XCTAssertEqual(input.text, base)
        XCTAssertEqual(Array(driver.text.utf8), Array(base.utf8), "Snapshotting must preserve the original Unicode representation")
        XCTAssertFalse(driver.composing)

        let undo = try XCTUnwrap(input.undoManager)
        undo.removeAllActions()
        undo.beginUndoGrouping()
        input.insertText("!")
        undo.endUndoGrouping()
        try await settle()
        XCTAssertEqual(driver.text, base + "!")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        try await settle()
        XCTAssertEqual(driver.text, base)
        undo.redo()
        try await settle()
        XCTAssertEqual(driver.text, base + "!")
        input.selectedRange = NSRange(location: "前缀 😀".utf16.count, length: 0)
        input.deleteBackward()
        try await settle()
        XCTAssertEqual(driver.text, "前缀  e\u{301} 中文!")
        XCTAssertEqual(input.selectedRange.location, "前缀 ".utf16.count)
        XCTAssertTrue(input.isFirstResponder)
    }

    func testLongDraftSizingAgreesWithNativeLayoutAcrossWidthFontAndEdits() {
        let editor = ComposerTextView.NativeTextView(usingTextLayoutManager: false)
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        let drafts = [
            String(repeating: "中文草稿", count: 3000),
            String(repeating: "A long draft with words ", count: 1000),
            String(repeating: "😀👨‍👩‍👧‍👦👍🏽", count: 800),
            String(repeating: "first line\n", count: 1200),
            String(repeating: " ", count: 8000),
        ]
        for draft in drafts {
            for size in [CGFloat(12), 24] {
                editor.font = .systemFont(ofSize: size)
                editor.text = draft
                let limit = ceil(editor.font!.lineHeight * 12)
                for width in [CGFloat(160), 390, 1200] {
                    let native = editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
                    let bounded = editor.measuredHeight(width: width, maximum: limit)
                    XCTAssertEqual(min(native, limit), min(bounded, limit), accuracy: 1)
                    editor.selectedRange = NSRange(location: 3, length: 0)
                    _ = editor.measuredHeight(width: width, maximum: limit)
                    XCTAssertEqual(editor.selectedRange.location, 3)
                }
            }
        }
        editor.text = "short"
        XCTAssertLessThan(editor.measuredHeight(width: 390, maximum: 400), 400)
        editor.text = String(repeating: "changed prefix\n", count: 700)
        XCTAssertGreaterThan(editor.measuredHeight(width: 390, maximum: 200), 200)
        editor.text = String(repeating: "x", count: 2100)
        let width: CGFloat = 20000
        XCTAssertEqual(editor.measuredHeight(width: width, maximum: 200),
                       editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height, accuracy: 1)
    }
    #endif

    func testMentionListFitsNarrowAndAccessibleLayouts() throws {
        let hits = (0..<8).map { index in
            ComposerMentionSuggestion(id: "session:\(index)", text: "reference", label: "@很长的会话标题 / A long session title \(index)",
                detail: "12345678", source: .session(active: true))
        }
        for size in [DynamicTypeSize.large, .accessibility3] {
            let view = ComposerMentionList(suggestions: hits, surface: .white) { _ in }
                .environment(\.dynamicTypeSize, size)
            let measured = UIHostingController(rootView: view).sizeThatFits(in: .init(width: 252, height: 1000))
            XCTAssertLessThanOrEqual(measured.width, 252)
            XCTAssertGreaterThanOrEqual(measured.height, 4 * 44)
            XCTAssertLessThan(measured.height, 1000)
        }
    }

    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "en")))
        window.makeKeyAndVisible()
        return window
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }

    private func textView(in view: UIView) throws -> UITextView {
        func find(_ view: UIView) -> UITextView? {
            if let input = view as? UITextView, input.accessibilityIdentifier == "composer.text" { return input }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view))
    }

}
