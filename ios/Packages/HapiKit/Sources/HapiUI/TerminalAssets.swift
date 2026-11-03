import Foundation

public enum TerminalAssets {
    public static func html(hub: URL) throws -> String {
        guard hub.user == nil, hub.password == nil, hub.query == nil, hub.fragment == nil, ["", "/"].contains(hub.path),
              let scheme = hub.scheme, ["https", "http"].contains(scheme), let host = hub.host,
              !host.contains("'"), !host.contains("\""), !host.contains("<") else { throw URLError(.badURL) }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = hub.port.map { ":\($0)" } ?? ""
        let origin = "\(scheme)://\(authority)\(port)"
        let websocket = "\(scheme == "https" ? "wss" : "ws")://\(authority)\(port)"
        guard let js = Bundle.module.url(forResource: "terminal", withExtension: "js", subdirectory: "Terminal"),
              let css = Bundle.module.url(forResource: "terminal", withExtension: "css", subdirectory: "Terminal") else { throw CocoaError(.fileNoSuchFile) }
        let script = try String(contentsOf: js, encoding: .utf8).replacingOccurrences(of: "</script", with: "<\\/script")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src \(origin) \(websocket); img-src data:; font-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(try String(contentsOf: css, encoding: .utf8))
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#101114}#terminal{position:absolute;inset:6px;}</style></head>
        <body><div id="terminal"></div><script>\(script)</script></body></html>
        """
    }
}
