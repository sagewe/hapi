import HapiClient
import HapiUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

private struct CaseFileAction: Identifiable {
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
struct CaseFilesView: View {
    @Bindable var model: CaseFilesModel
    let title: String
    @State private var filter = 0
    @State private var selected = Set<String>()
    @State private var zip: ZIPRoute?
    @State private var action: CaseFileAction?
    @State private var preview: CaseFileAction?
    init(model: CaseFilesModel, title: String, initialSelection: Set<String> = []) {
        self.model = model; self.title = title; _selected = State(initialValue: initialSelection)
    }
    private var shown: [CaseFile] { model.files.filter { filter == 0 || (filter == 2) == $0.isUpload } }
    private var picked: [CaseFile] { model.files.filter { selected.contains($0.selectionID) } }
    var body: some View {
        Group {
            if let zip {
                ZIPContentsView(route: zip, title: title, back: { self.zip = nil })
            } else { inventory }
        }
        .background(AssistantDesign.background)
        .presentationDetents([.fraction(0.88), .large])
        .presentationDragIndicator(.visible)
        .task { await model.refresh() }
        .sheet(item: $action) { value in CaseFilesActivity(files: value.files, images: value.images, export: value.export) }
        .sheet(item: $preview) { value in CaseFilesPreview(file: value.files[0]) }
    }
    private var inventory: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("本案资料（\(model.files.count)）").font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Text("持久留存").font(.caption.weight(.medium)).foregroundStyle(.green)
            }.padding(.top, 26).padding(.bottom, 16)
            Picker("资料分类", selection: $filter) {
                Text("全部").tag(0); Text("报告与证据").tag(1); Text("送审原件").tag(2)
            }.pickerStyle(.segmented).padding(.bottom, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if shown.isEmpty {
                        ContentUnavailableView("暂无资料", systemImage: "folder", description: Text("报告、证据和送审原件会保留在这里"))
                    }
                    ForEach([false, true], id: \.self) { upload in
                        let group = shown.filter { $0.isUpload == upload }
                        if !group.isEmpty {
                            Text(upload ? "送审原件" : "报告与证据").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
                            ForEach(group.filter { !$0.isImage }.sorted { ($0.selectionID == model.report?.selectionID ? 0 : 1) < ($1.selectionID == model.report?.selectionID ? 0 : 1) }, id: \.selectionID) { file in
                                CaseFileRow(name: file.fileName, detail: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file), selected: selected.contains(file.selectionID), label: file.isZIP ? "展开 ›" : "预览", select: { toggle(file.selectionID) }, open: { open(file) })
                            }
                            let images = group.filter(\.isImage)
                            if !images.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                                    ForEach(images, id: \.selectionID) { file in
                                        CaseImageTile(model: model, file: file, selected: selected.contains(file.selectionID), select: { toggle(file.selectionID) }, open: { open(file) })
                                    }
                                }
                            }
                        }
                    }
                }.padding(.bottom, 16)
            }
            if let error = model.error {
                HStack { Text(error).font(.caption).foregroundStyle(.red); Button("重试") { Task { await model.refresh() } } }.padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                thumb("存文件", icon: "arrow.down") { exportFiles(picked.isEmpty ? shown : picked) }
                if picked.isEmpty {
                    if let archive = model.files.first(where: \.isZIP) {
                        thumb("整包发 ZIP", primary: false) { share([archive]) }
                    }
                    thumb("转发尽调报告", primary: true) {
                        if let report = model.report { share([report]) }
                    }.disabled(!model.files.contains { !$0.isUpload && $0.isPDF })
                } else {
                    thumb("转发已选 (\(picked.count))", primary: true) { share(picked) }
                }
            }.padding(.vertical, 12).background(AssistantDesign.background)
            if model.busy { ProgressView("正在准备资料…").font(.caption).padding(.bottom, 6) }
        }.padding(.horizontal, 16).accessibilityIdentifier("assistant.case-files")
    }
    private func toggle(_ id: String) { if !selected.insert(id).inserted { selected.remove(id) } }
    private func open(_ file: CaseFile) {
        run {
            let local = try await model.local(file)
            if file.isZIP {
                let archive = try await Task.detached { try SafeZIP(data: Data(contentsOf: local.url)) }.value
                zip = ZIPRoute(file: local, archive: archive)
            } else { preview = CaseFileAction(files: [local]) }
        }
    }
    private func share(_ files: [CaseFile]) {
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
        guard !model.busy else { return }; model.busy = true; model.error = nil
        Task { defer { model.busy = false }; do { try await work() } catch { model.error = error.localizedDescription } }
    }
}

