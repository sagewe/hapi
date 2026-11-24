import Foundation
import Testing
@testable import HapiClient

@Suite("Case files and safe ZIP") struct SafeZIPTests {
    @Test func roundTripMultipleDocumentsAndDuplicateNames() throws {
        let zip = try SafeZIP(data: SafeZIP.pack([(name: "报告.pdf", data: Data("report".utf8)), (name: "报告.pdf", data: Data("evidence".utf8)), (name: "表格.csv", data: Data("a,b\n1,2".utf8))]))
        #expect(zip.entries.map(\.fileName) == ["报告.pdf", "报告 (2).pdf", "表格.csv"])
        #expect(try zip.extract(zip.entries[0]) == Data("report".utf8))
        #expect(try zip.extract(zip.entries[1]) == Data("evidence".utf8))
    }
    @Test func rejectsAllTraversalForms() throws {
        for name in ["../x", "/x", "dir/../../x", "C:/x", "a\\..\\b", "null\0x", "a/.."] {
            #expect(throws: SafeZIPError.unsafePath) { try SafeZIP.validatePath(name) }
        }
        let original = try SafeZIP.pack([(name: "safe.pdf", data: Data("x".utf8))])
        var changed = original
        let unsafe = Array("../x.pdf".utf8)
        changed.replaceSubrange(30..<38, with: unsafe)
        let central = changed.range(of: Data([0x50,0x4b,0x01,0x02]))!.lowerBound
        changed.replaceSubrange(central + 46..<central + 54, with: unsafe)
        #expect(throws: SafeZIPError.unsafePath) { try SafeZIP(data: changed) }
    }
    @Test func rejectsEncryptionSymlinksAndBombsBeforeExtraction() throws {
        let original = try SafeZIP.pack([(name: "x.pdf", data: Data("x".utf8))])
        let central = original.range(of: Data([0x50,0x4b,0x01,0x02]))!.lowerBound
        var encrypted = original; encrypted[central + 8] |= 1
        #expect(throws: SafeZIPError.encrypted) { try SafeZIP(data: encrypted) }
        var link = original; link[central + 41] = 0xa0
        #expect(throws: SafeZIPError.unsafePath) { try SafeZIP(data: link) }
        var bomb = original; bomb[central + 24] = 0xff; bomb[central + 25] = 0xff
        #expect(throws: SafeZIPError.tooLarge) { try SafeZIP(data: bomb) }
    }
    @Test func filtersMacNoiseAndDetectsCorruption() throws {
        let original = try SafeZIP.pack([(name: "x.pdf", data: Data("x".utf8)), (name: ".DS_Store", data: Data())])
        let zip = try SafeZIP(data: original); #expect(zip.entries.count == 1)
        var corrupt = original; corrupt[35] = 42
        let bad = try SafeZIP(data: corrupt)
        #expect(throws: SafeZIPError.checksum) { try bad.extract(bad.entries[0]) }
        #expect(throws: (any Error).self) { try SafeZIP(data: Data(original.dropLast())) }
    }
    @Test func readsDeflatedZIPFromStandardTools() throws {
        // Python zipfile, DEFLATED, one UTF-8 filename; raw DEFLATE via zlib.
        let data = Data(base64Encoded: "UEsDBBQAAAAIAPRUeF2GphA2BwAAAAUAAAAFAAAAeC50eHTLSM3JyQcAUEsBAhQDFAAAAAgA9FR4XYamEDYHAAAABQAAAAUAAAAAAAAAAAAAAIABAAAAAHgudHh0UEsFBgAAAAABAAEAMwAAACoAAAAAAA==")!
        let zip = try SafeZIP(data: data)
        #expect(try zip.extract(zip.entries[0]) == Data("hello".utf8))
    }
    @Test func decodesDurableIndexAndDerivesAuthenticatedDownloadRoute() async throws {
        let harness = try makeHarness(jwt: freshJWT())
        await harness.performer.enqueue(json: """
        {"files":[{"id":"u1","category":"uploads","fileName":"原件.zip","mimeType":"application/zip","size":4,"createdAt":1795487400000,"downloadPath":"https://untrusted.invalid/x"}]}
        """)
        let files = try await harness.client.caseFiles(sessionId: "case1")
        #expect(files.count == 1); #expect(files[0].isUpload); #expect(files[0].isZIP)
        await harness.performer.enqueue(json: "data")
        _ = try await harness.client.caseFileBytes(sessionId: "case1", file: files[0])
        let requests = await harness.performer.requests
        #expect(requests.last?.url?.path == "/api/sessions/case1/uploads/u1")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }
}
