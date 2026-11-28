import Foundation
import HapiClient
import HapiProtocol
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class AssistantLibraryModel {
    let api: APIClient
    private(set) var deliverables: [RecentDeliverable] = []
    private(set) var referenceDocs: [ReferenceDoc] = []
    var busy = false
    var error: String?

    private var fileCache: [String: GeneratedMediaFile] = [:]
    private var pdfThumbCache: [String: UIImage] = [:]

    init(api: APIClient) {
        self.api = api
    }

    func refresh() async {
        async let delivs = api.recentDeliverables(limit: 50)
        async let refs = api.referenceDocs()
        do {
            let (d, r) = try await (delivs, refs)
            deliverables = d
            referenceDocs = r
            error = nil
        } catch {
            if !Task.isCancelled {
                self.error = "资料库暂时无法读取，请重试"
            }
        }
    }

    func localDeliverable(_ item: RecentDeliverable) async throws -> GeneratedMediaFile {
        if let cached = fileCache[item.uniqueKey] { return cached }
        let diskURL = CaseFilesModel.diskCacheURL(sessionId: item.sessionId, fileId: item.id, fileName: item.fileName)
        if let existing = try? Data(contentsOf: diskURL), !existing.isEmpty {
            let local = try await Task.detached(priority: .utility) {
                try GeneratedMediaFile(data: existing, fileName: item.fileName, mimeType: item.mimeType)
            }.value
            fileCache[item.uniqueKey] = local
            return local
        }
        let bytes = try await api.deliverableBytes(sessionId: item.sessionId, mediaId: item.id)
        Task.detached(priority: .background) { CaseFilesModel.writeDiskCache(data: bytes, url: diskURL) }
        let local = try await Task.detached(priority: .utility) {
            try GeneratedMediaFile(data: bytes, fileName: item.fileName, mimeType: item.mimeType)
        }.value
        fileCache[item.uniqueKey] = local
        return local
    }

    func pdfThumb(for item: RecentDeliverable) async -> UIImage? {
        guard item.isPDF else { return nil }
        if let cached = pdfThumbCache[item.uniqueKey] { return cached }
        guard let local = try? await localDeliverable(item) else { return nil }
        let url = local.url
        let img = await Task.detached(priority: .utility) {
            CaseFilesModel.renderPDFCover(url: url, targetSize: CGSize(width: 96, height: 128))
        }.value
        if let img { pdfThumbCache[item.uniqueKey] = img }
        return img
    }

    func localReferenceDoc(_ doc: ReferenceDoc) async throws -> GeneratedMediaFile {
        let key = "ref:\(doc.id)"
        if let cached = fileCache[key] { return cached }
        let diskURL = CaseFilesModel.diskCacheURL(sessionId: "_reference_docs", fileId: doc.id, fileName: doc.fileName)
        if let existing = try? Data(contentsOf: diskURL), !existing.isEmpty {
            let local = try await Task.detached(priority: .utility) {
                try GeneratedMediaFile(data: existing, fileName: doc.fileName, mimeType: doc.mimeType)
            }.value
            fileCache[key] = local
            return local
        }
        let bytes = try await api.referenceDocBytes(id: doc.id)
        Task.detached(priority: .background) { CaseFilesModel.writeDiskCache(data: bytes, url: diskURL) }
        let local = try await Task.detached(priority: .utility) {
            try GeneratedMediaFile(data: bytes, fileName: doc.fileName, mimeType: doc.mimeType)
        }.value
        fileCache[key] = local
        return local
    }

    func uploadReferenceDoc(_ prepared: PreparedAttachment, scope: String = "library") async throws {
        let uploaded = try await api.uploadReferenceDoc(
            filename: prepared.filename,
            data: prepared.bytes,
            mimeType: prepared.mimeType,
            scope: scope
        )
        referenceDocs.insert(uploaded, at: 0)
    }

    func toggleGlobal(_ doc: ReferenceDoc) async {
        do {
            let updated = try await api.updateReferenceDoc(id: doc.id, scope: doc.isGlobal ? "library" : "global")
            if let idx = referenceDocs.firstIndex(where: { $0.id == doc.id }) {
                referenceDocs[idx] = updated
            }
        } catch {
            self.error = "更新失败，请重试"
        }
    }

    func deleteReferenceDoc(_ doc: ReferenceDoc) async {
        do {
            try await api.deleteReferenceDoc(id: doc.id)
            referenceDocs.removeAll { $0.id == doc.id }
            fileCache.removeValue(forKey: "ref:\(doc.id)")
        } catch {
            self.error = "删除失败，请重试"
        }
    }
}

struct AssistantLibraryDrawer: View {
    @Bindable var model: AssistantLibraryModel
    let scenarios: [AssistantScene]
    let onOpenSession: (String) -> Void
    let onUseReferenceInStudio: (ReferenceDoc) -> Void

