import HapiClient
import HapiUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct CaseFileAction: Identifiable {
    let id = UUID()
    let files: [GeneratedMediaFile]
    var images = false
    var export = false
}

struct ZIPRoute: Identifiable {
    let id = UUID()
    let file: GeneratedMediaFile
    let archive: SafeZIP
}

struct CaseGalleryItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let file: GeneratedMediaFile
}

struct CaseGalleryRoute: Identifiable {
    let id = UUID()
    let items: [CaseGalleryItem]
    let startIndex: Int
}

struct CaseFilesView: View {
    @Bindable var model: CaseFilesModel
    let title: String
    var isDrawer: Bool = false
    var onQuoteFile: ((String) -> Void)? = nil
    var onAddFiles: (() -> Void)? = nil
    var onPromoteToScenario: (() -> Void)? = nil

    @State private var filter = 0
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var versionsExpanded = false
    @State private var action: CaseFileAction?
    @State private var preview: CaseFileAction?
    @State private var gallery: CaseGalleryRoute?

    init(
        model: CaseFilesModel,
        title: String,
        initialSelection: Set<String> = [],
        isDrawer: Bool = false,
        onQuoteFile: ((String) -> Void)? = nil,
        onAddFiles: (() -> Void)? = nil,
        onPromoteToScenario: (() -> Void)? = nil
    ) {
        self.model = model
        self.title = title
        self.isDrawer = isDrawer
        self.onQuoteFile = onQuoteFile
        self.onAddFiles = onAddFiles
        self.onPromoteToScenario = onPromoteToScenario
        _selected = State(initialValue: initialSelection)
        _selecting = State(initialValue: !initialSelection.isEmpty)
    }

    private var deliverablesCount: Int { model.files.filter { !$0.isUpload }.count }
    private var uploadsCount: Int { model.files.filter(\.isUpload).count }
    private var shown: [CaseFile] { model.files.filter { filter == 0 || (filter == 2) == $0.isUpload } }
    private var picked: [CaseFile] { model.files.filter { selected.contains($0.selectionID) } }
    private var allShownSelected: Bool { !shown.isEmpty && shown.allSatisfy { selected.contains($0.selectionID) } }

    private var showsHeroCard: Bool {
        !selecting && filter != 2 && model.report != nil
    }

    private var heroExcludedIDs: Set<String> {
        guard showsHeroCard else { return [] }
        var ids = Set<String>()
        if let report = model.report { ids.insert(report.selectionID) }
        for old in model.previousReports { ids.insert(old.selectionID) }
        return ids
    }

