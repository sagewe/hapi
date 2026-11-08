import HapiClient
import HapiProtocol
import HapiUI
import SwiftUI

/// The session list (A-M2a) — standalone screen: navigation and hub chrome
/// stay outside; taps surface through `onOpenSession`.
///
/// Inventory (mirrors the web sidebar semantics via the Android port):
/// - an active-filter summary, pull-to-refresh, empty/loading states;
///   home owns the filter menu and connection notice;
/// - pinned section first (the sort already puts globalPinned/pinned rows on
///   top; a header makes the boundary visible);
/// - per row: a two-line-tall flavor icon whose presence badge marks
///   connected sessions (pulsing while running); title with trailing
///   relative `updatedAt` (unread: semibold title + accent time, no dot so
///   the badge stays the only dot); a quiet second line has project left and an attention symbol right. No preview, task progress,
///   machine/path details or spinners. Disconnected rows are not dimmed;
/// - swipe actions: leading pin/mark-read, trailing archive or delete/reopen;
/// - long-press context menu → rename, pin (none/project/global), then
///   archive for active sessions or reopen/delete for inactive ones (web
///   `SessionActionMenu`), with confirmed archive refresh; failures land in
///   an alert.
struct SessionListView: View {
    @Environment(\.hapiTheme) private var theme
    let model: SessionListModel
    var selectedSessionId: String? = nil
    var selection: Binding<String?>? = nil
    let onOpenSession: (String) -> Void

    @State private var renameTarget: SessionRowUI?
    @State private var deleteTarget: SessionRowUI?
    /// Rows kept while a pushed chat covers the list (see `sessionList`).
    @State private var frozenRows: [SessionRowUI]?