    @State private var tab = 0 // 0 = 最近交付, 1 = 参考底稿
    @State private var delivFilter = 0 // 0 = 报告, 1 = 证据包, 2 = 全部
    @State private var isSearching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var filePickerOpen = false
    @State private var action: CaseFileAction?
    @State private var preview: CaseFileAction?

    private var filteredDeliverables: [RecentDeliverable] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.deliverables.filter { item in
            let matchesTab: Bool = switch delivFilter {
            case 0: item.isPDF
            case 1: item.isZIP
            default: true
            }
            guard matchesTab else { return false }
            if q.isEmpty { return true }
            return item.fileName.localizedCaseInsensitiveContains(q)
                || item.sessionTitle.localizedCaseInsensitiveContains(q)
        }
    }

    private var groupedDeliverables: [(bucket: Int, items: [RecentDeliverable])] {
        let dict = Dictionary(grouping: filteredDeliverables) { item in
            let ts = item.createdAt > 10_000_000_000 ? Int(item.createdAt) : Int(item.createdAt * 1000)
            return AssistantDesign.dayBucket(ts)
        }
        return [0, 1, 2, 3].compactMap { bucket in
            guard let items = dict[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }

    private var filteredRefs: [ReferenceDoc] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return model.referenceDocs }
        return model.referenceDocs.filter { $0.fileName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("我的资料库")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(AssistantDesign.ink)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isSearching.toggle()
                        if !isSearching {
                            query = ""
                            searchFocused = false
                        } else {
                            searchFocused = true
                        }
                    }
                } label: {
                    Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AssistantDesign.ink)
                        .frame(width: 36, height: 36)
                        .assistantGlass(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索资料库")
            }
            .padding(.top, 12)
            .padding(.bottom, 10)

            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(AssistantDesign.inkMuted)
                    TextField("搜索报告、案件或参考底稿", text: $query)
                        .focused($searchFocused)
                        .font(.system(size: 14))
                        .foregroundStyle(AssistantDesign.ink)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(AssistantDesign.inkMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.bottom, 10)
            }

            // Segmented Switch: 最近交付 | 参考底稿
            HStack(spacing: 3) {
                segmentButton("最近交付", index: 0)
                segmentButton("参考底稿", index: 1)
            }
            .padding(3)
            .background(AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 10)

            if tab == 0 {
                HStack(spacing: 6) {
                    subFilterPill("报告", tag: 0)
                    subFilterPill("证据包", tag: 1)
                    subFilterPill("全部", tag: 2)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 10)
            }

            Rectangle()
                .fill(AssistantDesign.border)
                .frame(height: 0.5)
                .padding(.bottom, 10)

            if tab == 0 {
                deliverablesList
            } else {
                referenceDocsList
            }

            if let error = model.error {
                HStack {
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
                    Text("正在处理…").font(.caption).foregroundStyle(AssistantDesign.inkMuted)
                }
                .padding(.vertical, 6)
            }

            if tab == 1 {
                VStack(spacing: 0) {
                    Rectangle().fill(AssistantDesign.border).frame(height: 0.5)
                    HStack(spacing: 8) {
                        Button { filePickerOpen = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .bold))
                                Text("上传参考底稿")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(AssistantDesign.inkOnSolid)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AssistantDesign.ink, in: Capsule())
                        }
                        .buttonStyle(AssistantPressStyle(scale: 0.97))
                        .disabled(model.busy)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(AssistantDesign.background)
        .task { await model.refresh() }
        .fileImporter(isPresented: $filePickerOpen, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                run {
                    for url in urls {
                        if case .ready(let prepared) = await AttachmentPreparer.prepare(fileURL: url) {
                            try await model.uploadReferenceDoc(prepared)
                        }
                    }
                }
            }
        }
        .sheet(item: $action) { value in CaseFilesActivity(files: value.files, images: value.images, export: value.export) }
        .sheet(item: $preview) { value in CaseFilesPreview(file: value.files[0]) }
    }

    private var deliverablesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if groupedDeliverables.isEmpty {
                    ContentUnavailableView(
                        "暂无交付记录",
                        systemImage: "doc.richtext",
                        description: Text("各案件生成的尽调报告和证据包会汇集在这里")
                    )
                    .padding(.top, 36)
                }
                ForEach(groupedDeliverables, id: \.bucket) { group in
                    Text(AssistantDesign.dayBucketTitle(group.bucket))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssistantDesign.inkMuted)
                        .padding(.leading, 4)
                        .padding(.top, 2)

                    ForEach(group.items, id: \.uniqueKey) { item in
                        RecentDeliverableRow(
                            model: model,
                            item: item,
                            open: {
                                run { preview = CaseFileAction(files: [try await model.localDeliverable(item)]) }
                            },
                            share: {
                                run { action = CaseFileAction(files: [try await model.localDeliverable(item)], images: item.isImage) }
                            }
                        )
                        .contextMenu {
                            Button { onOpenSession(item.sessionId) } label: {
                                Label("进入所属案件", systemImage: "bubble.left.and.bubble.right")
                            }
                            Button {
                                run { preview = CaseFileAction(files: [try await model.localDeliverable(item)]) }
                            } label: { Label("预览", systemImage: "eye") }
                            Button {
                                run { action = CaseFileAction(files: [try await model.localDeliverable(item)], images: item.isImage) }
                            } label: { Label("转发", systemImage: "square.and.arrow.up") }
                            Button {
                                run { action = CaseFileAction(files: [try await model.localDeliverable(item)], export: true) }
                            } label: { Label("存文件", systemImage: "arrow.down.to.line") }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await model.refresh() }
    }

    private var referenceDocsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                if filteredRefs.isEmpty {
                    ContentUnavailableView(
                        "暂无参考底稿",
                        systemImage: "tray.full",
                        description: Text("上传常用行内审单表、高风险口径或报告模板，供定制场景和日常尽调复用")
                    )
                    .padding(.top, 36)
                }
                ForEach(filteredRefs) { doc in
                    let linkedTitle = doc.scenarioIds.compactMap { sid in
                        scenarios.first(where: { $0.id == sid })?.title
                    }.first
                    Button {
                        run { preview = CaseFileAction(files: [try await model.localReferenceDoc(doc)]) }
                    } label: {
                        HStack(spacing: 10) {
                            FileTypeBadge(name: doc.fileName)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(doc.fileName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AssistantDesign.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 5) {
                                    if doc.isGlobal {
                                        Text("全局生效")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(AssistantDesign.risk)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(AssistantDesign.risk.opacity(0.14), in: Capsule())
                                    } else if let linkedTitle {
                                        Text(linkedTitle)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(AssistantDesign.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(AssistantDesign.accentSoft, in: Capsule())
                                    }
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(doc.size), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(AssistantDesign.inkMuted)
                                }
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(11)
                        .assistantSurface(radius: 15)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { onUseReferenceInStudio(doc) } label: {
                            Label("基于此底稿定制场景", systemImage: "sparkle")
                        }
                        Button {
                            Task { await model.toggleGlobal(doc) }
                        } label: {
                            Label(doc.isGlobal ? "取消全局生效" : "设为全局生效", systemImage: doc.isGlobal ? "globe.badge.chevron.backward" : "globe")
                        }
                        Button {
                            run { action = CaseFileAction(files: [try await model.localReferenceDoc(doc)], images: doc.isImage) }
                        } label: { Label("转发", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button(role: .destructive) {
                            Task { await model.deleteReferenceDoc(doc) }
                        } label: { Label("删除底稿", systemImage: "trash") }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await model.refresh() }
    }

    private func segmentButton(_ title: String, index: Int) -> some View {
        let active = tab == index
        return Button {
            withAnimation(.snappy(duration: 0.2)) { tab = index }
        } label: {
            Text(title)
                .font(.footnote.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? AssistantDesign.ink : AssistantDesign.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(active ? AssistantDesign.surface : .clear, in: RoundedRectangle(cornerRadius: 9.5, style: .continuous))
                .shadow(color: active ? AssistantDesign.shadow : .clear, radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func subFilterPill(_ title: String, tag: Int) -> some View {
        let active = delivFilter == tag
        return Button {
            withAnimation(.snappy(duration: 0.2)) { delivFilter = tag }
        } label: {
            Text(title)
                .font(.caption.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? AssistantDesign.inkOnSolid : AssistantDesign.inkSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(active ? AssistantDesign.ink : AssistantDesign.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
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

private struct RecentDeliverableRow: View {
    let model: AssistantLibraryModel
    let item: RecentDeliverable
    let open: () -> Void
    let share: () -> Void
    @State private var thumb: UIImage?

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        let title = item.sessionTitle.isEmpty ? "尽调案件" : item.sessionTitle
        return "\(title) · \(size)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if item.isPDF {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AssistantDesign.surfaceMuted)
                            if let thumb {
                                Image(uiImage: thumb).resizable().scaledToFill()
                            } else {
                                Image(systemName: "doc.richtext.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AssistantDesign.accent)
                            }
                        }
                        .frame(width: 36, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
                        )
                    } else {
                        FileTypeBadge(name: item.fileName)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.fileName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(AssistantDesign.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: share) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AssistantDesign.accent)
                    .frame(width: 34, height: 34)
                    .background(AssistantDesign.accentSoft, in: Circle())
            }
            .buttonStyle(AssistantPressStyle(scale: 0.92))
            .accessibilityLabel("转发 \(item.fileName)")
        }
        .padding(10)
        .assistantSurface(radius: 15)
        .task(id: item.uniqueKey) {
            if item.isPDF {
                thumb = await model.pdfThumb(for: item)
            }
        }
    }
}
