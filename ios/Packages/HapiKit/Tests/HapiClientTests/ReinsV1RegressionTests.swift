import Foundation
import HapiProtocol
import Testing
@testable import HapiClient

@Suite("Reins v1 client regressions")
struct ReinsV1RegressionTests {

    private func makeReinsJWT(sub: String = "reins", ns: String = "default", owner: Bool = true, exp: Int = 2_000_000_000) -> String {
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payloadJSON = #"{"sub":"\#(sub)","ns":"\#(ns)","owner":\#(owner),"iat":1700000000,"exp":\#(exp),"token_hash":"abc"}"#
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }

    @Test func jwtDecodesReinsV1PayloadWithoutUidAndHonorsOwnerGate() {
        let ownerToken = makeReinsJWT(ns: "compliance", owner: true, exp: 1_900_000_000)
        let claims = JWT.claims(from: ownerToken)
        #expect(claims != nil)
        #expect(claims?.uid == 0)
        #expect(claims?.ns == "compliance")
        #expect(claims?.sub == "reins")
        #expect(claims?.owner == true)
        #expect(claims?.exp == 1_900_000_000)
        #expect(OwnerGate.isOwnerNamespace(jwt: ownerToken) == true)

        let guestToken = makeReinsJWT(ns: "compliance", owner: false)
        #expect(JWT.claims(from: guestToken)?.ns == "compliance")
        #expect(OwnerGate.isOwnerNamespace(jwt: guestToken) == false)
    }

    @Test func messageContextReturnsNilOn404() async throws {
        let harness = try makeHarness(jwt: freshJWT())
        await harness.performer.enqueue(status: 404, json: #"{"error":"not_found"}"#)
        let result = try await harness.client.messageContext(sessionId: "s1", messageId: "missing")
        #expect(result == nil)
    }

    @Test func uploadScratchlistAttachmentUsesServerMediaId() async throws {
        let harness = try makeHarness(jwt: freshJWT())
        await harness.performer.enqueue(json: #"{"success":true,"path":"/tmp/a.png","media_id":"med_123"}"#)
        let res = try await harness.client.uploadScratchlistAttachment(
            sessionId: "s1",
            filename: "a.png",
            data: Data([1, 2, 3]),
            mimeType: "image/png"
        )
        #expect(res.success == true)
        #expect(res.attachment?.id == "med_123")
        #expect(res.attachment?.path == "/tmp/a.png")
    }

    @Test func renameSessionSendsEmptyTagsArrayToClearTags() async throws {
        let harness = try makeHarness(jwt: freshJWT())
        await harness.performer.enqueue(json: #"{"session":{"id":"s1"}}"#)
        try await harness.client.renameSession(id: "s1", tags: [])
        let req = try #require(await harness.performer.requests.first)
        #expect(req.httpMethod == "PATCH")
        #expect(req.url?.path == "/v1/sessions/s1")
        let body = req.httpBody.map { String(decoding: $0, as: UTF8.self) }
        #expect(body == #"{"tags":[]}"#)
    }
}
