#if canImport(UIKit) && canImport(WebKit)
import CryptoKit
import UIKit
import WebKit

struct MermaidRenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One offline render at a time, shared by all transcript cells. Cells retain
/// only a bitmap; the transient web process is released after each render.
@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()
    static let maxSourceLength = 20_000
    private let cache = NSCache<NSString, MermaidPreview>()
    @MainActor private final class Job {
        let task: Task<MermaidPreview, Error>
        var readers: Set<UUID> = []
        init(_ task: Task<MermaidPreview, Error>) { self.task = task }
    }
    private var jobs: [String: Job] = [:]
    private var tail: Task<Void, Never>?

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 20
    }

    func render(code: String, dark: Bool) async throws -> MermaidPreview {
        try Task.checkCancellation()
        guard code.utf16.count <= Self.maxSourceLength else {
            throw MermaidRenderError(message: String(localized: "Diagram is too large. View the source instead."))
        }
        let key = SHA256.hash(data: Data("11.14.0|\(dark)|\(code)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let result = cache.object(forKey: key as NSString) { return result }
        let entry: Job
        if let existing = jobs[key] {
            entry = existing
        } else {
            guard jobs.count < 8 else {
                throw MermaidRenderError(message: String(localized: "Diagram renderer is busy. Try again."))
            }
            let previous = tail
            let task = Task { @MainActor in
                await previous?.value
                try Task.checkCancellation()
                let operation = MermaidRenderOperation()
                return try await operation.render(code: code, dark: dark)
            }
            entry = Job(task)
            jobs[key] = entry
            tail = Task { _ = await task.result }
        }
        let reader = UUID()
        entry.readers.insert(reader)
        defer { release(key: key, reader: reader, entry: entry) }
        return try await withTaskCancellationHandler {
            let result = try await entry.task.value
            try Task.checkCancellation()
            let cost = (result.image.cgImage?.bytesPerRow ?? 0) * (result.image.cgImage?.height ?? 0)
            cache.setObject(result, forKey: key as NSString, cost: cost)
            return result
        } onCancel: {
            Task { @MainActor in self.release(key: key, reader: reader, entry: entry) }
        }
    }

    private func release(key: String, reader: UUID, entry: Job) {
        guard entry.readers.remove(reader) != nil, entry.readers.isEmpty else { return }
        entry.task.cancel()
        if jobs[key] === entry { jobs.removeValue(forKey: key) }
        if jobs.isEmpty { tail = nil }
    }

}

@MainActor final class MermaidPreview {
    let image: UIImage
    let svg: String
    init(image: UIImage, svg: String) { self.image = image; self.svg = svg }
}

/// Same navigation and resource restrictions for rendering and fullscreen SVG.
@MainActor
final class MermaidNavigationPolicy: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        Self.allows(action.request.url, link: action.navigationType == .linkActivated) ? .allow : .cancel
    }

    static func allows(_ url: URL?, link: Bool) -> Bool {
        !link && url?.absoluteString == "about:blank"
    }
}

@MainActor
final class MermaidRenderOperation: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<MermaidPreview, Error>?
    private var timeout: Task<Void, Never>?
    private var code = ""
    private var dark = false

    func render(code: String, dark: Bool) async throws -> MermaidPreview {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else {
            throw MermaidRenderError(message: String(localized: "Open this conversation to render the diagram."))
        }
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid") else {
            throw MermaidRenderError(message: String(localized: "Offline diagram resources are missing."))
        }
        let library = try String(contentsOf: url, encoding: .utf8)
        self.code = code
        self.dark = dark
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(source: library, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: -2000, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = .clear
        window.addSubview(view)
        webView = view
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                self?.finish(.failure(MermaidRenderError(message: String(localized: "Diagram rendering timed out. View the source instead."))))
            }
            view.loadHTMLString(MermaidDocument.html(body: "<main id='diagram'></main>", dark: dark), baseURL: nil)
          }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        MermaidNavigationPolicy.allows(action.request.url, link: action.navigationType == .linkActivated) ? .allow : .cancel
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        view.callAsyncJavaScript(MermaidDocument.renderScript, arguments: ["source": code, "dark": dark], in: nil, in: .page) { [weak self] result in
            guard let self, self.continuation != nil else { return }
            switch result {
            case .failure(let error):
                let reason = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self.finish(.failure(MermaidRenderError(message: reason ?? error.localizedDescription)))
            case .success(let value):
                guard let svg = value as? String, !svg.isEmpty else {
                    self.finish(.failure(MermaidRenderError(message: String(localized: "Could not render this diagram."))))
                    return
                }
                let snapshot = WKSnapshotConfiguration()
                snapshot.rect = CGRect(x: 0, y: 0, width: 800, height: 600)
                snapshot.snapshotWidth = 400
                view.takeSnapshot(with: snapshot) { [weak self] image, error in
                    guard let self else { return }
                    if let image { self.finish(.success(MermaidPreview(image: image, svg: svg))) }
                    else { self.finish(.failure(error ?? MermaidRenderError(message: String(localized: "Could not create diagram preview.")))) }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(MermaidRenderError(message: String(localized: "Diagram renderer stopped. Try again."))))
    }

    private func finish(_ result: Result<MermaidPreview, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        continuation.resume(with: result)
    }
}

