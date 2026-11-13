import HapiClient
import HapiProtocol
import HapiUI
import SwiftUI

/// Tool groups contribute only their displayed summary to transcript diffs.
/// Wraps the large value payload in a reference box so copying `TranscriptRow`
/// across arrays/dictionaries is a single pointer retain (32 bytes instead of
/// 602 bytes) and equality on unchanged rows short-circuits via `===` in O(1).
struct TranscriptRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case history(ChatHistoryPagingState.Phase, Bool, Bool)
        case message(VisibleChatBlock, Bool)
        case group(ToolGroupPresentation)
    }

    final class Box: Equatable {
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }
        static func == (lhs: Box, rhs: Box) -> Bool {
            if lhs === rhs { return true }
            return lhs.kind == rhs.kind
        }
    }

    static let historyID = "chat-history-control"
    let id: String
    let role: TranscriptRowRole
    let box: Box

    var kind: Kind { box.kind }

    static func history(_ phase: ChatHistoryPagingState.Phase, _ hasMore: Bool, _ isDisabled: Bool) -> TranscriptRow {
        TranscriptRow(
            id: Self.historyID,
            role: .history,
            box: Box(.history(phase, hasMore, isDisabled))
        )
    }

    static func message(_ block: VisibleChatBlock, _ isHighlighted: Bool) -> TranscriptRow {
        let role: TranscriptRowRole = switch block {
        case .toolGroup: .tool
        case .block(.userText): .user
        case .block(.toolCall): .tool
        default: .content
        }
        return TranscriptRow(
            id: block.stableId,
            role: role,
            box: Box(.message(block, isHighlighted))
        )
    }

    static func group(_ group: ToolGroupPresentation) -> TranscriptRow {
        TranscriptRow(
            id: group.id,
            role: .tool,
            box: Box(.group(group))
        )
    }

    func spacing(after previous: TranscriptRow?) -> CGFloat {
        return role.spacing(after: previous?.role)
    }
}