    var body: some View {
        ZStack {
            if let zip = model.activeZip {
                ZIPContentsView(
                    route: zip,
                    title: title,
                    isDrawer: isDrawer,
                    onQuoteFile: onQuoteFile,
                    back: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            model.activeZip = nil
                        }
                    }
                )
                .transition(.move(edge: .trailing))
            } else {
                inventory
                    .transition(.move(edge: .leading))
            }
        }
        .background(AssistantDesign.background)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: model.activeZip != nil)
        .presentationDetents([.fraction(0.88), .large])
        .presentationDragIndicator(isDrawer ? .hidden : .visible)
        .task(id: model.sessionId) { await model.refresh() }
        .sheet(item: $action) { value in CaseFilesActivity(files: value.files, images: value.images, export: value.export) }
        .sheet(item: $preview) { value in CaseFilesPreview(file: value.files[0]) }
        .fullScreenCover(item: $gallery) { route in
            CaseGalleryView(route: route)
        }
    }

    private var inventory: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.top, isDrawer ? 12 : 24)
                .padding(.bottom, 10)

            HStack(spacing: 6) {
                filterPill(title: "全部", count: model.files.count, tag: 0)
                filterPill(title: "交付", count: deliverablesCount, tag: 1)
                filterPill(title: "原件", count: uploadsCount, tag: 2)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            Rectangle()
                .fill(AssistantDesign.border)
                .frame(height: 0.5)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    if shown.isEmpty {
                        ContentUnavailableView(
                            "暂无资料",
                            systemImage: "folder",
                            description: Text("报告、核验图和送审原件会集中在这里")
                        )
                        .padding(.top, 36)
                    }

                    if showsHeroCard, let report = model.report {
                        HeroReportCard(
                            model: model,
                            report: report,
                            previousReports: model.previousReports,
                            versionsExpanded: $versionsExpanded,
                            open: { open($0) },
                            share: { share([$0]) },
                            export: { exportFiles([$0]) },
                            quote: onQuoteFile,
                            enterSelect: { enterMultiSelect(selecting: $0.selectionID) }
                        )
                    }

                    ForEach([false, true], id: \.self) { upload in
                        let rawGroup = shown.filter { $0.isUpload == upload }
                        let group = upload ? rawGroup : rawGroup.filter { !heroExcludedIDs.contains($0.selectionID) }
                        if !group.isEmpty {
                            Text(upload ? "送审原件" : "交付与核验")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssistantDesign.inkMuted)
                                .padding(.top, 4)
                                .padding(.leading, 4)

                            let docs = group.filter { !$0.isImage }.sorted {
                                if $0.selectionID == model.report?.selectionID { return true }
                                if $1.selectionID == model.report?.selectionID { return false }
                                return $0.createdAt > $1.createdAt
                            }
                            if !docs.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(Array(docs.enumerated()), id: \.element.selectionID) { index, file in
                                        if index > 0 {
                                            Rectangle()
                                                .fill(AssistantDesign.border)
                                                .frame(height: 0.5)
                                                .padding(.leading, selecting ? 80 : 54)
                                        }
                                        CaseFileRow(
                                            name: file.fileName,
                                            detail: fileDetailLine(file),
                                            isPrimaryReport: file.selectionID == model.report?.selectionID,
                                            selecting: selecting,
                                            selected: selected.contains(file.selectionID),
                                            isContainer: file.isZIP,
                                            select: { toggle(file.selectionID) },
                                            open: {
                                                if selecting { toggle(file.selectionID) }
                                                else { open(file) }
                                            }
                                        )
                                        .contextMenu {
                                            fileContextMenu(for: file)
                                        }
                                    }
                                }
                                .background(AssistantDesign.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
                                )
                            }

                            let images = group.filter(\.isImage)
                            if !images.isEmpty {
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 5),
                                        GridItem(.flexible(), spacing: 5),
                                        GridItem(.flexible(), spacing: 5),
                                    ],
                                    spacing: 5
                                ) {
                                    ForEach(Array(images.enumerated()), id: \.element.selectionID) { idx, file in
                                        CaseImageTile(
                                            model: model,
                                            file: file,
                                            selecting: selecting,
                                            selected: selected.contains(file.selectionID),
                                            select: { toggle(file.selectionID) },
                                            open: {
                                                if selecting { toggle(file.selectionID) }
                                                else { openImageGallery(images: images, startIndex: idx, groupTitle: upload ? "送审原件" : "交付核验图") }
                                            }
                                        )
                                        .contextMenu {
                                            fileContextMenu(for: file)
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }

                    if !selecting, let onPromoteToScenario, !model.files.isEmpty {
                        Button(action: onPromoteToScenario) {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(AssistantDesign.accentGradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text("将本案查证方法存为场景")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AssistantDesign.ink)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AssistantDesign.accent)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .assistantSurface(radius: 14)
                        }
                        .buttonStyle(AssistantPressStyle(scale: 0.98))
                        .padding(.top, 6)
                    }
                }
                .padding(.bottom, 16)
            }
            .refreshable { await model.refresh() }

            if let error = model.error {
                HStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(AssistantDesign.report)
                    Spacer()
                    Button("重试") { Task { await model.refresh() } }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssistantDesign.accent)
                }
                .padding(.vertical, 6)
            }

            if model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(AssistantDesign.accent)
                    Text("正在准备资料…").font(.caption).foregroundStyle(AssistantDesign.inkMuted)
                }
                .padding(.vertical, 6)
            }

            bottomDock
        }
        .padding(.horizontal, 14)
        .accessibilityIdentifier("assistant.case-files")
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            if selecting {
                Text(picked.isEmpty ? "选择资料" : "已选 \(picked.count) 项")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AssistantDesign.ink)
                Spacer(minLength: 6)
                if !shown.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if allShownSelected {
                                for file in shown { selected.remove(file.selectionID) }
                            } else {
                                for file in shown { selected.insert(file.selectionID) }
                            }
                        }
                    } label: {
                        Text(allShownSelected ? "取消全选" : "全选")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AssistantDesign.surfaceMuted, in: Capsule())
                    }
                    .buttonStyle(AssistantPressStyle(scale: 0.95))
                }
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selecting = false
                        selected.removeAll()
                    }
                } label: {
                    Text("完成")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssistantDesign.inkOnSolid)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AssistantDesign.ink, in: Capsule())
                }
                .buttonStyle(AssistantPressStyle(scale: 0.95))
            } else {
                HStack(spacing: 7) {
                    Text(isDrawer ? "本案卷宗" : "本案资料")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AssistantDesign.ink)
                    if !model.files.isEmpty {
                        Text("\(model.files.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(AssistantDesign.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(AssistantDesign.surfaceMuted, in: Capsule())
                    }
                }
                Spacer(minLength: 8)
                if !model.files.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            selecting = true
                        }
                    } label: {
                        Text("选择")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(AssistantDesign.surfaceMuted, in: Capsule())
                    }
                    .buttonStyle(AssistantPressStyle(scale: 0.95))
                }
            }
        }
    }

    private var bottomDock: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AssistantDesign.border)
                .frame(height: 0.5)
            HStack(spacing: 8) {
                if selecting {
                    compactActionButton("存文件", icon: "arrow.down.to.line") {
                        exportFiles(picked)
                    }
                    .disabled(picked.isEmpty || model.busy)

                    let allImages = !picked.isEmpty && picked.allSatisfy(\.isImage)
                    let shareLabel: String = {
                        if picked.isEmpty { return "选择后转发" }
                        if picked.count == 1 { return "转发已选 (1)" }
                        return allImages ? "转发图片 (\(picked.count))" : "打包转发 (\(picked.count))"
                    }()
                    primaryActionButton(shareLabel, icon: "square.and.arrow.up", accent: true) {
                        share(picked)
                    }
                    .disabled(picked.isEmpty || model.busy)
                } else {
                    if let report = model.report {
                        primaryActionButton("转发主报告", icon: "square.and.arrow.up", accent: false) {
                            share([report])
                        }
                        .disabled(model.busy)
                    } else if let archive = model.files.first(where: \.isZIP) {
                        primaryActionButton("整包转发 ZIP", icon: "archivebox", accent: false) {
                            share([archive])
                        }
                        .disabled(model.busy)
                    } else if let first = model.files.first {
                        primaryActionButton("转发资料", icon: "square.and.arrow.up", accent: false) {
                            share([first])
                        }
                        .disabled(model.busy)
                    } else {
                        Spacer(minLength: 0)
                    }

                    if let onAddFiles {
                        Button(action: onAddFiles) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(AssistantDesign.ink)
                                .frame(width: 44, height: 44)
                                .assistantGlass(Circle())
                        }
                        .buttonStyle(AssistantPressStyle(scale: 0.94))
                        .accessibilityLabel("补传资料到本案")
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(AssistantDesign.background)
    }

    @ViewBuilder
    private func fileContextMenu(for file: CaseFile) -> some View {
        if let onQuoteFile {
            Button {
                onQuoteFile(file.fileName)
            } label: {
                Label("引用回对话追问", systemImage: "bubble.left")
            }
        }
        Button {
            open(file)
        } label: {
            Label(file.isZIP ? "浏览卷内" : "预览", systemImage: file.isZIP ? "archivebox" : "eye")
        }
        Button {
            share([file])
        } label: {
            Label(file.isImage ? "转发此图" : "转发", systemImage: "square.and.arrow.up")
        }
        Button {
            exportFiles([file])
        } label: {
            Label("存文件", systemImage: "arrow.down.to.line")
        }
        if !selecting {
            Divider()
            Button {
                enterMultiSelect(selecting: file.selectionID)
            } label: {
                Label("进入多选", systemImage: "checkmark.circle")
            }
        }
    }

    private func enterMultiSelect(selecting id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            selecting = true
            selected.insert(id)
        }
    }

    private func filterPill(title: String, count: Int, tag: Int) -> some View {
        let active = filter == tag
        return Button {
            withAnimation(.snappy(duration: 0.2)) { filter = tag }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)").monospacedDigit().opacity(active ? 0.85 : 0.65)
                }
            }
            .font(.caption.weight(active ? .semibold : .medium))
            .foregroundStyle(active ? AssistantDesign.inkOnSolid : AssistantDesign.inkSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(active ? AssistantDesign.ink : AssistantDesign.subtleFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fileDetailLine(_ file: CaseFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        guard file.createdAt > 0 else { return size }
        let ts = file.createdAt > 10_000_000_000 ? Int(file.createdAt) : Int(file.createdAt * 1000)
        return "\(size) · \(AssistantDesign.age(ts))"
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.18)) {
            if !selected.insert(id).inserted { selected.remove(id) }
        }
    }

    private func open(_ file: CaseFile) {
        run {
            let local = try await model.local(file)
            if file.isZIP {
                let archive = try await Task.detached { try SafeZIP(data: Data(contentsOf: local.url)) }.value
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    model.activeZip = ZIPRoute(file: local, archive: archive)
                }
            } else if file.isImage {
                let group = shown.filter { $0.isUpload == file.isUpload && $0.isImage }
                let idx = group.firstIndex(where: { $0.selectionID == file.selectionID }) ?? 0
                let items = try await loadGalleryItems(group: group, groupTitle: file.isUpload ? "送审原件" : "交付核验图")
                gallery = CaseGalleryRoute(items: items, startIndex: min(idx, max(0, items.count - 1)))
            } else {
                preview = CaseFileAction(files: [local])
            }
        }
    }

    private func openImageGallery(images: [CaseFile], startIndex: Int, groupTitle: String) {
        run {
            let items = try await loadGalleryItems(group: images, groupTitle: groupTitle)
            guard !items.isEmpty else { return }
            gallery = CaseGalleryRoute(items: items, startIndex: min(startIndex, items.count - 1))
        }
    }

    private func loadGalleryItems(group: [CaseFile], groupTitle: String) async throws -> [CaseGalleryItem] {
        var out: [CaseGalleryItem] = []
        for file in group {
            let local = try await model.local(file)
            out.append(CaseGalleryItem(id: file.selectionID, title: file.fileName, subtitle: groupTitle, file: local))
        }
        return out
    }

    private func share(_ files: [CaseFile]) {
        guard !files.isEmpty else { return }
        run { action = CaseFileAction(files: try await model.sharing(files, title: title), images: files.allSatisfy(\.isImage)) }
    }

    private func exportFiles(_ files: [CaseFile]) {
        guard !files.isEmpty else { return }
        run {
            var locals: [GeneratedMediaFile] = []
            for file in files { locals.append(try await model.local(file)) }
            action = CaseFileAction(files: locals, export: true)
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !model.busy else { return }
        model.busy = true
        model.error = nil
        Task {
            defer { model.busy = false }
            do { try await work() } catch { model.error = error.localizedDescription }
        }
    }
}