    var body: some View {
        // Rows own their minute-tick age labels; the list itself only
        // changes with the data.
        Group {
            sessionList
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.hasArchivedSearchMatches {
                Button("Include Archived Sessions in Search") { model.setShowArchivedSessions(true) }
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("home.search-archived")
            }
            if let summary = model.filterSummary {
                SessionFilterSummary(summary: summary, onClear: model.clearFilters)
            }
        }
        .onChange(of: model.machineFilterIds, initial: true) { _, _ in
            model.reconcileFilters()
        }
        .task {
            // Explicit fetch on entry: the snapshot may be stale and a
            // `resume: ok` handshake deliberately skips the REST resync.
            if selection != nil {
                await model.refreshOnFirstAppearance()
            } else {
                await model.refresh()
            }
        }
        .refreshable {
            await model.refresh()
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { presented in
                    if !presented {
                        model.actionError = nil
                    }
                }
            )
        ) {
            Button("OK") {
                model.actionError = nil
            }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(item: $renameTarget) { row in
            SessionTitleEditor(row: row, availableTags: model.availableTags) { name, locked, tags in
                try await model.saveTitle(row, name: name, locked: locked, tags: tags)
            }
            .macSheetSizing()
        }
        .alert(
            "Delete Session",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { row in
            Button("Delete", role: .destructive) {
                model.deleteSession(sessionId: row.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(SessionNameRules.deleteMessage(title: row.title))
        }
    }

    // MARK: - List

    /// Covered by a pushed chat, the list keeps its last rows: on a large
    /// hub every streaming session would otherwise rebuild and diff
    /// thousands of rows nobody sees (~80 ms main-thread stalls while
    /// scrolling the chat). A side-by-side split never disappears and
    /// stays live; returning refreshes once.
    private var sessionList: some View {
        let rows = frozenRows ?? model.rows
        let effectiveSelectedId = selectedSessionId ?? selection?.wrappedValue ?? model.selectedSessionId
        return KeyedContent(key: ListRenderKey(rows: rows, selectedSessionId: effectiveSelectedId,
                                               selectable: selection != nil,
                                               theme: theme, filters: model.filters,
                                               groupByTag: model.groupByTag,
                                               collapsedTagGroups: model.collapsedTagGroups)) {
            list(rows, selectedSessionId: effectiveSelectedId)
        }
        .equatable()
        .onAppear { frozenRows = nil }
        .onDisappear { frozenRows = model.rows }
    }

    private func list(_ rows: [SessionRowUI], selectedSessionId: String?) -> some View {
        let pinnedCount = SessionListModel.pinnedCount(of: rows)
        let listSelection: Binding<String?>? = model.groupByTag ? nil : selection
        return ScrollViewReader { proxy in
            List(selection: listSelection) {
                if model.groupByTag {
                    let groups = SessionListModel.tagGroups(of: rows)
                    ForEach(groups) { group in
                        let isCollapsed = model.isTagGroupCollapsed(group.id)
                        Section {
                            if !isCollapsed {
                                ForEach(group.rows) { row in
                                    groupedEquatableRow(row, groupId: group.id, isSelected: selectedSessionId == row.id)
                                }
                            }
                        } header: {
                            tagGroupHeader(group, isCollapsed: isCollapsed)
                        }
                        .listSectionSeparator(.hidden, edges: .top)
                    }
                } else {
                    if pinnedCount > 0 {
                        Section {
                            ForEach(rows.prefix(pinnedCount)) { row in
                                equatableRow(row, isSelected: selectedSessionId == row.id)
                            }
                        } header: {
                            sectionHeader("Pinned")
                        }
                        .listSectionSeparator(.hidden, edges: .top)
                    }
                    if rows.count > pinnedCount {
                        // Headerless when nothing is pinned: an empty-string Section
                        // header still reserves a blank sticky band above the list
                        // (device feedback: "一片空白").
                        if pinnedCount > 0 {
                            Section {
                                ForEach(rows.dropFirst(pinnedCount)) { row in
                                    equatableRow(row, isSelected: selectedSessionId == row.id)
                                }
                            } header: {
                                // Not "Sessions": the navigation title already says so.
                                sectionHeader("Recent")
                            }
                            .listSectionSeparator(.hidden, edges: .top)
                        } else {
                            // Top edge hidden: a plain list otherwise draws a stray
                            // separator above the very first row (device feedback).
                            Section {
                                ForEach(rows) { row in
                                    equatableRow(row, isSelected: selectedSessionId == row.id)
                                }
                            }
                            .listSectionSeparator(.hidden, edges: .top)
                        }
                    }
                }
            }
            .onChange(of: selectedSessionId) { _, newId in
                guard let newId, rows.contains(where: { $0.id == newId }) else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if model.groupByTag {
                        let groups = SessionListModel.tagGroups(of: rows)
                        if let firstGroup = groups.first(where: { group in
                            !model.isTagGroupCollapsed(group.id) && group.rows.contains(where: { $0.id == newId })
                        }) {
                            proxy.scrollTo("\(firstGroup.id)::\(newId)")
                        }
                    } else {
                        proxy.scrollTo(newId)
                    }
                }
            }
        }
        .modifier(PlatformSessionListStyle())
        // The default plain header height leaves a blank band between
        // Pinned and Recent; headers size to their compact text instead.
        .environment(\.defaultMinListHeaderHeight, 0)
        // An explicit filter change starts at the top. SSE/count/name changes
        // keep this identity (and the reading position), as does chat return.
        .id(model.filters)
        .accessibilityIdentifier("home.sessions")
        .overlay {
            if rows.isEmpty {
                emptyState
                    .allowsHitTesting(false) // keep the pull-to-refresh gesture
            }
        }
    }

    /// The List evaluates every row's content (offscreen ones included) on
    /// each list change, so one streaming session cost O(all rows) per
    /// update. Rows compare only what they draw and skip unchanged content.
    private func equatableRow(_ row: SessionRowUI, isSelected: Bool) -> some View {
        KeyedContent(key: RowRenderKey(row: row, isSelected: isSelected, selectable: selection != nil, theme: theme)) {
            rowCell(row, isSelected: isSelected, useSelectionLink: selection != nil)
        }
        .equatable()
        .tag(row.id)
        .id(row.id)
    }

    private func groupedEquatableRow(_ row: SessionRowUI, groupId: String, isSelected: Bool) -> some View {
        let compositeId = "\(groupId)::\(row.id)"
        return KeyedContent(key: RowRenderKey(row: row, isSelected: isSelected, selectable: false, theme: theme)) {
            rowCell(row, isSelected: isSelected, useSelectionLink: false)
        }
        .equatable()
        .id(compositeId)
    }

    private func rowCell(_ row: SessionRowUI, isSelected: Bool, useSelectionLink: Bool) -> some View {
        Group {
            if useSelectionLink {
                #if targetEnvironment(macCatalyst)
                Button {
                    onOpenSession(row.id)
                } label: {
                    rowLabel(row, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .tag(row.id)
                #else
                NavigationLink(value: row.id) {
                    rowLabel(row, isSelected: isSelected)
                }
                .tag(row.id)
                #endif
            } else {
                Button {
                    onOpenSession(row.id)
                } label: {
                    rowLabel(row, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.2))
                : nil
        )
        .listRowInsets(EdgeInsets(top: Self.rowVerticalInset, leading: 16, bottom: Self.rowVerticalInset, trailing: 16))
        // Default separator color reads heavy against these rows; the theme
        // divider is the WeChat-style faint hairline.
        .listRowSeparatorTint(theme.divider)
        .swipeActions(edge: .leading) {
            leadingSwipeActions(row)
        }
        .swipeActions(edge: .trailing) {
            trailingSwipeActions(row)
        }
        .contextMenu {
            contextMenuActions(row)
        }
    }

    /// Pointer rows on a Mac sidebar are denser than touch rows.
    private static var rowVerticalInset: CGFloat {
        #if targetEnvironment(macCatalyst)
        6
        #else
        12
        #endif
    }

    /// Compact header (Mail-style) instead of the large plain-list default.
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func tagGroupHeader(_ group: SessionTagGroup, isCollapsed: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                model.toggleTagGroupCollapsed(group.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                    .frame(width: 12)
                switch group.kind {
                case .pinned:
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Pinned")
                case .tag(let label):
                    Image(systemName: "tag.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Text(verbatim: label)
                case .untagged:
                    Image(systemName: "tray")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text("Untagged")
                }
                Spacer(minLength: 4)
                Text(verbatim: "\(group.rows.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.textSecondary.opacity(0.12), in: Capsule())
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .textCase(nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 16))
    }

    /// Leading swipe: the quick toggles (pin, read), as in Mail.
    @ViewBuilder
    private func leadingSwipeActions(_ row: SessionRowUI) -> some View {
        let isPinned = row.summary.pinned == true || row.summary.globalPinned == true
        Button {
            model.setPinMode(sessionId: row.id, mode: isPinned ? .none : .project)
        } label: {
            Label(isPinned ? "Unpin" : "Pin to Project",
                  systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.orange)
        if row.unread {
            Button {
                model.markRead(sessionId: row.id)
            } label: {
                Label("Mark as Read", systemImage: "envelope.open.fill")
            }
            .tint(theme.accent)
        }
    }

    /// Trailing swipe mirrors the context menu's lifecycle actions: the hub
    /// archives live sessions only; inactive ones are deleted or reopened.
    @ViewBuilder
    private func trailingSwipeActions(_ row: SessionRowUI) -> some View {
        if row.summary.active {
            Button {
                model.archiveSession(sessionId: row.id)
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(.indigo)
        } else {
            // Not role: .destructive — that removes the row before the
            // confirmation alert has a chance to cancel.
            Button {
                deleteTarget = row
            } label: {
                Label("Delete…", systemImage: "trash.fill")
            }
            .tint(.red)
            Button {
                model.reopenSession(sessionId: row.id) { sessionId in
                    onOpenSession(sessionId)
                }
            } label: {
                Label("Reopen", systemImage: "arrow.clockwise")
            }
            .tint(.gray)
        }
    }

    private func rowLabel(_ row: SessionRowUI, isSelected: Bool = false) -> some View {
        SessionRowView(row: row, isSelected: isSelected)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func contextMenuActions(_ row: SessionRowUI) -> some View {
        let summary = row.summary
        Button { model.markUnread(summary) } label: {
            Label("Mark as Unread", systemImage: "circle.badge")
        }
        Button {
            renameTarget = row
        } label: {
            Label("Rename & Tags…", systemImage: "pencil")
        }
        Menu {
            Button {
                renameTarget = row
            } label: {
                Label("Edit Tags…", systemImage: "plus.circle")
            }
            let allTags = model.availableTags
            if !allTags.isEmpty {
                Divider()
                ForEach(allTags, id: \.self) { tag in
                    let hasTag = row.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                    Button {
                        model.toggleTag(row, tag: tag)
                    } label: {
                        Label(
                            "#\(tag)",
                            systemImage: hasTag ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
            if !row.tags.isEmpty {
                Divider()
                Button(role: .destructive) {
                    model.setTags(row, tags: [])
                } label: {
                    Label("Clear Tags", systemImage: "xmark.circle")
                }
            }
            Divider()
            Button {
                model.setGroupByTag(!model.groupByTag)
            } label: {
                Label(
                    model.groupByTag ? "Disable Group by Tag" : "Group Sidebar by Tag",
                    systemImage: "rectangle.3.group"
                )
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
        if summary.pinned == true || summary.globalPinned == true {
            Button {
                model.setPinMode(sessionId: row.id, mode: .none)
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
        }
        if summary.pinned != true {
            Button {
                model.setPinMode(sessionId: row.id, mode: .project)
            } label: {
                Label("Pin to Project", systemImage: "pin")
            }
        }
        if summary.globalPinned != true {
            Button {
                model.setPinMode(sessionId: row.id, mode: .global)
            } label: {
                Label("Pin Globally", systemImage: "pin.circle")
            }
        }
        // The hub archives live sessions only (409 for an inactive one);
        // inactive history is reopened or deleted instead.
        if summary.active {
            Button(role: .destructive) {
                model.archiveSession(sessionId: row.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        } else {
            Button {
                model.reopenSession(sessionId: row.id) { sessionId in
                    onOpenSession(sessionId)
                }
            } label: {
                Label("Reopen", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                deleteTarget = row
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasLoaded && !model.isOffline {
            ContentUnavailableView {
                Label("Loading sessions…", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Fetching the session list from the hub.")
            }
        } else if model.isOffline {
            ContentUnavailableView {
                Label("Hub unreachable", systemImage: "wifi.slash")
            } description: {
                Text("Pull to retry once you are back online.")
            }
        } else if model.isSearching {
            ContentUnavailableView.search(text: model.searchQuery)
        } else if model.hasActiveFilters {
            ContentUnavailableView {
                Label("No matching sessions", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Clear the filters to see every session.")
            }
        } else if model.hasHiddenArchivedSessions {
            ContentUnavailableView {
                Label("Archived Sessions Are Hidden", systemImage: "archivebox")
            } actions: {
                Button("Show Archived Sessions") { model.setShowArchivedSessions(true) }
            }
        } else {
            ContentUnavailableView {
                Label("No sessions yet", systemImage: "tray")
            } description: {
                Text("Start an agent with the hapi CLI and it will appear here.")
            }
        }
    }
}

// MARK: - Row

/// Re-renders `content` only when `key` changes. List and row content
/// capture only stable references (the model, state setters, the open
/// callback), so an equal key can keep the previous content.
private struct KeyedContent<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

private struct RowRenderKey: Equatable {
    let row: SessionRowUI
    let isSelected: Bool
    let selectable: Bool
    let theme: HapiTheme
}

private struct ListRenderKey: Equatable {
    let rows: [SessionRowUI]
    let selectedSessionId: String?
    let selectable: Bool
    let theme: HapiTheme
    let filters: SessionListFilters
    let groupByTag: Bool
    let collapsedTagGroups: Set<String>
}

struct SessionRowView: View {
    @Environment(\.hapiTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30
    @ScaledMetric(relativeTo: .footnote) private var statusSlotSize: CGFloat = 16

    let row: SessionRowUI
    var isSelected = false

    private let iconSpacing: CGFloat = 12

    var body: some View {
        HStack(alignment: .center, spacing: iconSpacing) {
            agentIcon
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                detailLine
            }
        }
        #if targetEnvironment(macCatalyst)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.22))
                : RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.clear)
        )
        #endif
        // Separators start under the text column, as in Mail and Messages.
        .alignmentGuide(.listRowSeparatorLeading) { _ in iconSize + iconSpacing }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.unread ? Text("Unread") : Text(verbatim: ""))
        .accessibilityIdentifier("home.session.\(row.id)")
    }

    /// The agent owns the leading column; a presence badge marks connected
    /// sessions (pulsing while the agent works) instead of dimming the rest.
    private var agentIcon: some View {
        AgentFlavorIconView(flavor: row.flavor, size: iconSize * 0.8)
            .frame(width: iconSize, height: iconSize)
            .overlay(alignment: .bottomTrailing) {
                if row.summary.active {
                    presenceBadge
                }
            }
    }

    private var presenceBadge: some View {
        let isRunning = row.status == .running
        return Image(systemName: "circle.fill")
            .font(.system(size: iconSize * 0.3))
            .foregroundStyle(theme.success)
            .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
            .padding(2)
            .background(Circle().fill(theme.background))
            .offset(x: 2, y: 2)
            .accessibilityLabel(isRunning ? Text("Running") : Text("Connected"))
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(verbatim: row.title)
                .font(.body)
                .fontWeight(row.unread ? .semibold : .regular)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            // Unread is a semibold title plus an accent timestamp, not a
            // dot: the presence badge is the row's only dot.
            // Minute ticks redraw only this label, not the list.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(verbatim: formatRelativeAge(now: context.date, thenEpochMs: row.summary.updatedAt))
            }
            .font(.footnote)
            .fontWeight(row.unread ? .semibold : .regular)
            .foregroundStyle(row.unread ? theme.accent : theme.textSecondary)
            .monospacedDigit()
            .fixedSize()
        }
    }

    /// Project + tags left; only states that need the user (reply/approval) get a
    /// trailing symbol. Routine activity lives on the icon badge.
    private var detailLine: some View {
        HStack(alignment: .center, spacing: 6) {
            // Keep the same text line height when metadata is missing,
            // so the row height does not jump.
            Text(verbatim: row.project ?? " ")
                .lineLimit(1)
                .accessibilityHidden(row.project == nil)
            if !row.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(row.tags.prefix(3)), id: \.self) { tag in
                        Text(verbatim: "#\(tag)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.accent.opacity(0.12), in: Capsule())
                            .lineLimit(1)
                    }
                    if row.tags.count > 3 {
                        Text(verbatim: "+\(row.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if let status = row.status, let symbol = status.symbolName {
                Image(systemName: symbol)
                    .symbolVariant(.none)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(attentionColor)
                    // One slot keeps every attention symbol aligned.
                    .frame(width: statusSlotSize, height: statusSlotSize)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityLabel(statusAccessibilityText(status))
            }
        }
        .font(.footnote)
        .foregroundStyle(theme.textSecondary)
    }

    // Darker amber keeps thin strokes visible on white without a filled
    // symbol, background badge or animation competing with the session title.
    private var attentionColor: Color {
        theme.isDark ? theme.warning : Color(hex: 0x9A6700)
    }

    /// Keep the exact request count available to VoiceOver without adding
    /// another visible number or badge to every waiting conversation.
    private func statusAccessibilityText(_ status: SessionRowStatus) -> Text {
        let title = Text(LocalizedStringKey(status.titleKey))
        if let count = status.count, count > 1 {
            return Text("\(title) · \(count) requests")
        }
        return title
    }
}

// MARK: - Rename / delete copy (shared by the list and the chat menu)

enum SessionNameRules {
    /// Hub `PATCH /sessions/:id` accepts 1–255 characters.
    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= 255
    }

    static func deleteMessage(title: String) -> String {
        String(format: String(localized: "Delete “%@”? This can't be undone."), title)
    }
}

// MARK: - Recent-directory chip (used by NewSessionView)

struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected
                        ? AnyShapeStyle(.tint.opacity(0.18))
                        : AnyShapeStyle(Color.secondary.opacity(0.12)),
                    in: Capsule()
                )
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SessionTitleEditor: View {
    let row: SessionRowUI
    let availableTags: [String]
    let save: (String?, Bool, [String]?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var locked: Bool
    @State private var tags: [String]
    @State private var newTagInput = ""
    @State private var originalName: String
    @State private var originalLock: Bool
    @State private var originalTags: [String]
    @State private var busy = false
    @State private var error: String?

    init(
        row: SessionRowUI,
        availableTags: [String] = [],
        save: @escaping (String?, Bool, [String]?) async throws -> Void
    ) {
        self.row = row
        self.availableTags = availableTags
        self.save = save
        let initialTags = SessionListStore.normalizeTags(row.tags)
        _originalName = State(initialValue: row.title)
        _originalLock = State(initialValue: row.summary.metadata?.titleLocked == true)
        _originalTags = State(initialValue: initialTags)
        _name = State(initialValue: row.title)
        _locked = State(initialValue: row.summary.metadata?.titleLocked == true)
        _tags = State(initialValue: initialTags)
    }

    init(row: SessionRowUI, save: @escaping (String?, Bool) async throws -> Void) {
        self.init(row: row, availableTags: []) { name, locked, _ in
            try await save(name, locked)
        }
    }

    private var suggestedTags: [String] {
        availableTags.filter { candidate in
            !tags.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
    }

    private func addTags(from raw: String) {
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : $0 }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        tags = SessionListStore.normalizeTags(tags + parts)
    }

    private func commitPendingTagInput() {
        guard !newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addTags(from: newTagInput)
        newTagInput = ""
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Session name", text: $name)
                    Toggle("Lock Title", isOn: $locked)
                }
                Section {
                    if !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    Button {
                                        removeTag(tag)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(verbatim: "#\(tag)")
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                        }
                                        .font(.footnote.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Add tag (comma or Return)", text: $newTagInput)
                            .onSubmit {
                                commitPendingTagInput()
                            }
                            .onChange(of: newTagInput) { _, updated in
                                if updated.contains(",") || updated.contains("，") {
                                    commitPendingTagInput()
                                }
                            }
                        Button {
                            commitPendingTagInput()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !suggestedTags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Existing Tags")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(suggestedTags, id: \.self) { suggestion in
                                        Button {
                                            addTags(from: suggestion)
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "plus")
                                                    .font(.caption2.weight(.bold))
                                                Text(verbatim: "#\(suggestion)")
                                                    .font(.footnote)
                                            }
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                            .foregroundStyle(.primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } header: {
                    Text("Tags")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("Session Info & Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        commitPendingTagInput()
                        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedTags = SessionListStore.normalizeTags(tags)
                        let tagsChanged = normalizedTags != originalTags
                        if value == originalName && locked == originalLock && !tagsChanged {
                            dismiss()
                            return
                        }
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await save(
                                    value == originalName ? nil : value,
                                    locked,
                                    tagsChanged ? normalizedTags : nil
                                )
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }.disabled(busy || !SessionNameRules.isValid(name))
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }
}

/// Mac windows get the native sidebar list (vibrant background, rounded
/// accent selection, hover); touch layouts keep the plain list.
private struct PlatformSessionListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.listStyle(.sidebar)
        #else
        content.listStyle(.plain)
        #endif
    }
}