struct ZIPContentsView: View {
    let route: ZIPRoute
    let title: String
    let back: () -> Void
    @State private var selected = Set<Int>()
    @State private var action: CaseFileAction?
    @State private var preview: CaseFileAction?
    @State private var error: String?
    @State private var busy = false
    private var picked: [SafeZIP.Entry] { route.archive.entries.filter { selected.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(route.file.url.lastPathComponent).font(.title3.weight(.semibold)).lineLimit(2)
                    Text("共 \(route.archive.entries.count) 份资料 · 按需预览").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); FileTypeBadge(name: "archive.zip")
            }.padding(.top, 26).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(route.archive.entries) { entry in
                        CaseFileRow(name: entry.fileName, detail: entry.path == entry.fileName ? ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file) : entry.path,
                            selected: selected.contains(entry.id), label: entry.isImage ? "看图" : "预览",
                            select: { if !selected.insert(entry.id).inserted { selected.remove(entry.id) } },
                            open: { perform { preview = CaseFileAction(files: try await extract([entry])) } })
                    }
                }.padding(.bottom, 12)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if busy { ProgressView("正在准备资料…").font(.caption) }
            HStack(spacing: 8) {
                thumb("返回资料", icon: "arrow.left", action: back)
                thumb("存", icon: "arrow.down") { perform { action = CaseFileAction(files: picked.isEmpty ? [route.file] : try await extract(picked), export: true) } }
                thumb(picked.isEmpty ? "整包转发" : "转发已选 (\(picked.count))", primary: true) {
                    perform {
                        if picked.isEmpty { action = CaseFileAction(files: [route.file]) }
                        else {
                            let files = try await extract(picked), images = picked.allSatisfy(\.isImage)
                            let share = files.count > 1 && !images ? [try await CaseFilesModel.package(files, title: title)] : files
                            action = CaseFileAction(files: share, images: images)
                        }
                    }
                }
            }.padding(.vertical, 12)
        }.padding(.horizontal, 16).accessibilityIdentifier("assistant.zip-contents")
        .sheet(item: $action) { value in CaseFilesActivity(files: value.files, images: value.images, export: value.export) }
        .sheet(item: $preview) { value in CaseFilesPreview(file: value.files[0]) }
    }
    private func extract(_ entries: [SafeZIP.Entry]) async throws -> [GeneratedMediaFile] {
        let archive = route.archive
        return try await Task.detached(priority: .utility) {
            try entries.map { try GeneratedMediaFile(data: archive.extract($0), fileName: $0.fileName, mimeType: nil) }
        }.value
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
}

struct FileTypeBadge: View {
    let name: String
    private var ext: String { (name as NSString).pathExtension.lowercased() }
    private var color: Color {
        switch ext { case "pdf": .pink; case "zip": .orange; case "doc", "docx": .blue; case "xls", "xlsx", "csv": .green; default: .purple }
    }
    var body: some View {
        Text(ext == "docx" ? "DOC" : ext == "xlsx" ? "XLS" : String(ext.uppercased().prefix(4)))
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .frame(width: 36, height: 38).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
private struct CaseFileRow: View {
    let name: String; let detail: String; let selected: Bool; let label: String
    let select: () -> Void; let open: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            selectionCircle(selected, action: select)
            Button(action: open) {
                HStack(spacing: 10) {
                    FileTypeBadge(name: name)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(label).font(.caption.weight(.medium)).foregroundStyle(name.lowercased().hasSuffix(".zip") ? .orange : .blue)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(10).background(selected ? Color.blue.opacity(0.04) : AssistantDesign.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.blue : AssistantDesign.border, lineWidth: selected ? 1 : 0.5))
    }
}
private struct CaseImageTile: View {
    let model: CaseFilesModel; let file: CaseFile; let selected: Bool
    let select: () -> Void; let open: () -> Void
    @State private var image: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) {
                    Rectangle().fill(Color.blue.opacity(0.07)).frame(height: 88)
                        .overlay {
                            if let image { Image(uiImage: image).resizable().scaledToFill() }
                            else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }.clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                selectionCircle(selected, action: select).background(.regularMaterial, in: Circle()).padding(3)
            }
            Text(file.fileName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(6).background(AssistantDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? .blue : AssistantDesign.border, lineWidth: selected ? 1 : 0.5))
            .task {
                if let local = try? await model.local(file) {
                    image = await Task.detached { UIImage(contentsOfFile: local.url.path)?.preparingThumbnail(of: CGSize(width: 300, height: 220)) }.value
                }
            }
    }
}
@MainActor private func selectionCircle(_ selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(selected ? Color.blue : Color.secondary.opacity(0.45)).frame(width: 32, height: 36)
    }.buttonStyle(.plain).accessibilityLabel(selected ? "取消选择" : "选择资料")
}
@MainActor private func thumb(_ title: String, icon: String? = nil, primary: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 4) { if let icon { Image(systemName: icon) }; Text(title).lineLimit(1).minimumScaleFactor(0.75) }
            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? Color.blue : AssistantDesign.surface, in: Capsule())
            .overlay(Capsule().stroke(primary ? .clear : AssistantDesign.border, lineWidth: 0.7))
    }.buttonStyle(.plain)
}
private struct CaseFilesActivity: UIViewControllerRepresentable {
    let files: [GeneratedMediaFile]; let images: Bool; let export: Bool
    func makeUIViewController(context: Context) -> UIViewController {
        if export { return UIDocumentPickerViewController(forExporting: files.map(\.url), asCopy: true) }
        let items: [Any] = images ? files.map { UIImage(contentsOfFile: $0.url.path) as Any? ?? $0.url as Any } : files.map { $0.url as Any }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
private struct CaseFilesPreview: View {
    let file: GeneratedMediaFile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            if let image = UIImage(contentsOfFile: file.url.path) { ZoomableImageView(image: image) {} }
            else { CaseQuickLook(file: file) }
            Button("返回资料", systemImage: "arrow.down") { dismiss() }.frame(maxWidth: .infinity, minHeight: 48).buttonStyle(.bordered)
        }.presentationDragIndicator(.visible)
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
    func makeUIViewController(context: Context) -> QLPreviewController { let c = QLPreviewController(); c.dataSource = context.coordinator; return c }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

struct CaseFileAccess {
    let count: Int
    var mainReportID: String? = nil
    let open: () -> Void
}
private struct CaseFileAccessKey: EnvironmentKey { static let defaultValue: CaseFileAccess? = nil }
extension EnvironmentValues {
    var caseFileAccess: CaseFileAccess? {
        get { self[CaseFileAccessKey.self] }
        set { self[CaseFileAccessKey.self] = newValue }
    }
}
extension Notification.Name { static let assistantImportFiles = Notification.Name("assistantImportFiles") }
