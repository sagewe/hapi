import AVFAudio
import HapiClient
import HapiProtocol
import HapiUI
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The chat input card (A-M3a, extended in A-M3f): attachments and the
/// multiline text field grow above a fixed bottom action row. The trailing
/// primary action is stateful: Stop while a turn runs with an empty draft,
/// otherwise Send (long-press offers "Send & steer" during a turn). The card
/// also hosts dictation and attachment controls, and a `/` command list
/// above the card while the input is a lone slash token, plus selection-aware
/// `@` session/file suggestions.
struct ChatComposerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.hapiTypography) private var typography
    let interactor: ChatInteractor
    /// nil ⇒ dictation unavailable (no controller wired) — mic button hidden.
    var dictation: DictationController?
    #if !targetEnvironment(macCatalyst)
    var holdDictation: HoldToDictateController?
    #endif
    var api: APIClient?
    var machineId: String?
    /// Folded iPhone Duo: the short outer screen keeps more transcript by
    /// letting the composer sit closer to the home indicator.
    var hugsBottomEdge = false
    var onOpenScratchlist: (ScratchlistEntry?, Bool) -> Void = { _, _ in }

    // Attachment pickers (the launchers live here; policy + upload live in
    // HapiKit — `AttachmentPreparer` / `ComposerAttachments`).
    @State private var configModel: SessionConfigModel
    @State private var quotaPopoverOpen = false
    @State private var attachDialogOpen = false
    @State private var photosPickerOpen = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var cameraOpen = false
    @State private var filePickerOpen = false
    @State private var textFocused = false
    @State private var textSelection = NSRange(location: 0, length: 0)
    @State private var isComposing = false
    @State private var preparingAttachment = false
    @State private var schedulePickerOpen = false
    @State private var selectedSuggestionIndex = 0
    @State private var dismissedSuggestionKey: String?
    @State private var sentHistory: [String] = []
    @State private var historyIndex: Int?
    @State private var draftBeforeHistory = ""
    // Secondary tools are bare symbols; only the primary action is a filled
    // circle (Messages / ChatGPT / Claude). Both follow Dynamic Type.
    #if targetEnvironment(macCatalyst)
    @ScaledMetric(relativeTo: .body) private var toolGlyphSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var primaryDiameter: CGFloat = 28
    #else
    @ScaledMetric(relativeTo: .body) private var toolGlyphSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var primaryDiameter: CGFloat = 34
    #endif

    init(
        interactor: ChatInteractor,
        dictation: DictationController? = nil,
        holdDictation: HoldToDictateController? = nil,
        api: APIClient? = nil,
        machineId: String? = nil,
        hugsBottomEdge: Bool = false,
        onOpenScratchlist: @escaping (ScratchlistEntry?, Bool) -> Void = { _, _ in }
    ) {
        self.interactor = interactor
        self.dictation = dictation
        #if !targetEnvironment(macCatalyst)
        self.holdDictation = holdDictation
        #endif
        self.api = api
        self.machineId = machineId
        self.hugsBottomEdge = hugsBottomEdge
        self.onOpenScratchlist = onOpenScratchlist
        _configModel = State(initialValue: SessionConfigModel(interactor: interactor, api: api, machineId: machineId))
    }

    private var scratchlistMode: Bool { interactor.composerDestination == .scratchlist }
    private var composerPrompt: LocalizedStringKey {
        if scratchlistMode {
            return "Keep an instruction for later…"
        }
        #if !targetEnvironment(macCatalyst)
        if !textFocused, holdDictation?.isAvailable == true {
            return "Hold to dictate…"
        }
        #endif
        return "Message the agent…"
    }

    private var text: Binding<String> {
        Binding(
            get: { interactor.composerText },
            set: { interactor.setComposerText($0) }
        )
    }

    /// Elevated iOS surface: white in light mode, lifted charcoal in dark
    /// mode. `secondarySystemBackground` made the whole composer read like a
    /// grouped form cell instead of a floating iOS control.
    private var composerSurfaceColor: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.12, alpha: 1)
                : .white
        })
    }

    private var primaryCircleFill: Color {
        colorScheme == .dark
            ? Color.white
            : Color(red: 0.08, green: 0.09, blue: 0.11)
    }

    private var primaryCircleForeground: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.09, blue: 0.11)
            : Color.white
    }

    private var primaryCircleDisabledFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.08)
    }

    private var primaryCircleDisabledForeground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.42)
            : Color.black.opacity(0.32)
    }

    private var mentionRequest: ComposerMentionFiles.Request? {
        guard textFocused, !isComposing, !scratchlistMode,
              let query = ComposerMentionSuggestions.query(in: interactor.composerText, selection: textSelection) else { return nil }
        return .init(query: query.search, flavor: interactor.mentionFlavor)
    }

    var body: some View {
        let composer = interactor.composer
        let attachments = interactor.attachments.items
        let rawSlashSuggestions = interactor.slashSuggestions
        let rawMentionSuggestions = mentionRequest == nil ? [] : interactor.mentionSuggestions(selection: textSelection)
        let rawSkillQuery = scratchlistMode ? nil : SkillSuggestions.query(in: interactor.composerText, selection: textSelection, composing: isComposing)
        let rawSkillMatches = rawSkillQuery.map { SkillSuggestions.matches(interactor.skills, query: $0.text, recent: interactor.recentSkills) } ?? []
        let suggestionKey: String? = {
            if !rawMentionSuggestions.isEmpty {
                return "mention:\(mentionRequest?.query ?? "")"
            }
            if !rawSlashSuggestions.isEmpty {
                return "slash:\(interactor.composerText)"
            }
            if let query = rawSkillQuery {
                return "skill:\(query.text)"
            }
            return nil
        }()
        let suggestionsDismissed = suggestionKey != nil && suggestionKey == dismissedSuggestionKey
        let mentionSuggestions = suggestionsDismissed ? [] : rawMentionSuggestions
        let slashSuggestions = suggestionsDismissed ? [] : rawSlashSuggestions
        let skillQuery = suggestionsDismissed ? nil : rawSkillQuery
        let skillMatches = suggestionsDismissed ? [] : rawSkillMatches
        let activeSuggestionCount: Int = {
            if !mentionSuggestions.isEmpty { return mentionSuggestions.count }
            if !slashSuggestions.isEmpty { return slashSuggestions.count }
            if skillQuery != nil { return skillMatches.count }
            return 0
        }()
        let clampedSuggestionIndex = activeSuggestionCount > 0
            ? min(max(0, selectedSuggestionIndex), activeSuggestionCount - 1)
            : 0
        let collapsed = isCollapsed(composer, attachments: attachments)
        VStack(spacing: 0) {
            if !mentionSuggestions.isEmpty {
                ComposerMentionList(
                    suggestions: mentionSuggestions,
                    selectedIndex: clampedSuggestionIndex,
                    surface: composerSurfaceColor
                ) { suggestion in
                    if let selection = interactor.selectMention(suggestion, selection: textSelection) {
                        textSelection = selection
                        textFocused = true
                    }
                }
                .padding(.bottom, 6)
            } else if !slashSuggestions.isEmpty {
                SlashCommandList(
                    commands: slashSuggestions,
                    selectedIndex: clampedSuggestionIndex,
                    surface: composerSurfaceColor
                ) { command in
                    interactor.selectSlashCommand(command)
                }
                .padding(.bottom, 6)
            }
            if let skillQuery {
                VStack(alignment: .leading, spacing: 0) {
                    if interactor.skillsLoading { ProgressView().padding(8) }
                    if let error = interactor.skillsError {
                        HStack {
                            Text(error).font(.caption)
                            Button("Retry") { Task { await interactor.loadSkills() } }
                        }.padding(8)
                    }
                    if !interactor.skillsLoading && interactor.skillsError == nil && skillMatches.isEmpty {
                        Text("No matching skills").foregroundStyle(.secondary).padding(12)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(skillMatches.enumerated()), id: \.element.name) { index, skill in
                                    let isSelected = index == clampedSuggestionIndex
                                    Button {
                                        guard !isComposing else { return }
                                        let result = SkillSuggestions.insert(skill.name, text: interactor.composerText, query: skillQuery)
                                        interactor.setComposerText(result.0)
                                        textSelection = result.1
                                        interactor.recordSkill(skill.name)
                                        textFocused = true
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("$" + skill.name)
                                            if let description = skill.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(skill.name)
                                }
                            }
                        }
                        .onChange(of: clampedSuggestionIndex) { _, newIndex in
                            guard skillMatches.indices.contains(newIndex) else { return }
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(skillMatches[newIndex].name, anchor: .center)
                            }
                        }
                    }.frame(height: min(CGFloat(skillMatches.count) * 64, 220))
                }.background(composerSurfaceColor, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(spacing: 0) {
                if scratchlistMode, let store = interactor.scratchlist {
                    ScratchlistDrawerView(store: store, sessionId: interactor.sessionId, interactor: interactor,
                        keyboardFocused: textFocused, onOpen: onOpenScratchlist)
                }
                if let error = interactor.scratchlistError {
                    ScratchlistErrorBanner(message: error,
                        actionTitle: interactor.scratchlistErrorDestination == nil ? "Dismiss" : "Retry",
                        retry: interactor.retryScratchlistComposerOperation)
                        .padding(.horizontal, 12)
                }
                if !attachments.isEmpty {
                    attachmentsRow(attachments)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if !scratchlistMode, let schedule = interactor.pendingSchedule {
                    ScheduledSendChip(schedule: schedule) {
                        interactor.setPendingSchedule(nil)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                if let dictation, case .recording(let startedAtMs) = dictation.state {
                    RecordingChipView(startedAtMs: startedAtMs) {
                        dictation.cancel()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                // The field keeps one structural identity across the compact
                // and expanded layouts so focus survives the switch.
                composerTextFieldRow(
                    composer: composer,
                    attachments: attachments,
                    collapsed: collapsed,
                    mentionSuggestions: mentionSuggestions,
                    slashSuggestions: slashSuggestions,
                    skillQuery: skillQuery,
                    skillMatches: skillMatches,
                    clampedSuggestionIndex: clampedSuggestionIndex,
                    activeSuggestionCount: activeSuggestionCount,
                    suggestionKey: suggestionKey
                )
                if !collapsed {
                    HStack(spacing: 0) {
                        composerLeadingTools(hasAttachments: !attachments.isEmpty)
                        Spacer(minLength: 0)
                        trailingActions(
                            composer,
                            attachments: attachments,
                            collapsed: false,
                            hasActiveSuggestions: activeSuggestionCount > 0 || skillQuery != nil
                        )
                    }
                    #if targetEnvironment(macCatalyst)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    #else
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    #endif
                }
            }
            .modifier(ComposerCardSurface(fill: composerSurfaceColor, isFocused: textFocused, isCollapsed: collapsed))
            #if !targetEnvironment(macCatalyst)
            .background {
                ComposerAttachmentPopupHost(
                    isPresented: $attachDialogOpen,
                    colorScheme: colorScheme,
                    onCamera: {
                        if CameraCaptureView.isAvailable {
                            cameraOpen = true
                        } else {
                            interactor.postNotice(String(localized: "Camera is unavailable"))
                        }
                    },
                    onPhotos: {
                        photosPickerOpen = true
                    },
                    onFiles: {
                        filePickerOpen = true
                    }
                )
            }
            #endif
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: collapsed)
        }
        .hapiReadingColumn()
        .padding(.top, 8)
        // Overlap the home-indicator safe area only while the software
        // keyboard is down; above a keyboard the normal gap applies.
        .padding(.bottom, hugsBottomEdge && !textFocused ? -8 : 8)
        .animation(.snappy, value: hugsBottomEdge && !textFocused)
        .task(id: rawSkillQuery != nil) { if rawSkillQuery != nil { await interactor.loadSkills() } }
        .task(id: mentionRequest) {
            await interactor.mentionFiles.load(mentionRequest)
        }
        .task(id: "\(interactor.sessionId):\(configModel.config.flavor ?? ""):\(configModel.config.active):\(machineId ?? "")") {
            if configModel.machineId != machineId {
                configModel.machineId = machineId
            }
            if api != nil, configModel.showsComposerModelMenu {
                configModel.loadModels()
            }
            #if !targetEnvironment(macCatalyst)
            if api != nil, configModel.showsQuota {
                configModel.loadQuota()
            }
            #endif
        }
        .onChange(of: machineId) { _, newValue in
            if configModel.machineId != newValue {
                configModel.machineId = newValue
            }
        }
        .onChange(of: ObjectIdentifier(interactor)) {
            configModel = SessionConfigModel(interactor: interactor, api: api, machineId: machineId)
        }
        .onChange(of: suggestionKey) { _, newKey in
            selectedSuggestionIndex = 0
            if newKey != dismissedSuggestionKey {
                dismissedSuggestionKey = nil
            }
        }
        .onChange(of: activeSuggestionCount) { _, count in
            if selectedSuggestionIndex >= count {
                selectedSuggestionIndex = max(0, count - 1)
            }
        }
        .onChange(of: interactor.composerFocusRequest) {
            textFocused = true
        }
        // Hardware keyboard: ⌘↩ sends (or parks draft in scratchlist mode); ⇧⌘↩ steers into active turn.
        .background {
            Group {
                if scratchlistMode {
                    Button("Save draft") { interactor.parkComposerDraft() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canParkDraft)
                } else {
                    Button("Send") { submitMessage() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!primaryAction(composer, attachments: attachments).canSend)
                    Button("Send & steer into current turn") { submitMessage(steer: true) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .disabled(!canSendAndSteer(composer, attachments: attachments))
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $schedulePickerOpen) {
            ScheduleTimeSheet { date in
                interactor.setPendingSchedule(.at(Int(date.timeIntervalSince1970 * 1000)))
            }
        }
        .task(id: dictation.map { ObjectIdentifier($0) }) {
            await dictation?.refreshAvailability()
        }
        #if !targetEnvironment(macCatalyst)
        .task(id: holdDictation.map { ObjectIdentifier($0) }) {
            await holdDictation?.refreshAvailability()
        }
        #endif
        .photosPicker(
            isPresented: $photosPickerOpen,
            selection: $photoSelection,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoSelection) {
            let items = photoSelection
            guard !items.isEmpty else { return }
            photoSelection = []
            Task {
                for item in items {
                    await ingestPhotoItem(item)
                }
            }
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraCaptureView { jpeg in
                Task {
                    await handle(AttachmentPreparer.prepare(
                        data: jpeg,
                        filename: AttachmentPreparer.cameraFilename(),
                        mimeType: "image/jpeg"
                    ))
                }
            }
            .ignoresSafeArea()
        }
        // Finder/Files drags anywhere on the composer attach like a file pick.
        .onDrop(of: [.item], isTargeted: nil) { providers in
            let loadable = providers.filter(ItemProviderAttachmentLoader.canLoad)
            guard !loadable.isEmpty, !interactor.scratchlistBusy, !interactor.isSending else { return false }
            ingest(loadable)
            return true
        }
        .fileImporter(
            isPresented: $filePickerOpen,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { outcome in
            guard case .success(let urls) = outcome else { return }
            Task {
                for url in urls {
                    await handle(AttachmentPreparer.prepare(fileURL: url))
                }
            }
        }
    }

    // MARK: - Attachment ingestion

    private func ingestPhotoItem(_ item: PhotosPickerItem) async {
        let type = item.supportedContentTypes.first
        if type?.conforms(to: .audiovisualContent) == true {
            // Videos import as a temp file (capped read in the preparer) so a
            // multi-GB pick never has to fit in memory.
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                interactor.postNotice(String(localized: "Couldn't read the selected video"))
                return
            }
            let result = await AttachmentPreparer.prepare(fileURL: movie.url)
            try? FileManager.default.removeItem(at: movie.url)
            await handle(result)
            return
        }
        let naming = AttachmentPreparer.photoFilename(for: type)
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            interactor.postNotice(String(format: String(localized: "Couldn't read %@"), naming.filename))
            return
        }
        await handle(AttachmentPreparer.prepare(
            data: data,
            filename: naming.filename,
            mimeType: naming.mimeType
        ))
    }

    private func ingest(_ providers: [NSItemProvider]) {
        Self.ingestProviders(providers, into: interactor)
    }

    static func acceptDroppedProviders(_ providers: [NSItemProvider], into interactor: ChatInteractor) -> Bool {
        let loadable = providers.filter(ItemProviderAttachmentLoader.canLoad)
        guard !loadable.isEmpty, !interactor.scratchlistBusy, !interactor.isSending else { return false }
        ingestProviders(loadable, into: interactor)
        return true
    }

    static func ingestProviders(_ providers: [NSItemProvider], into interactor: ChatInteractor) {
        Task { @MainActor in
            for provider in providers {
                guard let copy = await ItemProviderAttachmentLoader.copy(provider) else {
                    interactor.postNotice(String(format: String(localized: "Couldn't read %@"),
                                                 provider.suggestedName ?? String(localized: "the dropped item")))
                    continue
                }
                await handlePreparedResult(AttachmentPreparer.prepare(fileURL: copy.fileURL), into: interactor)
                copy.remove()
            }
        }
    }

    private func handle(_ result: PrepareResult) async {
        await Self.handlePreparedResult(result, into: interactor, onPreparingChange: { preparingAttachment = $0 })
    }

    private static func handlePreparedResult(
        _ result: PrepareResult,
        into interactor: ChatInteractor,
        onPreparingChange: ((Bool) -> Void)? = nil
    ) async {
        switch result {
        case .ready(let prepared):
            if interactor.composerDestination == .scratchlist, let store = interactor.scratchlist {
                onPreparingChange?(true)
                defer { onPreparingChange?(false) }
                let limits = await store.limits(sessionId: interactor.sessionId)
                let existing = interactor.attachments.scratchlistBudget
                let outcome = await Task.detached(priority: .userInitiated) {
                    ScratchlistAttachmentImport.prepare(data: prepared.bytes, filename: prepared.filename,
                        mimeType: prepared.mimeType, existing: existing, limits: limits)
                }.value
                switch outcome {
                case .ready(let attachment):
                    interactor.attachments.add(PreparedAttachment(filename: attachment.filename, mimeType: attachment.mimeType,
                        bytes: attachment.data, previewBytes: prepared.previewBytes), toScratchlist: true)
                case .rejected(let message): interactor.reportScratchlistError(message)
                }
            } else { interactor.attachments.add(prepared) }
        case .tooLarge(let filename, _):
            interactor.postNotice(String(format: String(localized: "%@ is over the 50 MB upload limit"), filename))
        case .unreadable(let filename):
            interactor.postNotice(String(format: String(localized: "Couldn't read %@"), filename))
        }
    }

    // MARK: - Attachment chips

    private func attachmentsRow(_ attachments: [ComposerAttachmentUI]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChipView(
                        attachment: attachment,
                        onRetry: { interactor.attachments.retry(attachment.id) },
                        onRemove: { interactor.attachments.remove(attachment.id) }
                    )
                    .disabled(interactor.scratchlistBusy || interactor.isSending)
                }
            }
        }
    }

    /// Web clock: relative presets (resolved at Send) or a specific time
    /// within 7 days. Unavailable with attachments — the hub rejects them.
    private func scheduleButton(hasAttachments: Bool) -> some View {
        let active = interactor.pendingSchedule != nil
        return Menu {
            Section("Schedule send") {
                ForEach(PendingSchedule.presets, id: \.self) { preset in
                    Button(ScheduledSendChip.presetLabel(preset)) {
                        interactor.setPendingSchedule(preset)
                    }
                }
                Button("Pick a Time…", systemImage: "calendar") {
                    schedulePickerOpen = true
                }
            }
            if active {
                Button("Don't Schedule", systemImage: "xmark") {
                    interactor.setPendingSchedule(nil)
                }
            }
        } label: {
            toolGlyph("clock", active: active ? AnyShapeStyle(.tint) : nil)
        }
        // Menu labels inherit the accent as their foreground, which tints
        // the relative `.secondary` style and reads as "on".
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(hasAttachments || interactor.scratchlistBusy)
        .accessibilityLabel("Schedule send")
        .accessibilityIdentifier("chat.schedule-send")
        .help("Schedule send")
    }

    @ViewBuilder
    private var addAttachmentButton: some View {
        #if targetEnvironment(macCatalyst)
        Menu {
            Button {
                filePickerOpen = true
            } label: {
                Label("Choose Files…", systemImage: "folder")
            }
            Button {
                photosPickerOpen = true
            } label: {
                Label("Photo Library…", systemImage: "photo.on.rectangle")
            }
        } label: {
            toolGlyph("plus")
        } primaryAction: {
            filePickerOpen = true
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(preparingAttachment || interactor.scratchlistBusy)
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("chat.add-attachment")
        .help("Attach files (click) · Hold for Photo Library")
        #else
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            attachDialogOpen.toggle()
        } label: {
            toolGlyph("plus")
        }
        .buttonStyle(.plain)
        .disabled(preparingAttachment || interactor.scratchlistBusy)
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("chat.add-attachment")
        .help("Add attachment")
        #endif
    }

    private func insertTrigger(_ symbol: String, atStartOnly: Bool = false) {
        guard !isComposing else { return }
        if atStartOnly {
            if interactor.composerText.isEmpty {
                interactor.setComposerText(symbol)
                textSelection = NSRange(location: symbol.utf16.count, length: 0)
            } else if !interactor.composerText.hasPrefix(symbol) {
                let updated = symbol + interactor.composerText
                interactor.setComposerText(updated)
                textSelection = NSRange(location: symbol.utf16.count, length: 0)
            }
            textFocused = true
            return
        }
        let source = interactor.composerText as NSString
        let range = textSelection.location <= source.length && NSMaxRange(textSelection) <= source.length
            ? textSelection
            : NSRange(location: source.length, length: 0)
        let needsSpace = range.location > 0
            && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: range.location - 1)) ?? " ")
        let value = needsSpace ? " " + symbol : symbol
        interactor.setComposerText(source.replacingCharacters(in: range, with: value))
        textSelection = NSRange(location: range.location + value.utf16.count, length: 0)
        textFocused = true
    }

    private func submitMessage(steer: Bool = false) {
        let trimmed = interactor.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, sentHistory.last != interactor.composerText {
            sentHistory.append(interactor.composerText)
            if sentHistory.count > 50 {
                sentHistory.removeFirst(sentHistory.count - 50)
            }
        }
        historyIndex = nil
        draftBeforeHistory = ""
        #if !targetEnvironment(macCatalyst)
        holdDictation?.clearInlineEditSession()
        #endif
        interactor.sendMessage(steer: steer)
        #if !targetEnvironment(macCatalyst)
        textFocused = false
        #endif
    }

    private var scratchlistButton: some View {
        Button {
            interactor.setComposerDestination(scratchlistMode ? .chat : .scratchlist)
        } label: {
            toolGlyph("tray", active: scratchlistMode ? AnyShapeStyle(.orange) : nil)
            .overlay(alignment: .topTrailing) {
                if interactor.scratchlistCount > 0 {
                    Text(verbatim: interactor.scratchlistCount > 99 ? "99+" : "\(interactor.scratchlistCount)")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(scratchlistMode ? AnyShapeStyle(.orange) : AnyShapeStyle(.gray), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .offset(x: -2, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(interactor.scratchlistBusy || interactor.isSending || preparingAttachment)
        .accessibilityLabel(String(format: String(localized: "Scratchlist (%lld)"), Int64(interactor.scratchlistCount)))
        .accessibilityValue(scratchlistMode ? String(localized: "Held — not sent") : String(localized: "Chat"))
        .accessibilityIdentifier("scratchlist.toggle")
        .help("Toggle Scratchlist (⇧⌘D)")
    }

    private var canParkDraft: Bool {
        interactor.hasComposerDraft && !interactor.scratchlistBusy && !interactor.isSending
            && !interactor.attachments.hasUnsettled && !preparingAttachment
    }

    private var parkButton: some View {
        Button { interactor.parkComposerDraft() } label: {
            HStack(spacing: 5) {
                if interactor.scratchlistBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "tray.and.arrow.down") }
                Text("Save draft").font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!canParkDraft)
        .accessibilityIdentifier("scratchlist.park")
        .help("Save draft to Scratchlist (⌘↩)")
    }

    // MARK: - Composer Input Row & iOS WeChat Hold-to-Dictate

    private func composerTextFieldRow(
        composer: ComposerState,
        attachments: [ComposerAttachmentUI],
        collapsed: Bool,
        mentionSuggestions: [ComposerMentionSuggestion],
        slashSuggestions: [SlashCommand],
        skillQuery: SkillSuggestions.Query?,
        skillMatches: [SkillSummary],
        clampedSuggestionIndex: Int,
        activeSuggestionCount: Int,
        suggestionKey: String?
    ) -> some View {
        HStack(alignment: collapsed ? .center : .top, spacing: 0) {
            if collapsed { addAttachmentButton }
            ZStack(alignment: collapsed ? .leading : .topLeading) {
                if interactor.composerText.isEmpty {
                    Text(composerPrompt)
                        .font(typography.bodyFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                #if targetEnvironment(macCatalyst)
                ComposerTextView(
                    text: text,
                    selection: $textSelection,
                    isFocused: $textFocused,
                    isComposing: $isComposing,
                    font: .systemFont(ofSize: typography.bodySize, weight: typography.boldText ? .semibold : .regular),
                    accessibilityLabel: scratchlistMode
                        ? String(localized: "Keep an instruction for later…")
                        : String(localized: "Message the agent…"),
                    onReturn: {
                        handleReturn(
                            composer,
                            attachments: attachments,
                            mentions: mentionSuggestions,
                            slashCommands: slashSuggestions,
                            skillQuery: skillQuery,
                            skillMatches: skillMatches,
                            selectedIndex: clampedSuggestionIndex
                        )
                    },
                    onSteerReturn: {
                        handleSteerReturn(composer, attachments: attachments)
                    },
                    onMoveSuggestion: { delta in
                        moveSuggestion(delta, count: activeSuggestionCount)
                    },
                    onTab: {
                        acceptSuggestion(
                            mentions: mentionSuggestions,
                            slashCommands: slashSuggestions,
                            skillQuery: skillQuery,
                            skillMatches: skillMatches,
                            selectedIndex: clampedSuggestionIndex
                        )
                    },
                    onEscape: {
                        handleEscape(
                            suggestionKey: suggestionKey,
                            hasVisiblePopup: activeSuggestionCount > 0 || skillQuery != nil
                        )
                    },
                    onPasteItems: ingest
                )
                #else
                ComposerTextView(
                    text: text,
                    selection: $textSelection,
                    isFocused: $textFocused,
                    isComposing: $isComposing,
                    font: .systemFont(ofSize: typography.bodySize, weight: typography.boldText ? .semibold : .regular),
                    accessibilityLabel: scratchlistMode
                        ? String(localized: "Keep an instruction for later…")
                        : (holdDictation?.isAvailable == true
                            ? String(localized: "Hold to dictate…")
                            : String(localized: "Message the agent…")),
                    onReturn: {
                        handleReturn(
                            composer,
                            attachments: attachments,
                            mentions: mentionSuggestions,
                            slashCommands: slashSuggestions,
                            skillQuery: skillQuery,
                            skillMatches: skillMatches,
                            selectedIndex: clampedSuggestionIndex
                        )
                    },
                    onSteerReturn: {
                        handleSteerReturn(composer, attachments: attachments)
                    },
                    onMoveSuggestion: { delta in
                        moveSuggestion(delta, count: activeSuggestionCount)
                    },
                    onTab: {
                        acceptSuggestion(
                            mentions: mentionSuggestions,
                            slashCommands: slashSuggestions,
                            skillQuery: skillQuery,
                            skillMatches: skillMatches,
                            selectedIndex: clampedSuggestionIndex
                        )
                    },
                    onEscape: {
                        handleEscape(
                            suggestionKey: suggestionKey,
                            hasVisiblePopup: activeSuggestionCount > 0 || skillQuery != nil
                        )
                    },
                    onPasteItems: ingest,
                    holdToDictateEnabled: !scratchlistMode && (holdDictation?.isAvailable == true),
                    hitTestOutsets: collapsed
                        ? UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
                        : UIEdgeInsets(top: 14, left: 16, bottom: 0, right: 16),
                    onHoldBegan: { location, windowSize in
                        if let holdDictation {
                            handleHoldBegan(location, windowSize: windowSize, controller: holdDictation)
                        }
                    },
                    onHoldChanged: { location, windowSize in
                        if let holdDictation {
                            handleHoldChanged(location, windowSize: windowSize, controller: holdDictation)
                        }
                    },
                    onHoldEnded: {
                        holdDictation?.endHold()
                    },
                    onHoldCancelled: {
                        holdDictation?.cancelIfHolding()
                    }
                )
                #endif
            }
            #if targetEnvironment(macCatalyst)
            .padding(.horizontal, collapsed ? 2 : 14)
            .padding(.top, collapsed ? 0 : 12)
            .padding(.bottom, collapsed ? 0 : 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if !textFocused {
                    textFocused = true
                }
            }
            #else
            .padding(.horizontal, collapsed ? 6 : 16)
            .padding(.top, collapsed ? 0 : 14)
            .padding(.bottom, collapsed ? 0 : 6)
            #endif
            if collapsed {
                trailingActions(
                    composer,
                    attachments: attachments,
                    collapsed: true,
                    hasActiveSuggestions: activeSuggestionCount > 0 || skillQuery != nil
                )
            }
        }
        #if targetEnvironment(macCatalyst)
        .padding(.horizontal, collapsed ? 4 : 0)
        .padding(.vertical, collapsed ? 4 : 0)
        #else
        .padding(.horizontal, collapsed ? 6 : 0)
        .padding(.vertical, collapsed ? 5 : 0)
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func handleHoldBegan(_ location: CGPoint, windowSize: CGSize, controller: HoldToDictateController) {
        guard case .idle = controller.phase else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            controller.context = VoiceRecognitionContext(sessionId: interactor.sessionId, draft: interactor.composerText)
            controller.beginHold(
                fingerX: Double(location.x),
                fingerY: Double(location.y),
                containerWidth: Double(windowSize.width),
                containerHeight: Double(windowSize.height)
            )
            textFocused = false
        case .denied:
            interactor.postNotice(String(localized: "Microphone access is disabled — allow it in Settings to dictate"))
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                if !granted {
                    interactor.postNotice(String(localized: "Microphone permission is needed for dictation"))
                }
            }
        @unknown default:
            break
        }
    }

    private func handleHoldChanged(_ location: CGPoint, windowSize: CGSize, controller: HoldToDictateController) {
        guard case .holding = controller.phase else { return }
        controller.updateFinger(
            fingerX: Double(location.x),
            fingerY: Double(location.y),
            containerWidth: Double(windowSize.width),
            containerHeight: Double(windowSize.height)
        )
    }
    #endif

    // MARK: - Dictation

    private func micButton(_ dictation: DictationController) -> some View {
        let recording: Bool = {
            if case .recording = dictation.state { return true }
            return false
        }()
        let busy = dictation.state == .starting || dictation.state == .transcribing
        return Button {
            toggleDictation(dictation)
        } label: {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
            } else {
                toolGlyph(recording ? "stop.circle" : "mic", active: recording ? AnyShapeStyle(.red) : nil)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(recording ? String(localized: "Stop dictation") : String(localized: "Dictate"))
    }

    private func toggleDictation(_ dictation: DictationController) {
        // Stopping never needs the permission; starting checks + requests it.
        guard dictation.state == .idle else {
            dictation.toggle()
            return
        }
        dictation.context = VoiceRecognitionContext(sessionId: interactor.sessionId, draft: interactor.composerText)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            dictation.toggle()
        case .denied:
            interactor.postNotice(String(localized: "Microphone access is disabled — allow it in Settings to dictate"))
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                if granted {
                    dictation.toggle()
                } else {
                    interactor.postNotice(String(localized: "Microphone permission is needed for dictation"))
                }
            }
        @unknown default:
            dictation.toggle()
        }
    }

    // MARK: - Buttons

    /// iOS collapses to a single-row Liquid Glass field while unfocused with
    /// an empty draft, and morphs into the two-row card on focus or draft input.
    /// Mac Catalyst always keeps the desktop action bar visible.
    private func isCollapsed(_ composer: ComposerState, attachments: [ComposerAttachmentUI]) -> Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        let isLegacyDictationActive: Bool = {
            guard let dictation else { return false }
            return dictation.state != .idle
        }()
        let isHoldDictationActive: Bool = {
            guard let holdDictation else { return false }
            if case .idle = holdDictation.phase { return false }
            return true
        }()
        return !textFocused
            && composer.text.isEmpty
            && attachments.isEmpty
            && !scratchlistMode
            && interactor.pendingSchedule == nil
            && interactor.scratchlistError == nil
            && !isLegacyDictationActive
            && !isHoldDictationActive
        #endif
    }

    @ViewBuilder
    private func composerLeadingTools(hasAttachments: Bool) -> some View {
        #if targetEnvironment(macCatalyst)
        addAttachmentButton
        if !scratchlistMode {
            Button {
                insertTrigger("@")
            } label: {
                toolGlyph("at")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mention")
            .help("Mention file or session (@)")

            Button {
                insertTrigger("/", atStartOnly: true)
            } label: {
                toolGlyph("slash.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Commands")
            .help("Slash commands (/)")

            Button {
                insertTrigger("$")
            } label: {
                toolGlyph("sparkles")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skills")
            .accessibilityIdentifier("chat.skills")
            .help("Insert skill ($)")
        }
        if interactor.scratchlist != nil { scratchlistButton }
        if !scratchlistMode {
            scheduleButton(hasAttachments: hasAttachments)
            if configModel.showsComposerModelMenu {
                composerModelMenu
            }
            if configModel.showsComposerPermissionMenu {
                composerPermissionMenu
            }
            if configModel.showsQuota {
                composerQuotaButton
            }
        }
        #else
        addAttachmentButton
        if !scratchlistMode {
            Button {
                insertTrigger("$")
            } label: {
                toolGlyph("sparkles")
            }
            .buttonStyle(.plain)
            .disabled(interactor.scratchlistBusy)
            .accessibilityLabel("Skills")
            .accessibilityIdentifier("chat.skills")
            .help("Insert skill ($)")
        }
        if interactor.scratchlist != nil {
            scratchlistButton
        }
        if !scratchlistMode {
            scheduleButton(hasAttachments: hasAttachments)
            if holdDictation?.isRefiningEdit == true {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("润色中…")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .transition(.opacity)
            }
            if interactor.hasUndoableVoiceEdit {
                Button {
                    holdDictation?.clearInlineEditSession()
                    let becameEmpty = interactor.undoVoiceInlineEdit()
                    if becameEmpty {
                        textFocused = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                        Text("撤销")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("撤销语音文字")
            }
        }
        #endif
    }

    @ViewBuilder
    private var composerModelMenuSections: some View {
        if configModel.showsModel {
            Section("Model") {
                if configModel.config.modelOptionsLoading {
                    Text("Loading models…")
                } else if configModel.modelLoadFailed {
                    Text("Failed to load models")
                    Button("Retry", systemImage: "arrow.clockwise") {
                        configModel.loadModels()
                    }
                } else if let options = configModel.config.modelOptions, !options.isEmpty {
                    Picker("Model", selection: Binding(
                        get: { configModel.currentModel },
                        set: { configModel.selectModel($0) }
                    )) {
                        if let current = configModel.unlistedModelOption {
                            Text(verbatim: current.label).tag(current.value).disabled(true)
                        }
                        ForEach(options, id: \.value) { option in
                            Text(verbatim: option.label)
                                .tag(option.value)
                                .accessibilityIdentifier("session-config-model-\(option.value ?? "default")")
                        }
                    }
                    .pickerStyle(.inline)
                } else if configModel.canDiscoverModels {
                    Button("Load Models", systemImage: "arrow.clockwise") {
                        configModel.loadModels()
                    }
                } else {
                    Text("Model list unavailable")
                }
            }
        } else if configModel.canDiscoverModels {
            Section("Model") {
                Button("Load Models", systemImage: "arrow.clockwise") {
                    configModel.loadModels()
                }
            }
        }
        if configModel.showsEffort {
            Section("Effort") {
                Picker("Effort", selection: Binding(
                    get: { configModel.currentEffort },
                    set: { configModel.selectEffort($0) }
                )) {
                    ForEach(configModel.effortOptions, id: \.value) { option in
                        Text(verbatim: option.label)
                            .tag(option.value)
                            .disabled(!configModel.canSelectEffort(option.value))
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private var composerModelMenu: some View {
        let hasCustomEffort = configModel.showsEffort && configModel.currentEffort != nil
        return Menu {
            if !configModel.config.active {
                Text("Session is offline")
            } else if configModel.config.controlledByUser {
                Text("Controlled from terminal")
            }
            composerModelMenuSections
        } label: {
            HStack(spacing: 4) {
                toolGlyph("cpu", active: hasCustomEffort ? AnyShapeStyle(.tint) : nil)
                Text(verbatim: configModel.modelSummaryValue)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 180)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(configModel.isApplying || interactor.scratchlistBusy)
        .accessibilityLabel("Model")
        .accessibilityValue(Text(verbatim: configModel.modelSummaryValue))
        .accessibilityIdentifier("chat.composer-model")
        .help(configModel.modelSummaryHelp)
    }
    #endif

    private var permissionIconName: String {
        switch configModel.permission.tone {
        case .danger:
            return "exclamationmark.shield"
        default:
            return "checkmark.shield"
        }
    }

    private var permissionIconStyle: AnyShapeStyle? {
        switch configModel.permission.tone {
        case .danger:
            return AnyShapeStyle(.red)
        case .warning:
            return AnyShapeStyle(.orange)
        case .neutral, .info:
            if configModel.permission != .default || (configModel.showsCollaborationMode && configModel.collaborationMode != .default) {
                return AnyShapeStyle(.tint)
            }
            return nil
        }
    }

    @ViewBuilder
    private var composerPermissionMenuSections: some View {
        if !configModel.config.permissionModes.isEmpty {
            Section("Permission mode") {
                Picker("Permission mode", selection: Binding(
                    get: { configModel.permission },
                    set: { configModel.selectPermission($0) }
                )) {
                    if !configModel.config.permissionModes.contains(where: { $0.mode == configModel.permission }) {
                        composerPermissionOption(PermissionModeOption(mode: configModel.permission)).disabled(true)
                    }
                    ForEach(configModel.config.permissionModes, id: \.mode) { option in
                        composerPermissionOption(option)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        if configModel.showsCollaborationMode {
            Section("Collaboration Mode") {
                Picker("Collaboration Mode", selection: Binding(
                    get: { configModel.collaborationMode },
                    set: { configModel.selectCollaborationMode($0) }
                )) {
                    ForEach(CodexCollaborationMode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.label)).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(!configModel.config.canChangeCollaborationMode)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private var composerPermissionMenu: some View {
        Menu {
            composerPermissionMenuSections
        } label: {
            HStack(spacing: 4) {
                toolGlyph(permissionIconName, active: permissionIconStyle)
                Text(verbatim: configModel.permissionSummaryValue)
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: 140)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(configModel.isApplying || interactor.scratchlistBusy)
        .accessibilityLabel("Permission mode")
        .accessibilityValue(Text(verbatim: configModel.permissionSummaryValue))
        .accessibilityIdentifier("chat.composer-permission")
        .help(configModel.permissionSummaryHelp)
    }
    #endif

    private func composerPermissionOption(_ option: PermissionModeOption) -> some View {
        Group {
            if option.tone == .danger {
                Label {
                    Text(verbatim: option.label) + Text(verbatim: " · ") + Text("High risk")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } else {
                Text(verbatim: option.label)
            }
        }
        .tag(option.mode)
        .accessibilityIdentifier("session-config-permission-\(option.mode.rawValue)")
    }

    #if targetEnvironment(macCatalyst)
    private var quotaIconStyle: AnyShapeStyle? {
        guard let peak = configModel.quotaPeakUsedPercent else { return nil }
        if peak >= 90 { return AnyShapeStyle(.red) }
        if peak >= 75 { return AnyShapeStyle(.orange) }
        return nil
    }

    private var composerQuotaButton: some View {
        Button {
            quotaPopoverOpen = true
        } label: {
            toolGlyph("gauge.with.dots.needle.33percent", active: quotaIconStyle)
        }
        .buttonStyle(.plain)
        .disabled(interactor.scratchlistBusy)
        .accessibilityLabel("Subscription Quota")
        .accessibilityIdentifier("chat.composer-quota")
        .help(String(localized: "Subscription Quota"))
        .popover(isPresented: $quotaPopoverOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ComposerQuotaPopoverView(model: configModel)
                .presentationCompactAdaptation(.popover)
        }
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    private var showsComposerSessionControls: Bool {
        configModel.showsComposerModelMenu || configModel.showsComposerPermissionMenu || configModel.showsQuota
    }

    private var composerControlsIconStyle: AnyShapeStyle? {
        if configModel.permission.tone == .danger || (configModel.quotaPeakUsedPercent ?? 0) >= 90 {
            return AnyShapeStyle(.red)
        }
        if configModel.permission.tone == .warning || (configModel.quotaPeakUsedPercent ?? 0) >= 75 {
            return AnyShapeStyle(.orange)
        }
        let hasCustomEffort = configModel.showsEffort && configModel.currentEffort != nil
        let hasCustomPermission = configModel.permission != .default
            || (configModel.showsCollaborationMode && configModel.collaborationMode != .default)
        if hasCustomEffort || hasCustomPermission {
            return AnyShapeStyle(.tint)
        }
        return nil
    }

    private var quotaMenuSubtitle: String? {
        guard case .loaded(let result) = configModel.quotaState else { return nil }
        let fiveHour = result.groups?.first?.fiveHour ?? result.fiveHour
        let sevenDay = result.groups?.first?.sevenDay ?? result.sevenDay
        var parts: [String] = []
        if let fiveHour {
            parts.append("5H \(fiveHour.usedPercentInt)%")
        }
        if let sevenDay {
            parts.append("7D \(sevenDay.usedPercentInt)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var composerSessionControlsButton: some View {
        Menu {
            if !configModel.config.active {
                Text("Session is offline")
            } else if configModel.config.controlledByUser {
                Text("Controlled from terminal")
            }
            if configModel.showsComposerModelMenu {
                Menu {
                    composerModelMenuSections
                } label: {
                    Label {
                        Text("Model")
                        Text(verbatim: configModel.modelSummaryValue)
                    } icon: {
                        Image(systemName: "cpu")
                    }
                }
                .accessibilityIdentifier("chat.composer-model")
            }
            if configModel.showsComposerPermissionMenu {
                Menu {
                    composerPermissionMenuSections
                } label: {
                    Label {
                        Text("Permission mode")
                        Text(verbatim: configModel.permissionSummaryValue)
                    } icon: {
                        Image(systemName: permissionIconName)
                    }
                }
                .accessibilityIdentifier("chat.composer-permission")
            }
            if configModel.showsQuota {
                Divider()
                Button {
                    quotaPopoverOpen = true
                } label: {
                    Label {
                        Text("Subscription Quota")
                        if let subtitle = quotaMenuSubtitle {
                            Text(verbatim: subtitle)
                        }
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                    }
                }
                .accessibilityIdentifier("chat.composer-quota")
            }
        } label: {
            toolGlyph("gauge.with.needle", active: composerControlsIconStyle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(configModel.isApplying || interactor.scratchlistBusy)
        .accessibilityLabel(String(localized: "Session controls"))
        .accessibilityValue(Text(verbatim: "\(configModel.modelSummaryValue) · \(configModel.permissionSummaryValue)"))
        .accessibilityIdentifier("chat.composer-controls")
        .popover(isPresented: $quotaPopoverOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ComposerQuotaPopoverView(model: configModel)
                .presentationCompactAdaptation(.popover)
        }
    }
    #endif

    @ViewBuilder
    private func trailingActions(
        _ composer: ComposerState,
        attachments: [ComposerAttachmentUI],
        collapsed: Bool = false,
        hasActiveSuggestions: Bool = false
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        Text(macShortcutHint(composer: composer, hasActiveSuggestions: hasActiveSuggestions))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.trailing, 6)
            .allowsHitTesting(false)
        #else
        if !collapsed && !scratchlistMode && showsComposerSessionControls {
            composerSessionControlsButton
        }
        #endif
        if scratchlistMode, composer.canStop {
            Button { interactor.abortSession() } label: {
                toolGlyph("stop.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop the current turn")
        }
        #if targetEnvironment(macCatalyst)
        if let dictation, dictation.isAvailable {
            micButton(dictation)
        }
        #else
        if !collapsed, hasVoiceInput, scratchlistMode || primaryAction(composer, attachments: attachments) != .voice {
            composerMicButton
        }
        #endif
        if scratchlistMode { parkButton }
        else { primaryActionButton(composer, attachments: attachments) }
    }

    private func macShortcutHint(composer: ComposerState, hasActiveSuggestions: Bool) -> String {
        if hasActiveSuggestions {
            return String(localized: "↑↓ Navigate · ↩ Accept · Esc")
        }
        if scratchlistMode {
            return String(localized: "⌘↩ Save draft")
        }
        let base = ShortcutPrefs.shared.bareReturnSends
            ? String(localized: "↩ Send · ⇧↩ Newline")
            : String(localized: "⌘↩ Send · ↩ Newline")
        if composer.canSendAndSteer {
            return base + String(localized: " · ⇧⌘↩ Steer")
        }
        return base
    }

    private func moveSuggestion(_ delta: Int, count: Int) -> Bool {
        guard !isComposing else { return false }
        if count > 0 {
            selectedSuggestionIndex = (selectedSuggestionIndex + delta + count) % count
            return true
        }
        // Up / Down arrow recalls sent message history when no popup is open
        guard !sentHistory.isEmpty else { return false }
        if delta < 0 {
            if let current = historyIndex {
                guard textSelection.location == 0 || textSelection.location == (interactor.composerText as NSString).length else {
                    return false
                }
                let nextIndex = max(0, current - 1)
                guard nextIndex != current else { return true }
                historyIndex = nextIndex
                let recalled = sentHistory[nextIndex]
                interactor.setComposerText(recalled)
                textSelection = NSRange(location: (recalled as NSString).length, length: 0)
                return true
            } else if interactor.composerText.isEmpty {
                draftBeforeHistory = interactor.composerText
                let index = sentHistory.count - 1
                historyIndex = index
                let recalled = sentHistory[index]
                interactor.setComposerText(recalled)
                textSelection = NSRange(location: (recalled as NSString).length, length: 0)
                return true
            }
        } else if delta > 0, let current = historyIndex {
            guard textSelection.location == (interactor.composerText as NSString).length || textSelection.location == 0 else {
                return false
            }
            if current + 1 < sentHistory.count {
                let nextIndex = current + 1
                historyIndex = nextIndex
                let recalled = sentHistory[nextIndex]
                interactor.setComposerText(recalled)
                textSelection = NSRange(location: (recalled as NSString).length, length: 0)
            } else {
                historyIndex = nil
                interactor.setComposerText(draftBeforeHistory)
                textSelection = NSRange(location: (draftBeforeHistory as NSString).length, length: 0)
            }
            return true
        }
        return false
    }

    private func acceptSuggestion(
        mentions: [ComposerMentionSuggestion],
        slashCommands: [SlashCommand],
        skillQuery: SkillSuggestions.Query?,
        skillMatches: [SkillSummary],
        selectedIndex: Int
    ) -> Bool {
        guard !isComposing else { return false }
        if !mentions.isEmpty {
            let suggestion = mentions[min(max(0, selectedIndex), mentions.count - 1)]
            if let selection = interactor.selectMention(suggestion, selection: textSelection) {
                textSelection = selection
            }
            return true
        }
        if !slashCommands.isEmpty {
            let command = slashCommands[min(max(0, selectedIndex), slashCommands.count - 1)]
            interactor.selectSlashCommand(command)
            return true
        }
        if !scratchlistMode, let query = skillQuery, !skillMatches.isEmpty {
            let skill = skillMatches[min(max(0, selectedIndex), skillMatches.count - 1)]
            let edit = SkillSuggestions.insert(skill.name, text: interactor.composerText, query: query)
            interactor.setComposerText(edit.0)
            textSelection = edit.1
            interactor.recordSkill(skill.name)
            return true
        }
        return false
    }

    private func handleEscape(suggestionKey: String?, hasVisiblePopup: Bool) -> Bool {
        guard !isComposing else { return false }
        if hasVisiblePopup, let suggestionKey {
            dismissedSuggestionKey = suggestionKey
            return true
        }
        if textFocused {
            textFocused = false
            return true
        }
        return false
    }

    private func canSendAndSteer(_ composer: ComposerState, attachments: [ComposerAttachmentUI]) -> Bool {
        !scratchlistMode && interactor.pendingSchedule == nil && composer.canSendAndSteer
            && primaryAction(composer, attachments: attachments).canSend
    }

    private func handleSteerReturn(_ composer: ComposerState, attachments: [ComposerAttachmentUI]) -> Bool {
        let liveComposer = interactor.composer
        let liveAttachments = interactor.attachments.items
        guard canSendAndSteer(liveComposer, attachments: liveAttachments) else { return false }
        submitMessage(steer: true)
        return true
    }

    /// Mac Return: picks the highlighted suggestion, otherwise sends when
    /// the Send button would. Scratchlist drafts keep Return as a newline.
    private func handleReturn(_ composer: ComposerState, attachments: [ComposerAttachmentUI],
                              mentions: [ComposerMentionSuggestion], slashCommands: [SlashCommand],
                              skillQuery: SkillSuggestions.Query?, skillMatches: [SkillSummary],
                              selectedIndex: Int) -> Bool {
        if acceptSuggestion(
            mentions: mentions,
            slashCommands: slashCommands,
            skillQuery: skillQuery,
            skillMatches: skillMatches,
            selectedIndex: selectedIndex
        ) {
            return true
        }
        guard !scratchlistMode else { return false }
        let liveComposer = interactor.composer
        let liveAttachments = interactor.attachments.items
        if primaryAction(liveComposer, attachments: liveAttachments).canSend {
            submitMessage()
        }
        return true
    }

    #if !targetEnvironment(macCatalyst)
    private var hasVoiceInput: Bool {
        holdDictation != nil || dictation?.isAvailable == true || (dictation != nil && dictation?.state != .idle)
    }
    #endif

    private func primaryAction(_ composer: ComposerState, attachments: [ComposerAttachmentUI]) -> ComposerPrimaryAction {
        let hasText = !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDraft = hasText || !attachments.isEmpty
        let scheduled = interactor.pendingSchedule != nil
        // Attachments gate the send like the web: every chip must settle
        // Ready (uploading waits, failed must be retried or removed); a ready
        // tray allows an attachments-only send (wire: text or attachments).
        // A scheduled send is text-only and never steers.
        let attachmentsBusy = attachments.contains { $0.status != .ready }
        let attachmentsReady = !attachments.isEmpty && !attachmentsBusy
        let isDictating: Bool = {
            guard let dictation else { return false }
            return dictation.state != .idle
        }()
        let canSubmit = scheduled
            ? hasText && attachments.isEmpty && !composer.isSending && !isDictating
            : (hasText || attachmentsReady) && !attachmentsBusy && !composer.isSending && !isDictating
        if composer.isSending {
            return .sending
        }
        #if !targetEnvironment(macCatalyst)
        let usesPrimaryVoiceSlot = isCollapsed(composer, attachments: attachments)
            || (!hasDraft && !scheduled && !composer.canStop)
        if isDictating && usesPrimaryVoiceSlot {
            return .voice
        }
        #endif
        if composer.canStop && !hasDraft {
            return .stop
        }
        #if !targetEnvironment(macCatalyst)
        if !hasDraft && !scheduled && hasVoiceInput {
            return .voice
        }
        #endif
        return .send(enabled: canSubmit)
    }

    @ViewBuilder
    private func primaryActionButton(_ composer: ComposerState, attachments: [ComposerAttachmentUI]) -> some View {
        let scheduled = interactor.pendingSchedule != nil
        switch primaryAction(composer, attachments: attachments) {
        case .sending:
            Button {} label: {
                actionCircle(
                    background: AnyShapeStyle(.fill.tertiary),
                    foreground: AnyShapeStyle(.secondary)
                ) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat.composer-send")
        case .stop:
            Button {
                interactor.abortSession()
            } label: {
                #if targetEnvironment(macCatalyst)
                actionCircle(
                    background: AnyShapeStyle(.tint),
                    foreground: AnyShapeStyle(.white)
                ) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: primaryDiameter * 0.36))
                }
                #else
                actionCircle(
                    background: AnyShapeStyle(primaryCircleFill),
                    foreground: AnyShapeStyle(primaryCircleForeground)
                ) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: primaryDiameter * 0.34, weight: .bold))
                }
                #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop the current turn")
            .accessibilityIdentifier("chat.composer-stop")
            .help("Stop the current turn (⌘.)")
        #if !targetEnvironment(macCatalyst)
        case .voice:
            voicePrimaryButton
        #endif
        case .send(let enabled):
            let label = sendLabel(enabled: enabled)
            if scheduled {
                Button {
                    submitMessage()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel("Schedule send")
                .accessibilityIdentifier("chat.composer-send")
                .help("Schedule send (↩)")
            } else if composer.canSendAndSteer && enabled {
                // Tap sends (queue); long-press or ⇧⌘↩ steers into the active turn.
                Menu {
                    Button("Send & steer into current turn (⇧⌘↩)") {
                        submitMessage(steer: true)
                    }
                } label: {
                    label
                } primaryAction: {
                    submitMessage()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Send — long-press to steer")
                .accessibilityIdentifier("chat.composer-send")
                .help("Send to queue (↩) · Steer into current turn (⇧⌘↩)")
            } else {
                Button {
                    submitMessage()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.composer-send")
                .help("Send (↩)")
            }
        }
    }

    #if !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var composerMicButton: some View {
        let isBusy = dictation?.state == .starting || dictation?.state == .transcribing
        let isRecording: Bool = {
            if let dictation, case .recording = dictation.state { return true }
            return false
        }()
        let holdEnabled = !scratchlistMode && holdDictation != nil

        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 34, minHeight: 40)
                .accessibilityLabel(String(localized: "Dictate"))
                .accessibilityIdentifier("chat.composer-mic")
        } else if isRecording, let dictation {
            Button {
                toggleDictation(dictation)
            } label: {
                toolGlyph("stop.circle.fill", active: AnyShapeStyle(.red))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Stop dictation"))
            .accessibilityIdentifier("chat.composer-mic")
        } else {
            toolGlyph("mic")
                .overlay {
                    VoicePrimaryTouchSurface(
                        a11yLabel: String(localized: "Dictate"),
                        a11yIdentifier: "chat.composer-mic",
                        holdEnabled: holdEnabled,
                        onTap: {
                            if let dictation {
                                toggleDictation(dictation)
                            } else if holdEnabled {
                                interactor.postNotice(String(localized: "Hold to dictate"))
                            }
                        },
                        onHoldBegan: { location, windowSize in
                            if let holdDictation, holdEnabled {
                                handleHoldBegan(location, windowSize: windowSize, controller: holdDictation)
                            }
                        },
                        onHoldChanged: { location, windowSize in
                            if let holdDictation, holdEnabled {
                                handleHoldChanged(location, windowSize: windowSize, controller: holdDictation)
                            }
                        },
                        onHoldEnded: {
                            if holdEnabled {
                                holdDictation?.endHold()
                            }
                        },
                        onHoldCancelled: {
                            if holdEnabled {
                                holdDictation?.cancelIfHolding()
                            }
                        }
                    )
                }
        }
    }

    @ViewBuilder
    private var voicePrimaryButton: some View {
        let isBusy = dictation?.state == .starting || dictation?.state == .transcribing
        let isRecording: Bool = {
            if let dictation, case .recording = dictation.state { return true }
            return false
        }()

        if isBusy {
            Button {} label: {
                actionCircle(
                    background: AnyShapeStyle(primaryCircleDisabledFill),
                    foreground: AnyShapeStyle(primaryCircleFill)
                ) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel(String(localized: "Dictate"))
            .accessibilityIdentifier("chat.composer-voice")
        } else if isRecording, let dictation {
            Button {
                toggleDictation(dictation)
            } label: {
                actionCircle(
                    background: AnyShapeStyle(Color.red),
                    foreground: AnyShapeStyle(Color.white)
                ) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: primaryDiameter * 0.34, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Stop dictation"))
            .accessibilityIdentifier("chat.composer-voice")
        } else {
            actionCircle(
                background: AnyShapeStyle(primaryCircleFill),
                foreground: AnyShapeStyle(primaryCircleForeground)
            ) {
                Image(systemName: "waveform")
                    .font(.system(size: primaryDiameter * 0.46, weight: .semibold))
            }
            .overlay {
                VoicePrimaryTouchSurface(
                    a11yLabel: String(localized: "Voice input"),
                    a11yIdentifier: "chat.composer-voice",
                    holdEnabled: holdDictation != nil,
                    onTap: {
                        if let dictation {
                            toggleDictation(dictation)
                        } else if let holdDictation {
                            interactor.postNotice(String(localized: "Hold to dictate"))
                            _ = holdDictation
                        }
                    },
                    onHoldBegan: { location, windowSize in
                        if let holdDictation {
                            handleHoldBegan(location, windowSize: windowSize, controller: holdDictation)
                        }
                    },
                    onHoldChanged: { location, windowSize in
                        if let holdDictation {
                            handleHoldChanged(location, windowSize: windowSize, controller: holdDictation)
                        }
                    },
                    onHoldEnded: {
                        holdDictation?.endHold()
                    },
                    onHoldCancelled: {
                        holdDictation?.cancelIfHolding()
                    }
                )
            }
        }
    }
    #endif

    private func sendLabel(enabled: Bool) -> some View {
        #if targetEnvironment(macCatalyst)
        actionCircle(
            background: enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
            foreground: enabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
        ) {
            Image(systemName: "arrow.up")
                .font(.system(size: primaryDiameter * 0.47, weight: .semibold))
        }
        #else
        actionCircle(
            background: enabled ? AnyShapeStyle(primaryCircleFill) : AnyShapeStyle(primaryCircleDisabledFill),
            foreground: enabled ? AnyShapeStyle(primaryCircleForeground) : AnyShapeStyle(primaryCircleDisabledForeground)
        ) {
            Image(systemName: "arrow.up")
                .font(.system(size: primaryDiameter * 0.46, weight: .bold))
        }
        #endif
    }

    /// Bare secondary tool symbol; `active` recolors it for
    /// a state (scheduled, held, recording) without changing its shape.
    private func toolGlyph(_ name: String, active: AnyShapeStyle? = nil) -> some View {
        #if targetEnvironment(macCatalyst)
        let slotWidth: CGFloat = 32
        let slotHeight: CGFloat = 32
        #else
        let slotWidth: CGFloat = 34
        let slotHeight: CGFloat = 40
        #endif
        return Image(systemName: name)
            .font(.system(size: toolGlyphSize, weight: .medium))
            .foregroundStyle(active ?? AnyShapeStyle(.secondary))
            .frame(minWidth: slotWidth, minHeight: slotHeight)
            .contentShape(Rectangle())
    }

    /// The primary action (send / stop / voice / sending): a filled circle.
    private func actionCircle<Content: View>(
        background: AnyShapeStyle,
        foreground: AnyShapeStyle,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        let slotWidth: CGFloat = 32
        let slotHeight: CGFloat = 32
        #else
        let slotWidth: CGFloat = 40
        let slotHeight: CGFloat = 40
        #endif
        return content()
            .foregroundStyle(foreground)
            .frame(width: primaryDiameter, height: primaryDiameter)
            .background(background, in: Circle())
            .frame(minWidth: slotWidth, minHeight: slotHeight)
            .contentShape(Rectangle())
    }
}

private struct ComposerQuotaPopoverView: View {
    let model: SessionConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Subscription Quota", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.subheadline.weight(.semibold))
                if case .loaded(let result) = model.quotaState, let plan = result.planType, !plan.isEmpty {
                    Text(verbatim: plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Spacer(minLength: 8)
                if case .loaded(let result) = model.quotaState, result.stale {
                    Text("Cached")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button {
                    model.loadQuota(force: true)
                } label: {
                    if model.quotaState == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.quotaState == .loading)
                .accessibilityLabel("Refresh Quota")
                .help("Refresh Quota")
            }

            switch model.quotaState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading quota…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            case .disabled:
                Button {
                    model.loadQuota(force: true)
                } label: {
                    Label("Query Subscription Quota", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        model.loadQuota(force: true)
                    }
                    .font(.caption.weight(.semibold))
                }
            case .loaded(let result):
                if result.status != "success", let err = result.error {
                    Text(verbatim: err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let groups = result.groups, !groups.isEmpty {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            quotaWindowRow(label: "5H", window: group.fiveHour)
                            if group.sevenDay != nil {
                                quotaWindowRow(label: "7D", window: group.sevenDay)
                            }
                        }
                    }
                } else {
                    quotaWindowRow(label: "5H", window: result.fiveHour)
                    quotaWindowRow(label: "7D", window: result.sevenDay)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 340, alignment: .leading)
        .onAppear {
            model.loadQuota()
        }
    }

    private func quotaWindowRow(label: String, window: UsageQueryWindow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(.caption.monospaced().weight(.semibold))
                Spacer(minLength: 4)
                if let window {
                    Text(verbatim: "\(window.usedPercentInt)% used · \(window.remainingPercentInt)% left")
                        .font(.caption.monospacedDigit())
                    if window.resetsAt != nil {
                        Text(verbatim: "· ↻ \(window.formatResetCountdown())")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let window {
                let used = window.usedPercentInt
                ProgressView(value: Double(used), total: 100)
                    .tint(used >= 90 ? .red : (used >= 75 ? .orange : .accentColor))
            }
        }
    }
}

/// The composer floats over the transcript (bottom safe-area inset): Liquid
/// Glass on iOS 26 to match the glass navigation controls, otherwise the
/// elevated surface with a hairline edge so it separates from white rows.
private struct ComposerCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let fill: Color
    var isFocused: Bool = false
    var isCollapsed: Bool = false

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let borderColor = isFocused
            ? Color.accentColor.opacity(0.45)
            : Color(uiColor: .separator).opacity(0.45)
        let borderWidth: CGFloat = isFocused ? 1.5 : 0.75
        if #available(iOS 26.0, *) {
            content
                .background(shape.fill(fill.opacity(0.7)))
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
        } else {
            content
                .background(shape.fill(fill))
                .clipShape(shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
        #else
        let cornerRadius: CGFloat = 16
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        let specularRim = LinearGradient(
            colors: [
                Color.white.opacity(isDark ? 0.22 : 0.72),
                Color.white.opacity(isDark ? 0.06 : 0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        if #available(iOS 26.0, *) {
            content
                .background(shape.fill(Color.white.opacity(isDark ? 0.05 : 0.36)))
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(specularRim, lineWidth: 0.75))
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(isDark ? Color(white: 0.14).opacity(0.45) : Color.white.opacity(0.45)))
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(specularRim, lineWidth: 0.75))
                .shadow(color: .black.opacity(isDark ? 0.28 : 0.10), radius: 14, y: 4)
        }
        #endif
    }
}

private enum ComposerPrimaryAction: Equatable {
    case sending
    case stop
    #if !targetEnvironment(macCatalyst)
    case voice
    #endif
    case send(enabled: Bool)

    var canSend: Bool {
        if case .send(true) = self { return true }
        return false
    }
}

#if !targetEnvironment(macCatalyst)
/// Raw touch surface over the empty-state `waveform` voice input circle:
/// - Quick tap (`< 150ms`) toggles hands-free dictation (`RecordingChipView` -> inserts draft).
/// - Stationary hold (`>= 150ms`) or drag (`> 14pt`) engages WeChat Hold-to-Dictate seamlessly.
private struct VoicePrimaryTouchSurface: UIViewRepresentable {
    var a11yLabel: String
    var a11yIdentifier: String
    var holdEnabled: Bool
    var onTap: () -> Void
    var onHoldBegan: (CGPoint, CGSize) -> Void
    var onHoldChanged: (CGPoint, CGSize) -> Void
    var onHoldEnded: () -> Void
    var onHoldCancelled: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.configure(with: self)
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.configure(with: self)
    }

    static func dismantleUIView(_ uiView: TouchView, coordinator: ()) {
        uiView.resetTracking(notifyCancel: false)
    }

    final class TouchView: UIView {
        private let exclusiveRecognizer = ComposerTextView.ExclusiveTouchHoldRecognizer(target: nil, action: nil)
        private var config: VoicePrimaryTouchSurface?
        private weak var activeTouch: UITouch?
        private var holdTimer: DispatchWorkItem?
        private var startWindowPoint: CGPoint = .zero
        private var latestWindowPoint: CGPoint = .zero
        private var isTrackingTouch = false
        private var didEngageHold = false
        private var cancelledTap = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = [.button]
            addGestureRecognizer(exclusiveRecognizer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func configure(with surface: VoicePrimaryTouchSurface) {
            self.config = surface
            accessibilityLabel = surface.a11yLabel
            accessibilityIdentifier = surface.a11yIdentifier
        }

        override func accessibilityActivate() -> Bool {
            config?.onTap()
            return true
        }

        private var currentWindowSize: CGSize {
            if let window {
                return window.bounds.size
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let keyWindow = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
                ?? scenes.first?.windows.first {
                return keyWindow.bounds.size
            }
            return CGSize(width: 393, height: 852)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            holdTimer?.cancel()
            activeTouch = touch
            isTrackingTouch = true
            didEngageHold = false
            cancelledTap = false
            let pt = touch.location(in: window)
            startWindowPoint = pt
            latestWindowPoint = pt

            guard config?.holdEnabled == true else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.engageHoldNow()
            }
            holdTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch), isTrackingTouch else { return }
            let pt = activeTouch.location(in: window)
            latestWindowPoint = pt
            if didEngageHold {
                exclusiveRecognizer.moveHold()
                config?.onHoldChanged(pt, currentWindowSize)
                return
            }
            let dx = pt.x - startWindowPoint.x
            let dy = pt.y - startWindowPoint.y
            if config?.holdEnabled == true && (dy < -14 || dx < -14) {
                engageHoldNow()
            } else if hypot(dx, dy) > 22 {
                holdTimer?.cancel()
                holdTimer = nil
                cancelledTap = true
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch), isTrackingTouch else { return }
            holdTimer?.cancel()
            holdTimer = nil
            let wasHolding = didEngageHold
            let wasCancelled = cancelledTap
            self.activeTouch = nil
            isTrackingTouch = false
            didEngageHold = false
            cancelledTap = false

            if wasHolding {
                exclusiveRecognizer.endHold()
                config?.onHoldEnded()
            } else {
                exclusiveRecognizer.cancelHold()
                if !wasCancelled {
                    config?.onTap()
                }
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            resetTracking(notifyCancel: true)
        }

        func resetTracking(notifyCancel: Bool) {
            holdTimer?.cancel()
            holdTimer = nil
            let wasHolding = didEngageHold
            activeTouch = nil
            isTrackingTouch = false
            didEngageHold = false
            cancelledTap = false
            exclusiveRecognizer.cancelHold()
            if wasHolding && notifyCancel {
                config?.onHoldCancelled()
            }
        }

        private func engageHoldNow() {
            guard isTrackingTouch, !didEngageHold, config?.holdEnabled == true else { return }
            holdTimer?.cancel()
            holdTimer = nil
            didEngageHold = true
            exclusiveRecognizer.engageHold()
            config?.onHoldBegan(latestWindowPoint, currentWindowSize)
        }
    }
}
#endif

// MARK: - Attachment chip

/// One tray chip: 36 pt thumb (image preview / MIME glyph, spinner while
/// uploading), filename + status line, ✕ to remove. A failed chip tints red
/// and taps to retry.
/// Tap inserts `/name ` for arguments. Short lists size to their rows;
/// longer ones scroll inside a bounded card.
private struct SlashCommandList: View {
    let commands: [SlashCommand]
    var selectedIndex: Int = 0
    let surface: Color
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if commands.count > 4 {
                    ScrollView {
                        rows
                    }
                    .frame(height: 220)
                } else {
                    rows
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard commands.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(commands[newIndex].name, anchor: .center)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(surface))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .accessibilityIdentifier("composer.slash-commands")
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.name) { index, command in
                let isSelected = index == selectedIndex
                if index > 0 {
                    Divider().padding(.leading, 12)
                }
                Button {
                    onSelect(command)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "/\(command.name)")
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                        if let description = command.description, !description.isEmpty {
                            Text(verbatim: description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(command.name)
                .accessibilityIdentifier("composer.slash.\(command.name)")
            }
        }
    }
}

/// The pending send time above the input, with × to send normally again.
private struct ScheduledSendChip: View {
    let schedule: PendingSchedule
    let onClear: () -> Void

    static func presetLabel(_ schedule: PendingSchedule) -> String {
        switch schedule {
        case .delay(let minutes) where minutes % 60 == 0:
            let hours = minutes / 60
            return hours == 1
                ? String(localized: "In 1 hour")
                : String(format: String(localized: "In %lld hours"), Int64(hours))
        case .delay(let minutes):
            return String(format: String(localized: "In %lld minutes"), Int64(minutes))
        case .at(let ms):
            return Date(timeIntervalSince1970: Double(ms) / 1000)
                .formatted(date: .abbreviated, time: .shortened)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(String(format: String(localized: "Scheduled · %@"), Self.presetLabel(schedule)))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Don't Schedule")
        }
        .font(.footnote)
        .foregroundStyle(.tint)
        .padding(.leading, 10)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.scheduled-send")
    }
}

/// Specific send time: now through the hub's 7-day limit.
private struct ScheduleTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSchedule: (Date) -> Void
    @State private var date = Date().addingTimeInterval(30 * 60)

    var body: some View {
        let now = Date()
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Send at",
                        selection: $date,
                        in: now...now.addingTimeInterval(TimeInterval(PendingSchedule.maxDays * 24 * 60 * 60)),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                } footer: {
                    Text("Max 7 days. Requires the hub running; the CLI catches up the next time it connects after that time.")
                }
            }
            .navigationTitle("Schedule send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct ComposerAttachmentChipView: View {
    let attachment: ComposerAttachmentUI
    let onRetry: () -> Void
    let onRemove: () -> Void
    @State private var showsUploadError = false

    private var failed: Bool { attachment.status == .failed }

    var body: some View {
        HStack(spacing: 8) {
            if failed {
                Button(action: onRetry) {
                    attachmentLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                attachmentLabel
            }
            if failed, attachment.errorMessage != nil {
                Button {
                    showsUploadError = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.red)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details")
                .accessibilityIdentifier("attachment.error.\(attachment.id)")
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(6)
        .background(
            failed ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.fill.tertiary),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .alert("Error", isPresented: $showsUploadError) {
            Button("Retry", action: onRetry)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "\(attachment.filename)\n\n\(attachment.errorMessage ?? "")")
        }
    }

    private var attachmentLabel: some View {
        HStack(spacing: 8) {
            thumb
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .accessibilityIdentifier("attachment.progress.\(attachment.id)")
                if attachment.status == .uploading, let progress = attachment.uploadProgress {
                    GeometryReader { geometry in
                        Capsule().fill(Color.secondary.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.tint)
                                    .frame(width: geometry.size.width * progress.fraction)
                            }
                    }
                        .frame(height: 3)
                        .padding(.top, 4)
                        .accessibilityLabel("Uploading…")
                        .accessibilityValue("\(progress.percent)%")
                }
            }
            .frame(maxWidth: 132, alignment: .leading)
        }
    }

    var statusLine: String {
        switch attachment.status {
        case .uploading:
            if let progress = attachment.uploadProgress {
                switch progress.phase {
                case .uploading: return "\(progress.percent)%"
                case .retrying: return "\(String(localized: "Retrying…")) · \(progress.percent)%"
                case .finishing: return String(localized: "Finishing…")
                }
            }
            return String(localized: "Uploading…")
        case .failed:
            return String(localized: "Failed — tap to retry")
        case .ready:
            return formatChipSize(attachment.sizeBytes)
        }
    }

    private var thumb: some View {
        ZStack {
            // Preparer-made ≤ 512 px JPEGs — cheap enough to decode inline.
            if let previewBytes = attachment.previewBytes,
               let image = UIImage(data: previewBytes) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipped()
                    .opacity(attachment.status == .uploading ? 0.4 : 1)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.fill.secondary)
                    .frame(width: 36, height: 36)
                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if attachment.status == .uploading && attachment.uploadProgress == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// `12.3 MB` / `456 KB` / `789 B` chip size label (Android `formatChipSize`).
func formatChipSize(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
    if bytes >= 1024 {
        return String(format: "%.0f KB", Double(bytes) / 1024.0)
    }
    return "\(bytes) B"
}

// MARK: - Recording chip

/// Elapsed-time recording chip with a cancel affordance (discards the take).
private struct RecordingChipView: View {
    let startedAtMs: Int
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 8) {
                Text("● Recording…  \(formatElapsed(elapsedSeconds(at: context.date)))")
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Button("Cancel") {
                    onCancel()
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.red)
        }
    }

    private func elapsedSeconds(at date: Date) -> Int {
        max(0, (Int(date.timeIntervalSince1970 * 1000) - startedAtMs) / 1000)
    }
}

/// `m:ss` elapsed-time label for the recording chip.
func formatElapsed(_ totalSeconds: Int) -> String {
    String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}

// MARK: - Video import

/// Photo-picker videos land as a temp file (`FileRepresentation`) so the
/// preparer's capped read — not a full in-memory `Data` — bounds them.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-\(UUID().uuidString.prefix(8)).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

#if !targetEnvironment(macCatalyst)
// MARK: - Instant Attachment Popup Card

/// Anchors an instant-response floating attachment card directly in the key
/// window above the composer card's bottom-leading corner, avoiding `UIMenu`
/// context-menu snapshot delays and leaving the software keyboard focused.
private struct ComposerAttachmentPopupHost: UIViewRepresentable {
    @Binding var isPresented: Bool
    let colorScheme: ColorScheme
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] window in
            if window == nil {
                coordinator?.dismissImmediate(resetBinding: true)
            }
        }
        return view
    }

    func updateUIView(_ anchorView: AnchorView, context: Context) {
        context.coordinator.update(
            isPresented: $isPresented,
            presented: isPresented,
            colorScheme: colorScheme,
            anchorView: anchorView,
            onCamera: onCamera,
            onPhotos: onPhotos,
            onFiles: onFiles
        )
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.dismissImmediate(resetBinding: false)
    }

    final class AnchorView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isPresentedBinding: Binding<Bool>
        private var overlay: PopupOverlayView?
        private var currentlyPresented = false
        private var onCamera: () -> Void = {}
        private var onPhotos: () -> Void = {}
        private var onFiles: () -> Void = {}

        init(isPresented: Binding<Bool>) {
            self.isPresentedBinding = isPresented
        }

        func update(
            isPresented: Binding<Bool>,
            presented: Bool,
            colorScheme: ColorScheme,
            anchorView: AnchorView,
            onCamera: @escaping () -> Void,
            onPhotos: @escaping () -> Void,
            onFiles: @escaping () -> Void
        ) {
            self.isPresentedBinding = isPresented
            self.onCamera = onCamera
            self.onPhotos = onPhotos
            self.onFiles = onFiles

            if presented {
                guard let window = anchorView.window else { return }
                if let overlay {
                    if overlay.superview !== window {
                        overlay.removeFromSuperview()
                        window.addSubview(overlay)
                    }
                    overlay.update(
                        anchorView: anchorView,
                        colorScheme: colorScheme,
                        onCamera: { [weak self] in self?.runAction { self?.onCamera() } },
                        onPhotos: { [weak self] in self?.runAction { self?.onPhotos() } },
                        onFiles: { [weak self] in self?.runAction { self?.onFiles() } },
                        onDismiss: { [weak self] in self?.dismissFromBackdrop() }
                    )
                    overlay.setNeedsLayout()
                    if !currentlyPresented {
                        currentlyPresented = true
                        overlay.animateIn()
                    }
                } else {
                    let overlay = PopupOverlayView(
                        frame: window.bounds,
                        anchorView: anchorView,
                        colorScheme: colorScheme,
                        onCamera: { [weak self] in self?.runAction { self?.onCamera() } },
                        onPhotos: { [weak self] in self?.runAction { self?.onPhotos() } },
                        onFiles: { [weak self] in self?.runAction { self?.onFiles() } },
                        onDismiss: { [weak self] in self?.dismissFromBackdrop() }
                    )
                    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    window.addSubview(overlay)
                    overlay.layoutIfNeeded()
                    self.overlay = overlay
                    self.currentlyPresented = true
                    overlay.animateIn()
                }
            } else if currentlyPresented || overlay != nil {
                currentlyPresented = false
                dismissAnimated()
            }
        }

        private func runAction(_ action: () -> Void) {
            dismissImmediate(resetBinding: true)
            action()
        }

        private func dismissFromBackdrop() {
            guard isPresentedBinding.wrappedValue else {
                dismissAnimated()
                return
            }
            isPresentedBinding.wrappedValue = false
        }

        private func dismissAnimated() {
            guard let overlay else { return }
            self.overlay = nil
            overlay.animateOut { [weak overlay] in
                overlay?.removeFromSuperview()
            }
        }

        func dismissImmediate(resetBinding: Bool) {
            currentlyPresented = false
            if let overlay {
                self.overlay = nil
                overlay.layer.removeAllAnimations()
                overlay.cardContainer.layer.removeAllAnimations()
                overlay.removeFromSuperview()
            }
            if resetBinding, isPresentedBinding.wrappedValue {
                isPresentedBinding.wrappedValue = false
            }
        }
    }

    @MainActor
    final class PopupOverlayView: UIView {
        private weak var anchorView: UIView?
        private var onDismiss: () -> Void
        private let backdropView = UIView()
        let cardContainer = UIView()
        private let cardHostingController: UIHostingController<ComposerAttachmentPopupCard>

        init(
            frame: CGRect,
            anchorView: UIView,
            colorScheme: ColorScheme,
            onCamera: @escaping () -> Void,
            onPhotos: @escaping () -> Void,
            onFiles: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.anchorView = anchorView
            self.onDismiss = onDismiss
            let card = ComposerAttachmentPopupCard(
                colorScheme: colorScheme,
                onCamera: onCamera,
                onPhotos: onPhotos,
                onFiles: onFiles
            )
            self.cardHostingController = UIHostingController(rootView: card)
            super.init(frame: frame)

            backgroundColor = .clear

            backdropView.frame = bounds
            backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backdropView.backgroundColor = .clear
            backdropView.accessibilityIdentifier = "chat.attachment-popup.backdrop"
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
            backdropView.addGestureRecognizer(tap)
            addSubview(backdropView)

            cardHostingController.safeAreaRegions = []
            cardHostingController.view.backgroundColor = .clear
            cardContainer.backgroundColor = .clear
            cardContainer.accessibilityIdentifier = "chat.attachment-popup"
            cardContainer.layer.shadowColor = UIColor.black.cgColor
            cardContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
            cardContainer.layer.shadowRadius = 20
            cardContainer.layer.shadowOpacity = colorScheme == .dark ? 0.34 : 0.12
            cardContainer.addSubview(cardHostingController.view)
            addSubview(cardContainer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func update(
            anchorView: UIView,
            colorScheme: ColorScheme,
            onCamera: @escaping () -> Void,
            onPhotos: @escaping () -> Void,
            onFiles: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.anchorView = anchorView
            self.onDismiss = onDismiss
            cardHostingController.rootView = ComposerAttachmentPopupCard(
                colorScheme: colorScheme,
                onCamera: onCamera,
                onPhotos: onPhotos,
                onFiles: onFiles
            )
            cardContainer.layer.shadowOpacity = colorScheme == .dark ? 0.34 : 0.12
            positionCard()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            backdropView.frame = bounds
            positionCard()
        }

        private func positionCard() {
            guard let anchorView, anchorView.window === self.window else { return }
            let composerFrame = anchorView.convert(anchorView.bounds, to: self)
            let maxCardWidth = max(180, bounds.width - 24)
            let cardWidth = min(232, maxCardWidth)
            let targetSize = cardHostingController.sizeThatFits(in: CGSize(width: cardWidth, height: 400))
            let cardSize = CGSize(width: cardWidth, height: ceil(targetSize.height))
            let minX = min(max(12, composerFrame.minX), max(12, bounds.width - cardSize.width - 12))
            let minY = max(safeAreaInsets.top + 8, composerFrame.maxY - cardSize.height)
            let targetCenter = CGPoint(x: minX + cardSize.width / 2, y: minY + cardSize.height / 2)
            if cardContainer.bounds.size != cardSize {
                cardContainer.bounds = CGRect(origin: .zero, size: cardSize)
                cardHostingController.view.frame = cardContainer.bounds
                cardContainer.layer.shadowPath = UIBezierPath(
                    roundedRect: cardContainer.bounds,
                    cornerRadius: 28
                ).cgPath
            }
            if cardContainer.center != targetCenter {
                cardContainer.center = targetCenter
            }
        }

        private func bottomLeadingScaleTransform(_ scale: CGFloat) -> CGAffineTransform {
            let size = cardContainer.bounds.size
            let dx = size.width * 0.36
            let dy = size.height * 0.42
            return CGAffineTransform(translationX: -dx, y: dy)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: dx, y: -dy)
        }

        func animateIn() {
            isUserInteractionEnabled = true
            positionCard()
            if UIAccessibility.isReduceMotionEnabled {
                cardContainer.transform = .identity
                cardContainer.alpha = 0
                UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.cardContainer.alpha = 1
                }
                return
            }
            cardContainer.alpha = 0
            cardContainer.transform = bottomLeadingScaleTransform(0.88)
            UIView.animate(
                withDuration: 0.15,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0.6,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.cardContainer.alpha = 1
                self.cardContainer.transform = .identity
            }
        }

        func animateOut(completion: @escaping () -> Void) {
            isUserInteractionEnabled = false
            UIView.animate(
                withDuration: 0.10,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                self.cardContainer.alpha = 0
                if !UIAccessibility.isReduceMotionEnabled {
                    self.cardContainer.transform = self.bottomLeadingScaleTransform(0.94)
                }
            } completion: { _ in
                completion()
            }
        }

        @objc private func handleBackdropTap() {
            onDismiss()
        }
    }
}

struct ComposerAttachmentPopupCard: View {
    let colorScheme: ColorScheme
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let specularRim = LinearGradient(
            colors: [
                Color.white.opacity(isDark ? 0.24 : 0.82),
                Color.white.opacity(isDark ? 0.06 : 0.26),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let content = VStack(alignment: .leading, spacing: 4) {
            popupRow(title: String(localized: "Camera"), systemImage: "camera", identifier: "chat.attachment-popup.camera", action: onCamera)
            popupRow(title: String(localized: "Photos"), systemImage: "photo", identifier: "chat.attachment-popup.photos", action: onPhotos)
            popupRow(title: String(localized: "Files"), systemImage: "paperclip", identifier: "chat.attachment-popup.files", action: onFiles)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .background(shape.fill(isDark ? Color(white: 0.16).opacity(0.76) : Color.white.opacity(0.78)))
                    .clipShape(shape)
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.strokeBorder(specularRim, lineWidth: 0.75))
            } else {
                content
                    .background {
                        shape.fill(.ultraThinMaterial)
                            .overlay(shape.fill(isDark ? Color(white: 0.15).opacity(0.70) : Color.white.opacity(0.78)))
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(specularRim, lineWidth: 0.75))
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private func popupRow(title: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.055))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 16.5, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                Text(verbatim: title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(AttachmentPopupRowButtonStyle(isDark: isDark))
        .accessibilityIdentifier(identifier)
    }
}

private struct AttachmentPopupRowButtonStyle: ButtonStyle {
    let isDark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed
                          ? (isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                          : Color.clear)
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
#endif