struct ChatTranscriptView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: ChatModel
    var onOpenJumpSheet: (() -> Void)? = nil

    private var rows: [TranscriptRow] {
        let isHistoryDisabled = !model.hasMore || model.isLoadingOlder || model.isSyncingTail
        var result: [TranscriptRow] = [.history(model.historyPaging.phase, model.hasMore, isHistoryDisabled)]
        result.reserveCapacity(model.messageRows.count + 1)
        result.append(contentsOf: model.messageRows)
        return result
    }

    var body: some View {
        let basePath = model.basePath
        AnchoredTranscriptList(
            items: rows,
            historyVersion: model.historyVersion,
            jumpToken: model.jumpToLatestToken,
            scrollTarget: model.scrollTarget,
            geometryCache: model.geometryCache,
            contentRevision: basePath ?? "",
            historyControlID: TranscriptRow.historyID,
            isInspectionPresented: model.isInspectingContent,
            onViewport: { viewport in
                model.readingViewportChanged(
                    followsTail: viewport.followsTail, needsOlder: viewport.needsOlder,
                    isAwayFromBottom: viewport.isAwayFromBottom
                )
            },
            onTopVisibleItemChanged: { topID in
                model.topVisibleRowChanged(topID)
            },
            onLayout: { version, progress in model.historyLaidOut(version: version, madeProgress: progress) },
            onTailDisplayed: {
                if scenePhase == .active {
                    model.markDisplayed(revision: model.readThroughRevision, serverState: model.renderedReadState)
                }
            },
            spacingBefore: { previous, row in row.spacing(after: previous) }
        ) { row in
            // The list bridges the current environment into its hosting roots.
            AnyView(rowView(row, basePath: basePath))
        }
        .overlay(alignment: .trailing) {
            TurnJumpRailOverlay(model: model, onOpenJumpSheet: onOpenJumpSheet)
        }
        .overlay(alignment: .bottomTrailing) {
            JumpToLatestOverlay(model: model)
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow, basePath: String?) -> some View {
        switch row.kind {
        case .history(let phase, let hasMore, let isDisabled):
            Button(action: model.retryHistory) {
                HStack(spacing: 8) {
                    if !hasMore {
                        Text("Beginning of conversation")
                    } else {
                        switch phase {
                        case .loading, .retrying, .awaitingLayout:
                            ProgressView().controlSize(.small)
                            Text("Loading older messages…")
                        case .failed: Text("Couldn't load history. Tap to retry.")
                        case .paused: Text("Continue loading history")
                        default: Text("Load older messages")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityIdentifier("chat-history")
        case .message(let block, let isHighlighted):
            ChatBlockCard(block: block, basePath: basePath, isHighlighted: isHighlighted)
        case .group(let presentation):
            ToolGroupBlockView(presentation: presentation)
        }
    }
}

private struct TurnJumpRailOverlay: View {
    let model: ChatModel
    var onOpenJumpSheet: (() -> Void)? = nil

    var body: some View {
        if !model.railNavItems.isEmpty {
            TurnJumpRailView(model: model, onOpenJumpSheet: onOpenJumpSheet)
                #if targetEnvironment(macCatalyst)
                .padding(.trailing, 10)
                #else
                .padding(.trailing, 4)
                #endif
                .padding(.vertical, 48)
        }
    }
}

private struct JumpToLatestOverlay: View {
    let model: ChatModel

    var body: some View {
        if model.showsJumpToLatest {
            Button(action: model.jumpToLatest) {
                HStack(spacing: 6) {
                    if model.isJumpingToLatest { ProgressView().controlSize(.small) }
                    Text("Back to latest")
                    Image(systemName: "arrow.down")
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .disabled(model.isJumpingToLatest)
            .accessibilityIdentifier("chat-latest")
            .padding(12)
        }
    }
}

// MARK: - Mini Turn Navigation Rail

private struct TurnJumpRailView: View {
    let model: ChatModel
    var onOpenJumpSheet: (() -> Void)? = nil

    @State private var hoveredID: String?
    #if !targetEnvironment(macCatalyst)
    @State private var isScrubbing = false
    @State private var isRecentlyActive = false
    @State private var fadeTask: Task<Void, Never>?
    @State private var didTriggerOutlineDuringDrag = false
    #endif

    private func computeVisibleSlice(items: [ChatRailNavItem], activeIndex: Int) -> ArraySlice<ChatRailNavItem> {
        #if targetEnvironment(macCatalyst)
        let maxVisible = 64
        #else
        let maxVisible = 42
        #endif
        guard items.count > maxVisible else { return items[...] }
        let half = maxVisible / 2
        let start = max(0, min(activeIndex - half, items.count - maxVisible))
        let end = min(items.count, start + maxVisible)
        return items[start..<end]
    }

    private func tickRowHeight(for count: Int) -> CGFloat {
        switch count {
        case ...24: return 11
        case 25...36: return 9
        case 37...50: return 7.5
        default: return 6.5
        }
    }

    var body: some View {
        let allItems = model.railNavItems
        let activeIdx = model.activeRailIndex ?? max(0, allItems.count - 1)
        let activeID = allItems.indices.contains(activeIdx) ? allItems[activeIdx].id : nil
        let slice = Array(computeVisibleSlice(items: allItems, activeIndex: activeIdx))
        let rowHeight = tickRowHeight(for: slice.count)
        let hoveredSliceIndex = hoveredID.flatMap { id in slice.firstIndex(where: { $0.id == id }) }
        let hoveredItem = hoveredSliceIndex.map { slice[$0] }

        HStack(alignment: .center, spacing: 10) {
            if let item = hoveredItem {
                railHoverPreview(item)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
            }

            #if targetEnvironment(macCatalyst)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(slice.enumerated()), id: \.element.id) { idx, item in
                    let isActive = item.id == activeID
                    Button {
                        model.jumpToBlock(id: item.id)
                    } label: {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                                .fill(tickColor(index: idx, hoveredIndex: hoveredSliceIndex, isActive: isActive))
                                .frame(
                                    width: tickWidth(index: idx, hoveredIndex: hoveredSliceIndex, isActive: isActive),
                                    height: 2.5
                                )
                        }
                        .frame(width: 24, height: rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                    }
                }
            }
            .onHover { hovering in
                if !hovering {
                    withAnimation(.easeOut(duration: 0.12)) {
                        hoveredID = nil
                    }
                }
            }
            #else
            VStack(alignment: .trailing, spacing: 6) {
                if let onOpenJumpSheet, isScrubbing || isRecentlyActive || model.showsJumpToLatest {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onOpenJumpSheet()
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(slice.enumerated()), id: \.element.id) { idx, item in
                        let isActive = item.id == activeID
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                                .fill(tickColor(index: idx, hoveredIndex: hoveredSliceIndex, isActive: isActive))
                                .frame(
                                    width: tickWidth(index: idx, hoveredIndex: hoveredSliceIndex, isActive: isActive),
                                    height: 2.5
                                )
                        }
                        .frame(width: 24, height: rowHeight)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard !slice.isEmpty else { return }
                            if !didTriggerOutlineDuringDrag,
                               let onOpenJumpSheet,
                               value.translation.width < -38,
                               abs(value.translation.height) < 32 {
                                didTriggerOutlineDuringDrag = true
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.easeOut(duration: 0.12)) {
                                    hoveredID = nil
                                    isScrubbing = false
                                }
                                onOpenJumpSheet()
                                return
                            }
                            guard !didTriggerOutlineDuringDrag else { return }
                            fadeTask?.cancel()
                            if !isScrubbing {
                                isScrubbing = true
                                isRecentlyActive = true
                            }
                            let rawIndex = Int(floor(value.location.y / rowHeight))
                            let clampedIndex = max(0, min(slice.count - 1, rawIndex))
                            let targetID = slice[clampedIndex].id
                            if hoveredID != targetID {
                                UISelectionFeedbackGenerator().selectionChanged()
                                withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.82)) {
                                    hoveredID = targetID
                                }
                            }
                        }
                        .onEnded { value in
                            defer { didTriggerOutlineDuringDrag = false }
                            guard !didTriggerOutlineDuringDrag, !slice.isEmpty else { return }
                            let rawIndex = Int(floor(value.location.y / rowHeight))
                            let clampedIndex = max(0, min(slice.count - 1, rawIndex))
                            let targetID = hoveredID ?? slice[clampedIndex].id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.jumpToBlock(id: targetID)
                            withAnimation(.easeOut(duration: 0.15)) {
                                hoveredID = nil
                                isScrubbing = false
                            }
                            wakeRailBriefly()
                        }
                )
            }
            .opacity(isScrubbing || isRecentlyActive ? 1.0 : 0.52)
            .animation(.easeOut(duration: 0.2), value: isRecentlyActive)
            .onChange(of: activeIdx) { _, _ in
                wakeRailBriefly()
            }
            .onChange(of: model.showsJumpToLatest) { _, _ in
                wakeRailBriefly()
            }
            #endif
        }
    }

    #if !targetEnvironment(macCatalyst)
    private func wakeRailBriefly() {
        fadeTask?.cancel()
        isRecentlyActive = true
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_800))
            guard !Task.isCancelled, !isScrubbing else { return }
            isRecentlyActive = false
        }
    }
    #endif

    private func tickWidth(index: Int, hoveredIndex: Int?, isActive: Bool) -> CGFloat {
        guard let hoveredIndex else {
            #if targetEnvironment(macCatalyst)
            return 9
            #else
            if isRecentlyActive {
                return isActive ? 11 : 8
            }
            return isActive ? 9 : 6
            #endif
        }
        let distance = abs(index - hoveredIndex)
        switch distance {
        case 0: return 22
        case 1: return 15
        case 2: return 11
        default: return 8
        }
    }

    private func tickColor(index: Int, hoveredIndex: Int?, isActive: Bool) -> Color {
        if let hoveredIndex {
            if index == hoveredIndex {
                return Color.primary.opacity(0.78)
            }
            return Color.primary.opacity(0.20)
        }
        return isActive ? Color.primary.opacity(0.55) : Color.primary.opacity(0.20)
    }

    private func railHoverPreview(_ item: ChatRailNavItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .multilineTextAlignment(.leading)

            if let reply = item.subtitle, !reply.isEmpty {
                Text(reply)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        #if targetEnvironment(macCatalyst)
        .frame(width: 272, alignment: .leading)
        #else
        .frame(width: 224, alignment: .leading)
        #endif
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        .allowsHitTesting(false)
    }
}

