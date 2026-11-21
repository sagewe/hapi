import Foundation
import HapiUI
import Testing

@Suite("MarkdownImagePolicy")
struct MarkdownImagePolicyTests {
    @Test func resolvesRemoteHttpsAndHttpAndProtocolRelativeUrls() {
        #expect(
            MarkdownImagePolicy.resolve(destination: "https://example.com/a.png")
                == .remote(URL(string: "https://example.com/a.png")!)
        )
        #expect(
            MarkdownImagePolicy.resolve(destination: "http://example.com/b.jpg")
                == .remote(URL(string: "http://example.com/b.jpg")!)
        )
        #expect(
            MarkdownImagePolicy.resolve(destination: "//cdn.example.com/c.webp")
                == .remote(URL(string: "https://cdn.example.com/c.webp")!)
        )
    }

    @Test func resolvesWorkspaceRelativeAndAbsoluteAndFileUrlImages() {
        let workspace = "/Users/sage/myhome"
        #expect(
            MarkdownImagePolicy.resolve(destination: "docs/assets/shot.png", workspacePath: workspace)
                == .local(path: "docs/assets/shot.png", mimeType: "image/png")
        )
        #expect(
            MarkdownImagePolicy.resolve(destination: "./shot%201.jpg?v=2#top", currentFilePath: "docs/readme.md", workspacePath: workspace)
                == .local(path: "docs/shot 1.jpg", mimeType: "image/jpeg")
        )
        #expect(
            MarkdownImagePolicy.resolve(destination: "/Users/sage/myhome/docs/shot.webp", workspacePath: workspace)
                == .local(path: "/Users/sage/myhome/docs/shot.webp", mimeType: "image/webp")
        )
        #expect(
            MarkdownImagePolicy.resolve(destination: "file:///Users/sage/myhome/docs/shot.png", workspacePath: workspace)
                == .local(path: "/Users/sage/myhome/docs/shot.png", mimeType: "image/png")
        )
        #expect(
            MarkdownImagePolicy.resolve(destination: "~/myhome/docs/shot.png", workspacePath: workspace)
                == .local(path: "/Users/sage/myhome/docs/shot.png", mimeType: "image/png")
        )
    }

    @Test func rejectsOutsideWorkspaceDeniedSchemesAndNonImages() {
        let workspace = "/Users/sage/myhome"
        #expect(MarkdownImagePolicy.resolve(destination: "/Users/sage/.gemini/brain/x/a.png", workspacePath: workspace) == .inert)
        #expect(MarkdownImagePolicy.resolve(destination: "file:///Users/sage/.gemini/brain/x/a.png", workspacePath: workspace) == .inert)
        #expect(MarkdownImagePolicy.resolve(destination: "../secret.png", workspacePath: workspace) == .inert)
        #expect(MarkdownImagePolicy.resolve(destination: "/Users/sage/myhome/docs/readme.md", workspacePath: workspace) == .inert)
        #expect(MarkdownImagePolicy.resolve(destination: "data:image/png;base64,abc", workspacePath: workspace) == .inert)
        #expect(MarkdownImagePolicy.resolve(destination: "javascript:alert(1)", workspacePath: workspace) == .inert)
        #expect(MarkdownImagePolicy.resolve(destination: "/Users/sage/myhome/docs/shot.png", workspacePath: nil) == .inert)
    }
}
