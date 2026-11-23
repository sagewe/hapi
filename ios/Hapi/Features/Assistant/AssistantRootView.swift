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
    init(session: HubSession, initialScene: AssistantScene? = nil, historyOpen: Bool = false) {
        self.session = session
        let initial = AssistantWorkbenchModel(session: session)
        initial.scene = initialScene
        _draft = State(initialValue: initial)
        _drawerOpen = State(initialValue: historyOpen)
        _history = State(initialValue: SessionListModel(session: session))
    }
    private var needsAttention: Bool { history.rows.contains { $0.unread || $0.summary.thinking } }
    var body: some View {
        @Bindable var app = app
        GeometryReader { geometry in
            let width = min(340, geometry.size.width * 0.86)
            let reveal = min(1, max(0, (drawerOpen ? width + min(0, drag) : max(0, drag)) / width))
            ZStack(alignment: .leading) {
                AssistantDesign.background.ignoresSafeArea()
                NavigationStack {
                    Group {
                        if let id = selectedID {
                            ChatView(session: session, sessionId: id,
                                onNavigateToSession: { selectedID = $0 }, onOpenParentSession: { selectedID = $0 },
                                onAssistantHistory: { withAnimation(.snappy) { drawerOpen = true } },
                                onAssistantNew: newInvestigation).id(id)
                        } else { workbench }
                    }.toolbar(.hidden, for: .navigationBar)
                }
                if reveal > 0 {
                    Color.black.opacity(0.28 * reveal).ignoresSafeArea()
                        .onTapGesture { withAnimation(.snappy) { drawerOpen = false; drag = 0 } }
                        .accessibilityLabel("关闭历史调查")
                    AssistantHistoryDrawer(model: history, select: { id in
                        selectedID = id; withAnimation(.snappy) { drawerOpen = false; drag = 0 }
                    }, settings: { drawerOpen = false; settingsOpen = true })
                    .frame(width: width).background(AssistantDesign.background)
                    .offset(x: -width + width * reveal)
                    .compositingGroup().shadow(color: .black.opacity(0.08), radius: 18, x: 6)
                    .accessibilityIdentifier("assistant.history-drawer")
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    guard (drawerOpen || value.startLocation.x < 24), abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                    drag = value.translation.width
                }.onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { drag = 0; return }
                    guard drawerOpen || value.startLocation.x < 24 else { return }
                    withAnimation(.snappy(duration: 0.26)) {
                        drawerOpen = drawerOpen ? value.predictedEndTranslation.width > -width * 0.3 : value.predictedEndTranslation.width > width * 0.3
                        drag = 0
                    }
                })
        }
        .environment(\.isAssistantMode, true)
        .task { await history.refresh() }
        .onChange(of: session.sessionStore.sessions, initial: true) { _, sessions in
            PushCoordinator.shared.observeSessionsForLocalNotifications(sessions, openSessionId: selectedID, scenePhase: scenePhase)
        }
        .onChange(of: app.pendingOpenSessionId, initial: true) { _, id in
            if let id { selectedID = id; drawerOpen = false; app.pendingOpenSessionId = nil }
        }
        .onChange(of: session.sessionRemoval) { _, value in
            if value?.sessionId == selectedID { newInvestigation(false) }
        }
        .sheet(isPresented: $settingsOpen) { SettingsView(session: session).macSheetSizing() }
        .sheet(isPresented: $app.showAddHub) { PairingFlowView(context: .addHub).macSheetSizing() }
    }
    private var workbench: some View {
        VStack(spacing: 0) {
            HStack {
                Button { withAnimation(.snappy) { drawerOpen = true } } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44).assistantSurface(radius: 22)
                        .overlay(alignment: .topTrailing) { if needsAttention { Circle().fill(.blue).frame(width: 6, height: 6).offset(x: -1, y: 2) } }
                }.accessibilityLabel("历史调查")
                Spacer()
                if draft.useCodex { Text("交叉核验").font(.caption).foregroundStyle(.secondary) }
                Menu {
                    Button(draft.useCodex ? "标准调查" : "用 Codex 交叉核验") { newInvestigation(!draft.useCodex) }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel("更多调查选项")
            }.padding(.horizontal, 20).padding(.top, 10)
            if !editing {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 12) {
                Text("合规调查助手").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("需要核查哪笔交易？").font(.title3).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
            Spacer(minLength: 24)
            AssistantScenarioGrid(scenes: (session.clientProfile?.quickActions ?? []).map { AssistantScene(action: $0) }) { scene in
                draft.scene = scene
                if scene.kind == 2 { attachmentRequest.toggle() } else { focusRequest.toggle() }
            }.padding(.horizontal, 20).padding(.bottom, 20).disabled(draft.sending || draft.allocatedSessionID != nil)
            } else {
                Color.clear.contentShape(Rectangle()).onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AssistantDesign.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AssistantDraftComposer(draft: draft, attachmentRequest: attachmentRequest, focusRequest: focusRequest, focusChanged: { editing = $0 }) {
                Task {
                    let pending = draft
                    if let id = await pending.send() {
                        if selectedID == nil { withAnimation(.easeInOut(duration: 0.2)) { selectedID = id } }
                        if draft === pending { draft = AssistantWorkbenchModel(session: session) }
                        await history.refresh()
                    }
                }
            }
        }
        .accessibilityIdentifier("assistant.workbench")
    }
    private func newInvestigation(_ codex: Bool) {
        guard !draft.sending else { return }
        selectedID = nil; drawerOpen = false; editing = false
        draft = AssistantWorkbenchModel(session: session, useCodex: codex)
    }
}