// MARK: - Hero Report Card with Real PDF Cover Thumbnail & Collapsible Draft History

private struct HeroReportCard: View {
    let model: CaseFilesModel
    let report: CaseFile
    let previousReports: [CaseFile]
    @Binding var versionsExpanded: Bool
    let open: (CaseFile) -> Void
    let share: (CaseFile) -> Void
    let export: (CaseFile) -> Void
    let quote: ((String) -> Void)?
    let enterSelect: (CaseFile) -> Void
    @State private var cover: UIImage?

    private var metaText: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(report.size), countStyle: .file)
        guard report.createdAt > 0 else { return size }
        let ts = report.createdAt > 10_000_000_000 ? Int(report.createdAt) : Int(report.createdAt * 1000)
        return "\(size) · \(AssistantDesign.age(ts))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { open(report) } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AssistantDesign.surfaceMuted)
                        if let cover {
                            Image(uiImage: cover)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "doc.richtext.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AssistantDesign.accent)
                        }
                    }
                    .frame(width: 46, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(AssistantDesign.border, lineWidth: 0.6)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.fileName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(previousReports.isEmpty ? "主报告" : "最新主报告")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AssistantDesign.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(AssistantDesign.accentSoft, in: Capsule())
                            Text(metaText)
                                .font(.caption2)
                                .foregroundStyle(AssistantDesign.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let quote {
                    Button { quote(report.fileName) } label: { Label("引用回对话追问", systemImage: "bubble.left") }
                }
                Button { open(report) } label: { Label("预览报告", systemImage: "eye") }
                Button { share(report) } label: { Label("转发报告", systemImage: "square.and.arrow.up") }
                Button { export(report) } label: { Label("存文件", systemImage: "arrow.down.to.line") }
                Divider()
                Button { enterSelect(report) } label: { Label("进入多选", systemImage: "checkmark.circle") }
            }

            if !previousReports.isEmpty {
                Rectangle()
                    .fill(AssistantDesign.border)
                    .frame(height: 0.5)
                Button {
                    withAnimation(.snappy(duration: 0.2)) { versionsExpanded.toggle() }
                } label: {
                    HStack {
                        Text("历史初稿（\(previousReports.count) 份）")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AssistantDesign.inkMuted)
                        Spacer()
                        Image(systemName: versionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AssistantDesign.inkMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if versionsExpanded {
                    VStack(spacing: 6) {
                        ForEach(previousReports, id: \.selectionID) { old in
                            Button { open(old) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.richtext")
                                        .font(.caption)
                                        .foregroundStyle(AssistantDesign.inkMuted)
                                    Text(old.fileName)
                                        .font(.caption)
                                        .foregroundStyle(AssistantDesign.inkSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(old.size), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(AssistantDesign.inkMuted)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(AssistantDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AssistantDesign.accentBorder, lineWidth: 1.0)
        )
        .task(id: report.selectionID) {
            cover = await model.pdfCoverThumbnail(for: report)
        }
    }
}

// MARK: - ZIP Push View inside Right Drawer

struct ZIPContentsView: View {
    let route: ZIPRoute
    let title: String
    var isDrawer: Bool = false
    var onQuoteFile: ((String) -> Void)? = nil
    let back: () -> Void

    @State private var selecting = false
    @State private var selected = Set<Int>()
    @State private var action: CaseFileAction?
    @State private var preview: CaseFileAction?
    @State private var gallery: CaseGalleryRoute?
    @State private var error: String?
    @State private var busy = false

    private var entries: [SafeZIP.Entry] { route.archive.entries }
    private var docEntries: [SafeZIP.Entry] { entries.filter { !$0.isImage } }
    private var imageEntries: [SafeZIP.Entry] { entries.filter(\.isImage) }
    private var picked: [SafeZIP.Entry] { entries.filter { selected.contains($0.id) } }
    private var allSelected: Bool { !entries.isEmpty && entries.allSatisfy { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if selecting {
                    Text(picked.isEmpty ? "选择卷内文件" : "已选 \(picked.count) 项")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AssistantDesign.ink)
                    Spacer()
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if allSelected { selected.removeAll() }
                            else { selected = Set(entries.map(\.id)) }
                        }
                    } label: {
                        Text(allSelected ? "取消全选" : "全选")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AssistantDesign.surfaceMuted, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            selecting = false
                            selected.removeAll()
                        }
                    } label: {
                        Text("完成")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.inkOnSolid)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(AssistantDesign.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: back) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text(isDrawer ? "本案卷宗" : "返回")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(AssistantDesign.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !entries.isEmpty {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { selecting = true }
                        } label: {
                            Text("选择")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssistantDesign.ink)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(AssistantDesign.surfaceMuted, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, isDrawer ? 12 : 24)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.file.url.lastPathComponent)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssistantDesign.ink)
                    .lineLimit(2)
                Text("共 \(entries.count) 份 · \(ByteCountFormatter.string(fromByteCount: Int64(route.file.byteCount), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(AssistantDesign.inkMuted)
            }
            .padding(.bottom, 10)

            Rectangle()
                .fill(AssistantDesign.border)
                .frame(height: 0.5)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    if !docEntries.isEmpty {
                        Text("文档")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.inkMuted)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(docEntries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 {
                                    Rectangle()
                                        .fill(AssistantDesign.border)
                                        .frame(height: 0.5)
                                        .padding(.leading, selecting ? 80 : 54)
                                }
                                CaseFileRow(
                                    name: entry.fileName,
                                    detail: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file),
                                    directoryTag: entryDirectory(entry.path),
                                    isPrimaryReport: false,
                                    selecting: selecting,
                                    selected: selected.contains(entry.id),
                                    isContainer: false,
                                    select: { toggle(entry.id) },
                                    open: {
                                        if selecting { toggle(entry.id) }
                                        else { perform { preview = CaseFileAction(files: try await extract([entry])) } }
                                    }
                                )
                                .contextMenu {
                                    zipEntryMenu(entry)
                                }
                            }
                        }
                        .background(AssistantDesign.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
                        )
                    }

                    if !imageEntries.isEmpty {
                        Text("截图与扫描件")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AssistantDesign.inkMuted)
                            .padding(.leading, 4)

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 5),
                                GridItem(.flexible(), spacing: 5),
                                GridItem(.flexible(), spacing: 5),
                            ],
                            spacing: 5
                        ) {
                            ForEach(Array(imageEntries.enumerated()), id: \.element.id) { idx, entry in
                                ZIPImageTile(
                                    archive: route.archive,
                                    entry: entry,
                                    selecting: selecting,
                                    selected: selected.contains(entry.id),
                                    select: { toggle(entry.id) },
                                    open: {
                                        if selecting { toggle(entry.id) }
                                        else { openZIPGallery(startIndex: idx) }
                                    }
                                )
                                .contextMenu {
                                    zipEntryMenu(entry)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            if let error { Text(error).font(.caption).foregroundStyle(AssistantDesign.report).padding(.vertical, 4) }
            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(AssistantDesign.accent)
                    Text("正在准备资料…").font(.caption).foregroundStyle(AssistantDesign.inkMuted)
                }
                .padding(.vertical, 6)
            }

            VStack(spacing: 0) {
                Rectangle().fill(AssistantDesign.border).frame(height: 0.5)
                HStack(spacing: 8) {
                    if selecting {
                        compactActionButton("存文件", icon: "arrow.down.to.line") {
                            perform { action = CaseFileAction(files: try await extract(picked), export: true) }
                        }
                        .disabled(picked.isEmpty || busy)

                        let allImages = !picked.isEmpty && picked.allSatisfy(\.isImage)
                        let label = picked.isEmpty
                            ? "选择后转发"
                            : (picked.count == 1 ? "转发已选 (1)" : (allImages ? "转发图片 (\(picked.count))" : "打包转发 (\(picked.count))"))
                        primaryActionButton(label, icon: "square.and.arrow.up", accent: true) {
                            perform {
                                let files = try await extract(picked)
                                let shareFiles = files.count > 1 && !allImages
                                    ? [try await CaseFilesModel.package(files, title: title)]
                                    : files
                                action = CaseFileAction(files: shareFiles, images: allImages)
                            }
                        }
                        .disabled(picked.isEmpty || busy)
                    } else {
                        primaryActionButton("整包转发 ZIP", icon: "square.and.arrow.up", accent: false) {
                            action = CaseFileAction(files: [route.file])
                        }
                        .disabled(busy)
                        compactActionButton("存文件", icon: "arrow.down.to.line") {
                            action = CaseFileAction(files: [route.file], export: true)
                        }
                        .disabled(busy)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityIdentifier("assistant.zip-contents")
        .sheet(item: $action) { value in CaseFilesActivity(files: value.files, images: value.images, export: value.export) }
        .sheet(item: $preview) { value in CaseFilesPreview(file: value.files[0]) }
        .fullScreenCover(item: $gallery) { route in CaseGalleryView(route: route) }
    }

    @ViewBuilder
    private func zipEntryMenu(_ entry: SafeZIP.Entry) -> some View {
        if let onQuoteFile {
            Button { onQuoteFile(entry.fileName) } label: { Label("引用回对话追问", systemImage: "bubble.left") }
        }
        Button {
            perform { preview = CaseFileAction(files: try await extract([entry])) }
        } label: { Label("预览", systemImage: "eye") }
        Button {
            perform { action = CaseFileAction(files: try await extract([entry]), images: entry.isImage) }
        } label: { Label("转发", systemImage: "square.and.arrow.up") }
        Button {
            perform { action = CaseFileAction(files: try await extract([entry]), export: true) }
        } label: { Label("存文件", systemImage: "arrow.down.to.line") }
        if !selecting {
            Divider()
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    selecting = true
                    selected.insert(entry.id)
                }
            } label: { Label("进入多选", systemImage: "checkmark.circle") }
        }
    }

    private func toggle(_ id: Int) {
        withAnimation(.snappy(duration: 0.18)) {
            if !selected.insert(id).inserted { selected.remove(id) }
        }
    }

    private func entryDirectory(_ path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let dir = String(path[..<slash])
        return dir.isEmpty ? nil : "\(dir)/"
    }

    private func openZIPGallery(startIndex: Int) {
        perform {
            let extracted = try await extract(imageEntries)
            let items = zip(imageEntries, extracted).map { entry, file in
                CaseGalleryItem(id: "zip:\(entry.id)", title: entry.fileName, subtitle: route.file.url.lastPathComponent, file: file)
            }
            guard !items.isEmpty else { return }
            gallery = CaseGalleryRoute(items: items, startIndex: min(startIndex, items.count - 1))
        }
    }

    private func extract(_ entries: [SafeZIP.Entry]) async throws -> [GeneratedMediaFile] {
        let archive = route.archive
        return try await Task.detached(priority: .utility) {
            try entries.map { try GeneratedMediaFile(data: archive.extract($0), fileName: $0.fileName, mimeType: nil) }
        }.value
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Fullscreen Swipeable Image Gallery

struct CaseGalleryView: View {
    let route: CaseGalleryRoute
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var action: CaseFileAction?

    init(route: CaseGalleryRoute) {
        self.route = route
        _index = State(initialValue: max(0, min(route.startIndex, route.items.count - 1)))
    }

    private var current: CaseGalleryItem {
        route.items[max(0, min(index, route.items.count - 1))]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(route.items.enumerated()), id: \.element.id) { idx, item in
                    Group {
                        if let img = UIImage(contentsOfFile: item.file.url.path) {
                            ZoomableImageView(image: img) {}
                        } else {
                            ContentUnavailableView("无法加载图片", systemImage: "photo")
                                .foregroundStyle(.white)
                        }
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: route.items.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭预览")

                    Spacer()

                    VStack(spacing: 2) {
                        Text(current.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(index + 1) / \(route.items.count) · \(current.subtitle)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(.horizontal, 10)

                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(
                    LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                )

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        action = CaseFileAction(files: [current.file], images: true, export: true)
                    } label: {
                        Label("存文件", systemImage: "arrow.down.to.line")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(AssistantPressStyle(scale: 0.96))

                    Button {
                        action = CaseFileAction(files: [current.file], images: true, export: false)
                    } label: {
                        Label("转发此图", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AssistantDesign.accentGradient, in: Capsule())
                    }
                    .buttonStyle(AssistantPressStyle(scale: 0.96))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 18)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .sheet(item: $action) { value in
            CaseFilesActivity(files: value.files, images: value.images, export: value.export)
        }
    }
}

// MARK: - Shared Format Badge, Rows, Tiles & Activity Sheets

struct FileTypeBadge: View {
    let name: String
    var compact: Bool = false
    var highlighted: Bool = false

    private var ext: String { (name as NSString).pathExtension.lowercased() }
    private var symbol: String {
        switch ext {
        case "zip", "rar", "7z", "tar", "gz": "archivebox"
        case "xls", "xlsx", "csv": "tablecells"
        case "jpg", "jpeg", "png", "heic", "webp": "photo"
        case "pdf": "doc.richtext"
        default: "doc.text"
        }
    }

    private var tint: Color {
        if highlighted { return AssistantDesign.accent }
        switch ext {
        case "zip", "rar", "7z": return AssistantDesign.risk
        case "pdf": return AssistantDesign.report
        case "xls", "xlsx", "csv": return AssistantDesign.accent
        case "doc", "docx": return AssistantDesign.slateBlue
        default: return AssistantDesign.inkSecondary
        }
    }

    private var fill: Color {
        if highlighted { return AssistantDesign.accentSoft }
        switch ext {
        case "zip", "rar", "7z": return AssistantDesign.risk.opacity(0.12)
        case "pdf": return AssistantDesign.report.opacity(0.11)
        case "xls", "xlsx", "csv": return AssistantDesign.accentSoft
        case "doc", "docx": return AssistantDesign.slateBlue.opacity(0.12)
        default: return AssistantDesign.surfaceMuted
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 13.5 : 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
            .background(fill, in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous))
    }
}

private struct CaseFileRow: View {
    let name: String
    let detail: String
    var directoryTag: String? = nil
    let isPrimaryReport: Bool
    let selecting: Bool
    let selected: Bool
    let isContainer: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if selecting {
                selectionCircle(selected, action: select)
                    .transition(.scale.combined(with: .opacity))
            }
            Button(action: open) {
                HStack(spacing: 10) {
                    FileTypeBadge(name: name, highlighted: isPrimaryReport)
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AssistantDesign.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 5) {
                            if isPrimaryReport {
                                Text("主报告")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AssistantDesign.accent)
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1)
                                    .background(AssistantDesign.accentSoft, in: Capsule())
                            }
                            if let directoryTag {
                                Text(directoryTag)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(AssistantDesign.inkSecondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(AssistantDesign.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isContainer && !selecting {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AssistantDesign.inkMuted)
                    }
                }
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(selecting && selected ? AssistantDesign.accent.opacity(0.07) : .clear)
    }
}

private func cleanImageCaption(_ fileName: String) -> String? {
    let stem = (fileName as NSString).deletingPathExtension
    let lower = stem.lowercased()
    if lower.hasPrefix("photo-") || lower.hasPrefix("camera-") || lower.hasPrefix("img_") || lower.hasPrefix("pxl_") || lower.hasPrefix("screenshot_") {
        return nil
    }
    let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private struct CaseImageTile: View {
    let model: CaseFilesModel
    let file: CaseFile
    let selecting: Bool
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    @State private var image: UIImage?

    private var caption: String? { cleanImageCaption(file.fileName) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                Rectangle()
                    .fill(AssistantDesign.surfaceMuted)
                    .aspectRatio(1.05, contentMode: .fill)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(AssistantDesign.inkMuted)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let caption {
                            Text(caption)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 4)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
                                )
                        }
                    }
                    .clipped()
            }
            .buttonStyle(.plain)

            if selecting {
                Button(action: select) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(selected ? AssistantDesign.accent : Color.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: selected)
                .padding(4)
                .accessibilityLabel(selected ? "取消选择 \(file.fileName)" : "选择 \(file.fileName)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selecting && selected ? AssistantDesign.accent : AssistantDesign.border, lineWidth: selecting && selected ? 1.8 : 0.5)
        )
        .task(id: file.selectionID) {
            if let local = try? await model.local(file) {
                image = await Task.detached {
                    UIImage(contentsOfFile: local.url.path)?.preparingThumbnail(of: CGSize(width: 300, height: 260))
                }.value
            }
        }
    }
}

private struct ZIPImageTile: View {
    let archive: SafeZIP
    let entry: SafeZIP.Entry
    let selecting: Bool
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    @State private var image: UIImage?

    private var caption: String? { cleanImageCaption(entry.fileName) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                Rectangle()
                    .fill(AssistantDesign.surfaceMuted)
                    .aspectRatio(1.05, contentMode: .fill)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(AssistantDesign.inkMuted)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let caption {
                            Text(caption)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 4)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
                                )
                        }
                    }
                    .clipped()
            }
            .buttonStyle(.plain)

            if selecting {
                Button(action: select) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(selected ? AssistantDesign.accent : Color.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selecting && selected ? AssistantDesign.accent : AssistantDesign.border, lineWidth: selecting && selected ? 1.8 : 0.5)
        )
        .task(id: entry.id) {
            image = await Task.detached(priority: .utility) {
                guard let data = try? archive.extract(entry) else { return nil }
                return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 280, height: 240))
            }.value
        }
    }
}

