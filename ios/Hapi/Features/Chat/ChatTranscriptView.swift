import HapiClient
import HapiProtocol
import HapiUI
import SwiftUI

/// Tool groups contribute only their displayed summary to transcript diffs.
enum TranscriptRow: Identifiable, Equatable {
    case history(ChatHistoryPagingState.Phase, Bool)
    case message(VisibleChatBlock)
    case group(ToolGroupPresentation)

    static let historyID = "chat-history-control"
    var role: TranscriptRowRole {
        switch self {
        case .history: .history
        case .group: .tool
        case .message(.toolGroup): .tool
        case .message(.block(.userText)): .user
        case .message(.block(.toolCall)): .tool
        default: .content
        }
    }
    var id: String {
        switch self {
        case .history: Self.historyID
        case .message(let block): block.stableId
        case .group(let group): group.id
        }
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
        var rows: [TranscriptRow] = [.history(model.historyPaging.phase, model.hasMore)]
        for block in model.blocks {
            if case .toolGroup(let group) = block {
                rows.append(.group(ToolGroupPresentation(group)))
            } else {
                rows.append(.message(block))
            }
        }
        return rows
    }

    var body: some View {
        let revision = model.readThroughRevision
        let readState = model.renderedReadState
        AnchoredTranscriptList(
            items: rows,
            historyVersion: model.historyVersion,
            jumpToken: model.jumpToLatestToken,
            scrollTarget: model.scrollTarget,
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
                if scenePhase == .active { model.markDisplayed(revision: revision, serverState: readState) }
            },
            spacingBefore: { previous, row in row.spacing(after: previous) }
        ) { row in
            // The list bridges the current environment into its hosting roots.
            AnyView(rowView(row))
        }
        .overlay(alignment: .trailing) {
            if !model.railNavItems.isEmpty {
                TurnJumpRailView(model: model)
                    .padding(.trailing, 10)
                    .padding(.vertical, 48)
            }
        }
        .overlay(alignment: .bottomTrailing) {
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
                    .background(.regularMaterial, in: Capsule())
                }
                .disabled(model.isJumpingToLatest)
                .accessibilityIdentifier("chat-latest")
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow) -> some View {
        let isHighlighted = model.highlightedBlockID == row.id
        switch row {
        case .history(let phase, let hasMore):
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
            .disabled(!hasMore || model.isLoadingOlder || model.isSyncingTail)
            .accessibilityIdentifier("chat-history")
        case .message(let block):
            ChatBlockCard(block: block, basePath: model.basePath, isHighlighted: isHighlighted)
        case .group(let presentation):
            ToolGroupBlockView(presentation: presentation)
        }
    }
}

// MARK: - Mini Turn Navigation Rail

private struct TurnJumpRailView: View {
    let model: ChatModel

    @State private var hoveredID: String?

    private var items: [ChatRailNavItem] {
        if !model.userTurnItems.isEmpty {
            return model.userTurnItems.map { turn in
                ChatRailNavItem(
                    id: turn.id,
                    isUserTurn: true,
                    turnNumber: turn.turnNumber,
                    title: turn.userText,
                    subtitle: turn.assistantPreview,
                    toolCount: turn.toolCount,
                    createdAt: turn.createdAt
                )
            }
        }
        return model.railNavItems
    }

    private var activeIndex: Int {
        if !model.userTurnItems.isEmpty {
            return model.activeUserTurnIndex ?? max(0, items.count - 1)
        }
        return model.activeRailIndex ?? max(0, items.count - 1)
    }

    private var visibleSlice: ArraySlice<ChatRailNavItem> {
        let maxVisible = 18
        guard items.count > maxVisible else { return items[...] }
        let half = maxVisible / 2
        let start = max(0, min(activeIndex - half, items.count - maxVisible))
        let end = min(items.count, start + maxVisible)
        return items[start..<end]
    }

    var body: some View {
        let slice = Array(visibleSlice)
        let hoveredSliceIndex = hoveredID.flatMap { id in slice.firstIndex(where: { $0.id == id }) }
        let hoveredItem = hoveredSliceIndex.map { slice[$0] }

        HStack(alignment: .center, spacing: 10) {
            if let item = hoveredItem {
                railHoverPreview(item)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
            }

            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(slice.enumerated()), id: \.element.id) { idx, item in
                    let isActive = items.indices.contains(activeIndex) && items[activeIndex].id == item.id
                    Button {
                        model.jumpToBlock(id: item.id)
                    } label: {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                                .fill(tickColor(index: idx, hoveredIndex: hoveredSliceIndex, isActive: isActive))
                                .frame(
                                    width: tickWidth(index: idx, hoveredIndex: hoveredSliceIndex),
                                    height: 2.5
                                )
                        }
                        .frame(width: 24, height: 11)
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
        }
    }

    private func tickWidth(index: Int, hoveredIndex: Int?) -> CGFloat {
        guard let hoveredIndex else { return 9 }
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
        .frame(width: 272, alignment: .leading)
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
                            model.seekOlderUserTurn(jumpWhenFound: false)
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
                            in: Capsule()
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