struct AssistantHistoryDrawer: View {
    @Bindable var model: SessionListModel
    let select: (String) -> Void
    let settings: () -> Void
    @State private var tag: String?
    private var rows: [SessionRowUI] { model.rows.filter { tag == nil || $0.tags.contains(tag!) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("调查记录").font(.title2.weight(.semibold)).padding(.top, 16)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索调查", text: $model.searchQuery) }
                .padding(12).assistantSurface(radius: 12)
            HStack {
                Menu {
                    Button("全部标签") { tag = nil }
                    ForEach(model.availableTags.sorted(), id: \.self) { value in Button(value) { tag = value } }
                } label: { Label(tag ?? "标签", systemImage: "line.3.horizontal.decrease") }
                Spacer()
                Button { model.setShowArchivedSessions(!model.showArchivedSessions) } label: {
                    Image(systemName: model.showArchivedSessions ? "archivebox.fill" : "archivebox")
                }.accessibilityLabel("显示已归档调查")
            }.font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        Button { select(row.id) } label: { AssistantHistoryRow(row: row) }.buttonStyle(.plain)
                    }
                    if rows.isEmpty { Text("还没有调查记录").font(.subheadline).foregroundStyle(.secondary).padding(.top, 36) }
                }
            }.refreshable { await model.refresh() }
            Button(action: settings) { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                .foregroundStyle(.secondary).padding(.bottom, 8)
        }.padding(.horizontal, 18)
    }
}
struct AssistantHistoryRow: View {
    let row: SessionRowUI
    private var risk: Bool { row.tags.contains { $0.contains("风险") || $0.contains("制裁") } }
    private var symbol: String { risk ? "shield.lefthalf.filled" : row.tags.contains(where: { $0.contains("单据") }) ? "doc.text.magnifyingglass" : row.tags.contains(where: { $0.contains("自然人") }) ? "person.text.rectangle" : "building.2" }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantIcon(symbol: symbol, color: risk ? .orange : .blue, size: 32)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.subheadline.weight(row.unread ? .semibold : .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if row.unread { Circle().fill(.blue).frame(width: 5, height: 5) }
                }
                if !row.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(row.tags.prefix(2)), id: \.self) { value in
                            Text(value).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .foregroundStyle(value.contains("风险") || value.contains("制裁") ? Color.orange : Color.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background((value.contains("风险") || value.contains("制裁") ? Color.orange : .secondary).opacity(0.09), in: Capsule())
                        }
                    }.foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if AssistantHistoryPresentation.status(row.summary) == "待回复" {
                        Text("待回复").foregroundStyle(.orange)
                    } else if AssistantHistoryPresentation.status(row.summary) == "调查中" {
                        Circle().fill(.teal).frame(width: 4, height: 4)
                        Text("调查中").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(AssistantDesign.age(row.summary.updatedAt)).foregroundStyle(.tertiary)
                }.font(.caption2)
            }
        }.padding(12).assistantSurface().foregroundStyle(.primary)
    }
}
