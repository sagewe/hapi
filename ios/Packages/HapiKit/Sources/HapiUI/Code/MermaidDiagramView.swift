#if canImport(UIKit) && canImport(WebKit)
import SwiftUI
import WebKit

struct MermaidDiagramView: View {
    let code: String
    @Environment(\.hapiTheme) private var theme
    @Environment(\.hapiTypography) private var typography
    @Environment(\.hapiPasteboard) private var pasteboard
    @State private var preview: MermaidPreview?
    @State private var error: String?
    @State private var sourceVisible = false
    @State private var presentation: MermaidPresentation?
    @State private var retry = 0

    private struct Request: Equatable { let code: String; let dark: Bool; let retry: Int }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("mermaid").font(typography.captionMonoFont).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if error == nil {
                    Button(sourceVisible ? LocalizedStringKey("Preview") : LocalizedStringKey("Source")) {
                        sourceVisible.toggle()
                    }
                    .font(typography.captionFont).frame(minHeight: 44)
                }
                Button {
                    Task { @MainActor in pasteboard.copy(code) }
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Copy diagram source")
            }
            .padding(.leading, 12)
            .background(theme.codeHeaderBackground)
            if sourceVisible || error != nil {
                if let error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error).font(typography.captionFont).foregroundStyle(theme.textSecondary)
                        Button("Retry") { sourceVisible = false; retry += 1 }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if code.count > MermaidRenderer.maxSourceLength {
                    Text("Source preview shortened. Copy to read the complete source.")
                        .font(typography.captionFont).foregroundStyle(theme.textSecondary).padding(.horizontal, 12)
                }
                ScrollView(.horizontal) {
                    Text(String(code.prefix(MermaidRenderer.maxSourceLength))).font(typography.codeFont).foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled).padding(12)
                }
            } else if let preview {
                Button {
                    presentation = MermaidPresentation(svg: preview.svg, dark: theme.isDark)
                } label: {
                    Image(uiImage: preview.image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(height: 240)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open diagram full screen")
                .accessibilityIdentifier("mermaid.preview")
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: 240)
                    .accessibilityLabel("Rendering diagram")
            }
        }
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: Request(code: code, dark: theme.isDark, retry: retry)) {
            preview = nil
            error = nil
            do {
                // Streamed fences can change on every token. Wait for a quiet
                // interval before joining the renderer's bounded queue.
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                let result = try await MermaidRenderer.shared.render(code: code, dark: theme.isDark)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = String(error.localizedDescription.prefix(400))
            }
        }
        .fullScreenCover(item: $presentation) { MermaidViewer(presentation: $0) }
    }
}

private struct MermaidPresentation: Identifiable {
    let id = UUID()
    let svg: String
    let dark: Bool
}

private struct MermaidViewer: View {
    let presentation: MermaidPresentation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            MermaidVectorView(svg: presentation.svg, dark: presentation.dark)
                .navigationTitle("Diagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Only the sanitized SVG is loaded here: no Mermaid engine or source text.
struct MermaidVectorView: UIViewRepresentable {
    let svg: String
    let dark: Bool
    func makeCoordinator() -> MermaidNavigationPolicy { MermaidNavigationPolicy() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = dark ? .black : .white
        view.loadHTMLString(MermaidDocument.html(body: "<main>\(svg)</main>", dark: dark, zoom: true), baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