@MainActor private func selectionCircle(_ selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(selected ? AssistantDesign.accent : Color.secondary.opacity(0.45))
            .frame(width: 26, height: 32)
    }
    .buttonStyle(.plain)
    .sensoryFeedback(.selection, trigger: selected)
    .accessibilityLabel(selected ? "取消选择" : "选择资料")
}

@MainActor private func compactActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AssistantDesign.ink)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .assistantSurface(radius: 22)
    }
    .buttonStyle(AssistantPressStyle(scale: 0.96))
}

@MainActor private func primaryActionButton(_ title: String, icon: String? = nil, accent: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.subheadline.weight(.semibold)) }
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(accent ? .white : AssistantDesign.inkOnSolid)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background {
            if accent {
                Capsule().fill(AssistantDesign.accentGradient)
            } else {
                Capsule().fill(AssistantDesign.ink)
            }
        }
        .shadow(color: accent ? AssistantDesign.accent.opacity(0.22) : .clear, radius: 8, y: 3)
    }
    .buttonStyle(AssistantPressStyle(scale: 0.97))
}

struct CaseFilesActivity: UIViewControllerRepresentable {
    let files: [GeneratedMediaFile]
    let images: Bool
    let export: Bool
    func makeUIViewController(context: Context) -> UIViewController {
        if export { return UIDocumentPickerViewController(forExporting: files.map(\.url), asCopy: true) }
        let items: [Any] = images ? files.map { UIImage(contentsOfFile: $0.url.path) as Any? ?? $0.url as Any } : files.map { $0.url as Any }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct CaseFilesPreview: View {
    let file: GeneratedMediaFile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            if let image = UIImage(contentsOfFile: file.url.path) {
                ZoomableImageView(image: image) {}
            } else {
                CaseQuickLook(file: file)
            }
            Button {
                dismiss()
            } label: {
                Label("返回资料", systemImage: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(AssistantDesign.surface)
            }
            .buttonStyle(.plain)
        }
        .presentationDragIndicator(.visible)
    }
}

private struct CaseQuickLook: UIViewControllerRepresentable {
    let file: GeneratedMediaFile
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: GeneratedMediaFile
        init(file: GeneratedMediaFile) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file.url as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

struct CaseFileAccess {
    let count: Int
    var mainReportID: String? = nil
    let open: () -> Void
    var openZip: ((String) -> Void)? = nil
}

private struct CaseFileAccessKey: EnvironmentKey { static let defaultValue: CaseFileAccess? = nil }
extension EnvironmentValues {
    var caseFileAccess: CaseFileAccess? {
        get { self[CaseFileAccessKey.self] }
        set { self[CaseFileAccessKey.self] = newValue }
    }
}

extension Notification.Name {
    static let assistantImportFiles = Notification.Name("assistantImportFiles")
    static let assistantQuoteFile = Notification.Name("assistantQuoteFile")
    static let assistantRequestAddFiles = Notification.Name("assistantRequestAddFiles")
}
