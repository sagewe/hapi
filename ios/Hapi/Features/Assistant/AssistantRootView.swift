import HapiClient
import HapiProtocol
import SwiftUI

struct AssistantRootView: View {
    let session: HubSession
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: AssistantWorkbenchModel
    @State private var history: SessionListModel
    @State private var selectedID: String?
    @State private var drawerOpen = false
    @State private var drag: CGFloat = 0
    @State private var settingsOpen = false
    @State private var attachmentRequest = false
    @State private var focusRequest = false
    @State private var editing = false

    init(
        session: HubSession,
        initialScene: AssistantScene? = nil,
        historyOpen: Bool = false,
        initialDraft: AssistantWorkbenchModel? = nil
    ) {
        self.session = session
        let initial = initialDraft ?? AssistantWorkbenchModel(session: session)
        initial.scene = initialScene
        _draft = State(initialValue: initial)
        _drawerOpen = State(initialValue: historyOpen)
        _history = State(initialValue: SessionListModel(session: session))
    }

    private var needsAttention: Bool {
        history.rows.contains { $0.unread || $0.summary.thinking }
    }

    private var scenes: [AssistantScene] {
        (session.clientProfile?.quickActions ?? []).map { AssistantScene(action: $0) }
    }

    private var brandTitle: String {
        let configured = session.clientProfile?.appTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if AppBrand.isQiqiWork { return AppBrand.displayName }
        return (configured?.isEmpty == false ? configured : nil) ?? "琪琪工作"
    }