// MARK: - ⌘J Message Jump Palette

struct MessageJumpSheet: View {
    enum FilterMode: String, CaseIterable, Identifiable {
        case userTurns
        case allMessages

        var id: String { rawValue }
        var label: String {
            switch self {
            case .userTurns: "User Turns"
            case .allMessages: "All Messages"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let model: ChatModel

    @State private var query = ""
    @State private var mode: FilterMode = .userTurns
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private var filteredTurns: [ChatTurnNavItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.userTurnItems
        guard !needle.isEmpty else { return base }
        return base.filter { turn in
            turn.userText.lowercased().contains(needle)
                || (turn.assistantPreview?.lowercased().contains(needle) ?? false)
                || "#\(turn.turnNumber)".contains(needle)
        }
    }

    private var filteredMessages: [ChatMessageNavItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.allMessageNavItems
        guard !needle.isEmpty else { return base }
        return base.filter { item in
            item.text.lowercased().contains(needle)
                || "#\(item.turnNumber)".contains(needle)
        }
    }

    private var currentIDs: [String] {
        switch mode {
        case .userTurns: filteredTurns.map(\.id)
        case .allMessages: filteredMessages.map(\.id)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                Divider()
                contentList
                Divider()
                footerBar
            }
            .navigationTitle("Jump to Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if model.hasMore {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.seekOlderUserTurn(jumpWhenFound: false, loadAll: true)
                        } label: {
                            if model.isLoadingOlder || model.isSeekingOlderTurn {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Load Older Turns", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        .disabled(model.isLoadingOlder || model.isSeekingOlderTurn)
                    }
                }
            }
            .onAppear {
                searchFocused = true
                if model.userTurnItems.isEmpty && !model.allMessageNavItems.isEmpty {
                    mode = .allMessages
                }
                syncInitialSelection()
            }
            .onChange(of: query) { _, _ in
                ensureValidSelection()
            }
            .onChange(of: mode) { _, _ in
                ensureValidSelection()
            }
            .onKeyPress(.upArrow) {
                moveSelection(delta: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(delta: 1)
                return .handled
            }
            .onKeyPress(.return) {
                commitSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
        }
    }

    private var headerBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search user prompts or assistant replies…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        commitSelection()
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(FilterMode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()

                Text("\(currentIDs.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var contentList: some View {
        if currentIDs.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Messages Yet" : "No Matching Messages",
                systemImage: "text.magnifyingglass",
                description: Text(query.isEmpty ? "Messages in this conversation will appear here." : "Try a different keyword or load older history.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    switch mode {
                    case .userTurns:
                        ForEach(filteredTurns) { turn in
                            turnRow(turn)
                                .tag(turn.id)
                                .id(turn.id)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    case .allMessages:
                        ForEach(filteredMessages) { item in
                            messageRow(item)
                                .tag(item.id)
                                .id(item.id)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    if let selectedID {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
                .onChange(of: selectedID) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func turnRow(_ turn: ChatTurnNavItem) -> some View {
        let isCurrentTurn: Bool = {
            guard let activeIdx = model.activeUserTurnIndex,
                  model.userTurnItems.indices.contains(activeIdx) else { return false }
            return model.userTurnItems[activeIdx].id == turn.id
        }()
        let isSelected = selectedID == turn.id

        return Button {
            selectedID = turn.id
            jumpAndDismiss(turn.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("#\(turn.turnNumber)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(isCurrentTurn ? .white : Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isCurrentTurn ? Color.accentColor : Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    if isCurrentTurn {
                        Text("Current View")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    if turn.toolCount > 0 {
                        Label("\(turn.toolCount) tools", systemImage: "wrench.and.screwdriver")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(Self.formatTimestamp(turn.createdAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(turn.userText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let preview = turn.assistantPreview, !preview.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func messageRow(_ item: ChatMessageNavItem) -> some View {
        let isUser = item.role == .user
        let isSelected = selectedID == item.id

        return Button {
            selectedID = item.id
            jumpAndDismiss(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(
                        isUser ? "User #\(item.turnNumber)" : "Assistant #\(item.turnNumber)",
                        systemImage: isUser ? "person.fill" : "sparkles"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isUser ? Color.accentColor : .secondary)

                    Spacer()

                    Text(Self.formatTimestamp(item.createdAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(item.text)
                    .font(isUser ? .subheadline.weight(.medium) : .caption)
                    .foregroundStyle(isUser ? .primary : .secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footerBar: some View {
        HStack(spacing: 14) {
            Label("↑↓ Select", systemImage: "arrow.up.arrow.down")
            Label("↩ Jump", systemImage: "return")
            Label("⌥↑ / ⌥↓ Quick Step", systemImage: "command")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func syncInitialSelection() {
        if let activeIdx = model.activeUserTurnIndex,
           model.userTurnItems.indices.contains(activeIdx) {
            selectedID = model.userTurnItems[activeIdx].id
        } else {
            selectedID = currentIDs.last
        }
    }

    private func ensureValidSelection() {
        let ids = currentIDs
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.last
    }

    private func moveSelection(delta: Int) {
        let ids = currentIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedID, let idx = ids.firstIndex(of: current) else {
            selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        let next = max(0, min(ids.count - 1, idx + delta))
        selectedID = ids[next]
    }

    private func commitSelection() {
        guard let target = selectedID ?? currentIDs.first else { return }
        jumpAndDismiss(target)
    }

    private func jumpAndDismiss(_ id: String) {
        dismiss()
        model.jumpToBlock(id: id)
    }

    private static func formatTimestamp(_ rawTimestamp: Int) -> String {
        guard rawTimestamp > 0 else { return "" }
        let seconds = rawTimestamp > 10_000_000_000 ? Double(rawTimestamp) / 1000.0 : Double(rawTimestamp)
        let date = Date(timeIntervalSince1970: seconds)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