/// No source interpolation into HTML or JavaScript: callAsyncJavaScript passes
/// source as a structured argument. CSP also applies to diagram-generated SVG.
enum MermaidDocument {
    static func html(body: String, dark: Bool, zoom: Bool = false) -> String {
        let background = dark ? "#1c1c1e" : "#ffffff"
        let viewport = zoom ? "width=device-width, initial-scale=1, minimum-scale=0.2, maximum-scale=8, user-scalable=yes" : "width=device-width, initial-scale=1"
        return """
        <!doctype html><html><head><meta name="viewport" content="\(viewport)">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'">
        <style>html,body{margin:0;background:\(background);color:\(dark ? "#edf1f5" : "#2d333b");font-family:-apple-system,sans-serif}
        main{width:100vw;height:100vh;display:flex;align-items:center;justify-content:center}
        main svg{width:100% !important;height:100% !important;max-width:100% !important;max-height:100% !important}</style></head><body>\(body)</body></html>
        """
    }

    static let renderScript = """
    mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,
        maxTextSize:20000,maxEdges:500,fontFamily:'-apple-system, sans-serif',
        secure:['securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering','fontFamily'],
        theme:'base',
        themeVariables: dark ? {
                primaryColor: '#323843',
                primaryTextColor: '#edf1f5',
                primaryBorderColor: '#6d8fd6',
                lineColor: '#94a3b8',
                tertiaryColor: '#2d3440',
                background: '#2a2f35',
                mainBkg: '#323843',
                secondBkg: '#2d3440',
                tertiaryBkg: '#29313b',
                clusterBkg: '#2d3440',
                clusterBorder: '#6d8fd6',
                edgeLabelBackground: '#2a2f35',
                actorBkg: '#323843',
                actorBorder: '#6d8fd6',
                actorTextColor: '#edf1f5',
                signalColor: '#94a3b8',
                labelBoxBkgColor: '#323843',
                labelTextColor: '#edf1f5',
                loopTextColor: '#edf1f5',
                noteBkgColor: '#2d3440',
                noteTextColor: '#edf1f5',
            } : {
                primaryColor: '#f8fbff',
                primaryTextColor: '#2d333b',
                primaryBorderColor: '#b8cdfd',
                lineColor: '#94a3b8',
                tertiaryColor: '#eef4ff',
                background: '#f5f6f7',
                mainBkg: '#f8fbff',
                secondBkg: '#eef4ff',
                tertiaryBkg: '#edf3fb',
                clusterBkg: '#eef4ff',
                clusterBorder: '#b8cdfd',
                edgeLabelBackground: '#f5f6f7',
                actorBkg: '#f8fbff',
                actorBorder: '#b8cdfd',
                actorTextColor: '#2d333b',
                signalColor: '#94a3b8',
                labelBoxBkgColor: '#f8fbff',
                labelTextColor: '#2d333b',
                loopTextColor: '#2d333b',
                noteBkgColor: '#eef4ff',
                noteTextColor: '#2d333b',
            }});
    await mermaid.parse(source);
    const result = await mermaid.render('hapi-diagram',source);
    const host = document.getElementById('diagram');
    host.innerHTML=result.svg;
    await document.fonts.ready;
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    return host.innerHTML;
    """
}
#endif