    var body: some View {
        @Bindable var app = app
        GeometryReader { geometry in
            let width = min(306, geometry.size.width * 0.82)
            let reveal = min(1, max(0, (drawerOpen ? width + min(0, drag) : max(0, drag)) / width))
            ZStack(alignment: .leading) {
                AssistantDesign.background.ignoresSafeArea()
                NavigationStack {
                    Group {
                        if let id = selectedID {
                            ChatView(
                                session: session,
                                sessionId: id,
                                onNavigateToSession: { selectedID = $0 },
                                onOpenParentSession: { selectedID = $0 },
                                onAssistantHistory: { withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { drawerOpen = true } },
                                onAssistantNew: newInvestigation
                            )
                            .id(id)
                        } else {
                            workbench
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                }
                if reveal > 0 {
                    Color.black.opacity(0.28 * reveal)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                drawerOpen = false
                                drag = 0
                            }
                        }
                        .accessibilityLabel("关闭历史调查")
                    AssistantHistoryDrawer(
                        brandTitle: brandTitle,
                        model: history,
                        selectedID: selectedID,
                        onNew: { newInvestigation(false) },
                        select: { id in
                            selectedID = id
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                drawerOpen = false
                                drag = 0
                            }
                        },
                        settings: {
                            drawerOpen = false
                            settingsOpen = true
                        }
                    )
                    .frame(width: width)
                    .background(AssistantDesign.background)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(AssistantDesign.border).frame(width: 0.5)
                    }
                    .offset(x: -width + width * reveal)
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.12), radius: 20, x: 6)
                    .accessibilityIdentifier("assistant.history-drawer")
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { value in
                        guard drawerOpen || value.startLocation.x < 24,
                              abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                        drag = value.translation.width
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else {
                            drag = 0
                            return
                        }
                        guard drawerOpen || value.startLocation.x < 24 else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            drawerOpen = drawerOpen
                                ? value.predictedEndTranslation.width > -width * 0.3
                                : value.predictedEndTranslation.width > width * 0.3
                            drag = 0
                        }
                    }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !app.pendingIncomingFiles.isEmpty {
                incomingFilesCard(files: app.pendingIncomingFiles)
            }
        }
        .environment(\.isAssistantMode, true)
        .tint(AssistantDesign.accent)
        .task { await history.refresh() }
        .onChange(of: session.sessionStore.sessions, initial: true) { _, sessions in
            PushCoordinator.shared.observeSessionsForLocalNotifications(
                sessions,
                openSessionId: selectedID,
                scenePhase: scenePhase
            )
        }
        .onChange(of: app.pendingOpenSessionId, initial: true) { _, id in
            if let id {
                selectedID = id
                drawerOpen = false
                app.pendingOpenSessionId = nil
            }
        }
        .onChange(of: session.sessionRemoval) { _, value in
            if value?.sessionId == selectedID { newInvestigation(false) }
        }
        .sheet(isPresented: $settingsOpen) { SettingsView(session: session).macSheetSizing() }
        .sheet(isPresented: $app.showAddHub) { PairingFlowView(context: .addHub).macSheetSizing() }
    }

    // MARK: - Workbench (MyDots `HomeStatusPanel` calm rhythm + thumb-zone grid)

    private var workbench: some View {
        VStack(spacing: 0) {
            workbenchHeader

            if !editing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(AssistantDesign.calmDateCaption) · \(brandTitle)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(AssistantDesign.inkMuted)
                    Text(AssistantDesign.greeting)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(AssistantDesign.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))

                Spacer(minLength: 28)

                if !scenes.isEmpty {
                    AssistantScenarioGrid(
                        scenes: scenes,
                        selectedScene: draft.scene,
                        select: handleSceneSelection
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .disabled(draft.sending || draft.allocatedSessionID != nil)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            } else {
                // Keyboard open: dismissable canvas + compact scenario pill bar so typing never faces a blank void.
                VStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissKeyboard)

                    if !scenes.isEmpty, draft.allocatedSessionID == nil {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(scenes) { scene in
                                    let active = draft.scene?.id == scene.id
                                    Button {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                            draft.scene = active ? nil : scene
                                        }
                                        if !active, scene.kind == 2 {
                                            attachmentRequest.toggle()
                                        }
                                    } label: {
                                        HStack(spacing: 5.5) {
                                            Image(systemName: scene.icon).font(.system(size: 11, weight: .semibold))
                                            Text(scene.title).font(.caption.weight(.medium))
                                        }
                                        .foregroundStyle(active ? .white : scene.color)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(active ? scene.color : AssistantDesign.surface, in: Capsule())
                                        .overlay(Capsule().strokeBorder(active ? .clear : AssistantDesign.border, lineWidth: 0.5))
                                    }
                                    .buttonStyle(AssistantPressStyle(scale: 0.96))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: editing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AssistantDesign.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AssistantDraftComposer(
                draft: draft,
                attachmentRequest: attachmentRequest,
                focusRequest: focusRequest,
                focusChanged: { isFocused in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        editing = isFocused
                    }
                }
            ) {
                Task {
                    let pending = draft
                    if let id = await pending.send() {
                        if selectedID == nil {
                            withAnimation(.easeInOut(duration: 0.22)) { selectedID = id }
                        }
                        if draft === pending { draft = AssistantWorkbenchModel(session: session) }
                        await history.refresh()
                    }
                }
            }
            .padding(.top, 6)
            .background(alignment: .bottom) {
                LinearGradient(
                    colors: [AssistantDesign.background.opacity(0), AssistantDesign.background],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("assistant.workbench")
    }

    private var workbenchHeader: some View {
        HStack(spacing: 8) {
            Button {
                dismissKeyboard()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { drawerOpen = true }
            } label: {
                AssistantMenuIcon()
                    .frame(width: 44, height: 44)
                    .assistantGlass(Circle())
                    .overlay(alignment: .topTrailing) {
                        if needsAttention {
                            Circle()
                                .fill(AssistantDesign.accent)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(AssistantDesign.background, lineWidth: 1.5))
                                .offset(x: -4, y: 5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("历史调查")

            Spacer(minLength: 8)

            // MyDots top-right Liquid Glass glance pill: shows active depth/mode and opens quick switch menu.
            Menu {
                if !draft.useCodex, !draft.presets.isEmpty {
                    Section("调查档位") {
                        ForEach(draft.presets) { preset in
                            Button {
                                draft.selectPreset(preset)
                            } label: {
                                Label(
                                    preset.label,
                                    systemImage: draft.preset?.id == preset.id ? "checkmark" : (preset.label == "快速" ? "bolt.fill" : "sparkle")
                                )
                            }
                        }
                    }
                }
                Section {
                    Button {
                        newInvestigation(!draft.useCodex)
                    } label: {
                        Label(
                            draft.useCodex ? "切回标准调查" : "用 Codex 交叉核验",
                            systemImage: draft.useCodex ? "checkmark.shield" : "arrow.triangle.branch"
                        )
                    }
                    if !draft.text.isEmpty || !draft.files.isEmpty || draft.scene != nil {
                        Button(role: .destructive) {
                            newInvestigation(draft.useCodex)
                        } label: {
                            Label("清空当前草稿", systemImage: "trash")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(draft.useCodex ? AssistantDesign.risk : AssistantDesign.accent)
                        .frame(width: 6.5, height: 6.5)
                    Text(draft.useCodex ? "交叉核验" : "\(draft.preset?.label ?? "深度")模式")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(AssistantDesign.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(AssistantDesign.inkMuted)
                }
                .padding(.horizontal, 13)
                .frame(height: 44)
                .assistantGlass(Capsule())
            }
            .accessibilityLabel("更多调查选项")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func incomingFilesCard(files: [PreparedAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AssistantIcon(symbol: "tray.and.arrow.down.fill", color: AssistantDesign.accent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("收到 \(files.count) 份资料")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssistantDesign.ink)
                    Text(files.map(\.filename).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(AssistantDesign.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { app.pendingIncomingFiles = [] } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssistantDesign.inkMuted)
                        .frame(width: 28, height: 28)
                        .background(AssistantDesign.surfaceMuted, in: Circle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button {
                    let incoming = app.pendingIncomingFiles
                    newInvestigation(false)
                    for file in incoming { draft.add(.ready(file)) }
                    app.pendingIncomingFiles = []
                } label: {
                    Text("新建尽调送审")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(AssistantDesign.accentGradient, in: Capsule())
                }
                .buttonStyle(AssistantPressStyle())
                if selectedID != nil {
                    Button {
                        NotificationCenter.default.post(name: .assistantImportFiles, object: app.pendingIncomingFiles)
                        app.pendingIncomingFiles = []
                    } label: {
                        Text("补传到当前案")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AssistantDesign.ink)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(AssistantDesign.surfaceMuted, in: Capsule())
                    }
                    .buttonStyle(AssistantPressStyle())
                }
            }
        }
        .padding(16)
        .background { AssistantComposerCardSurface(cornerRadius: 22) }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func handleSceneSelection(_ scene: AssistantScene) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            if draft.scene?.id == scene.id {
                draft.scene = nil
                return
            }
            draft.scene = scene
        }
        if scene.kind == 2 {
            attachmentRequest.toggle()
        } else {
            focusRequest.toggle()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func newInvestigation(_ codex: Bool) {
        guard !draft.sending else { return }
        selectedID = nil
        drawerOpen = false
        editing = false
        draft = AssistantWorkbenchModel(session: session, useCodex: codex)
    }
}

// MARK: - MyDots-style Bottom-Weighted History Drawer

struct AssistantHistoryDrawer: View {
    var brandTitle: String = "琪琪工作"
    @Bindable var model: SessionListModel
    var selectedID: String? = nil
    var onNew: () -> Void = {}
    let select: (String) -> Void
    let settings: () -> Void
    @State private var isSearching = false
    @State private var tag: String?
    @FocusState private var searchFocused: Bool

    private var filteredRows: [SessionRowUI] {
        model.rows.filter { tag == nil || $0.tags.contains(tag!) }
    }

    /// Bottom-weighted chronological order (oldest top -> newest bottom) so newest cases sit closest
    /// to the thumb; flips to top-down while searching so keyboard never covers results (MyDots pattern).
    private var displayedRows: [SessionRowUI] {
        isSearching ? filteredRows : Array(filteredRows.reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(brandTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AssistantDesign.ink)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isSearching.toggle()
                        if !isSearching {
                            model.searchQuery = ""
                            searchFocused = false
                        } else {
                            searchFocused = true
                        }
                    }
                } label: {
                    Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AssistantDesign.ink)
                        .frame(width: 42, height: 42)
                        .assistantGlass(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索调查")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)

            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(AssistantDesign.inkMuted)
                    TextField("搜索案件、主体或标签", text: $model.searchQuery)
                        .focused($searchFocused)
                        .font(.system(size: 15))
                        .foregroundStyle(AssistantDesign.ink)
                    if !model.searchQuery.isEmpty {
                        Button { model.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AssistantDesign.inkMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if !model.availableTags.isEmpty || model.showArchivedSessions {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            filterChip(title: "全部", active: tag == nil) { tag = nil }
                            ForEach(model.availableTags.sorted(), id: \.self) { value in
                                filterChip(title: value, active: tag == value) {
                                    tag = tag == value ? nil : value
                                }
                            }
                        }
                    }
                    Button {
                        withAnimation(.snappy) { model.setShowArchivedSessions(!model.showArchivedSessions) }
                    } label: {
                        Image(systemName: model.showArchivedSessions ? "archivebox.fill" : "archivebox")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.showArchivedSessions ? AssistantDesign.accent : AssistantDesign.inkMuted)
                            .frame(width: 30, height: 28)
                            .background(
                                model.showArchivedSessions ? AssistantDesign.accentSoft : AssistantDesign.surfaceMuted,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("显示已归档调查")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Rectangle()
                .fill(AssistantDesign.border)
                .frame(height: 0.5)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            GeometryReader { geo in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if displayedRows.isEmpty {
                            Text(model.searchQuery.isEmpty ? "还没有调查记录" : "未找到匹配案件")
                                .font(.system(size: 14))
                                .foregroundStyle(AssistantDesign.inkMuted)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                        }
                        ForEach(displayedRows) { row in
                            Button { select(row.id) } label: {
                                AssistantHistoryRow(row: row, isCurrent: row.id == selectedID)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: max(0, geo.size.height),
                        alignment: isSearching ? .top : .bottom
                    )
                }
                .defaultScrollAnchor(isSearching ? .top : .bottom)
                .id(isSearching)
                .refreshable { await model.refresh() }
            }
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(AssistantDesign.border)
                .frame(height: 0.5)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            // MyDots signature bottom thumb bar: bold solid-ink primary action pill + Liquid Glass Settings circle.
            HStack(spacing: 12) {
                Button(action: onNew) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                        Text("新调查")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(AssistantDesign.background)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(AssistantDesign.ink, in: Capsule())
                }
                .buttonStyle(AssistantPressStyle(scale: 0.96))
                .accessibilityLabel("新建调查")

                Spacer()

                Button(action: settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AssistantDesign.ink)
                        .frame(width: 48, height: 48)
                        .assistantGlass(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private func filterChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Text(title)
                .font(.caption.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? .white : AssistantDesign.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? AssistantDesign.accentSolidFill : AssistantDesign.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AssistantHistoryRow: View {
    let row: SessionRowUI
    var isCurrent: Bool = false

    private var risk: Bool {
        row.tags.contains { $0.contains("风险") || $0.contains("制裁") }
    }

    var body: some View {
        let status = AssistantHistoryPresentation.status(row.summary)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if row.unread {
                        Circle()
                            .fill(AssistantDesign.accent)
                            .frame(width: 6, height: 6)
                    }
                    Text(row.title)
                        .font(.system(size: 15.5, weight: isCurrent || row.unread ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? AssistantDesign.ink : AssistantDesign.inkSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let firstTag = row.tags.first {
                        Text(firstTag)
                            .foregroundStyle(risk ? AssistantDesign.risk : AssistantDesign.inkMuted)
                    }
                    if row.tags.count > 1, risk {
                        Text("· 高风险").foregroundStyle(AssistantDesign.risk)
                    }
                    Text(AssistantDesign.age(row.summary.updatedAt))
                        .foregroundStyle(AssistantDesign.inkMuted.opacity(0.85))
                }
                .font(.caption2)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if status == "调查中" {
                HStack(spacing: 4) {
                    AssistantHeaderOrbitingRing(color: AssistantDesign.accent, lineWidth: 1.4)
                        .frame(width: 9, height: 9)
                    Text("调查中")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(AssistantDesign.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(AssistantDesign.accentSoft, in: Capsule())
            } else if status == "待回复" {
                Text("待回复")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AssistantDesign.risk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(AssistantDesign.risk.opacity(0.14), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isCurrent ? AssistantDesign.surfaceMuted : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}
