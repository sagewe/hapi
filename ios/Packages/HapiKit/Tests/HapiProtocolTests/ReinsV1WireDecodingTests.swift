import Foundation
import Testing
@testable import HapiProtocol

@Suite("Reins Native v1 wire decoding")
struct ReinsV1WireDecodingTests {

    @Test func decodesV1AuthResponse() throws {
        let json = """
        {"token":"jwt-v1","namespace":"default","is_owner":true}
        """
        let decoded = try JSONDecoder().decode(AuthResponse.self, from: Data(json.utf8))
        #expect(decoded.token == "jwt-v1")
        #expect(decoded.namespace == "default")
        #expect(decoded.isOwner == true)
        #expect(decoded.user == nil)
    }

    @Test func decodesV1SessionAndSessionSummary() throws {
        let json = """
        {
          "id": "sess-v1",
          "namespace": "default",
          "machine_id": "mach-1",
          "agent": "claude",
          "directory": "/Users/sage/myhome",
          "title": "Reins Migration",
          "title_locked": true,
          "prompt_title": "Migrate iOS",
          "model": "opus",
          "effort": "high",
          "permission_mode": "yolo",
          "status": "thinking",
          "pinned": false,
          "pin_mode": "global",
          "archived": false,
          "meta_rev": 7,
          "state_rev": 3,
          "message_epoch": 1,
          "content_rev": 12,
          "read_rev": 10,
          "read_state_ver": 4,
          "manual_unread": false,
          "pending_requests": {
            "requests": {
              "req-1": { "tool": "Bash", "createdAt": 1700000001000 }
            }
          },
          "metadata": { "host": "mac-studio", "tags": ["ios", "v1"] },
          "created_at": 1700000000000,
          "updated_at": 1700000005000,
          "seq": 9,
          "message_count": 4,
          "last_preview": "All tests pass"
        }
        """
        let data = Data(json.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        #expect(session.id == "sess-v1")
        #expect(session.namespace == "default")
        #expect(session.active == true)
        #expect(session.thinking == true)
        #expect(session.globalPinned == true)
        #expect(session.pinned == false)
        #expect(session.metadataVersion == 7)
        #expect(session.agentStateVersion == 3)
        #expect(session.contentRevision == 12)
        #expect(session.readState == SessionReadState(readRevision: 10, manualUnread: false, version: 4))
        #expect(session.hasConversationContent == true)
        #expect(session.permissionMode == .yolo)
        #expect(session.metadata?.name == "Reins Migration")
        #expect(session.metadata?.path == "/Users/sage/myhome")
        #expect(session.metadata?.machineId == "mach-1")
        #expect(session.metadata?.flavor == "claude")
        #expect(session.metadata?.tags == ["ios", "v1"])
        #expect(session.agentState?.requests?["req-1"]?.tool == "Bash")

        let summary = try JSONDecoder().decode(SessionSummary.self, from: data)
        #expect(summary.id == "sess-v1")
        #expect(summary.pendingRequestsCount == 1)
        #expect(summary.pendingRequestKinds == [.permission])
        #expect(summary.metadata?.name == "Reins Migration")
    }

    @Test func decodesV1Machine() throws {
        let json = """
        {
          "id": "m1",
          "namespace": "default",
          "name": "mac-studio",
          "platform": "darwin",
          "capabilities": ["workspace", "terminal"],
          "active": true,
          "last_seen_at": 1700000000000
        }
        """
        let machine = try JSONDecoder().decode(Machine.self, from: Data(json.utf8))
        #expect(machine.id == "m1")
        #expect(machine.active == true)
        #expect(machine.updatedAt == 1700000000000)
        #expect(machine.metadata?.host == "mac-studio")
        #expect(machine.metadata?.platform == "darwin")
        #expect(machine.metadata?.capabilities == ["workspace", "terminal"])
        #expect(machine.runnerState?.isRunning == true)
    }

    @Test func decodesV1StoredMessagesAndNormalizesThem() throws {
        let userJSON = """
        {
          "id": "u1",
          "session_id": "s1",
          "seq": 1,
          "local_id": "loc-1",
          "role": "user",
          "content_rev": 1,
          "invoked_at": null,
          "delivery_state": "queued",
          "blocks": [
            { "type": "text", "text": "Hello Reins" },
            { "type": "attachment", "id": "a1", "filename": "doc.pdf", "mimeType": "application/pdf", "size": 42, "previewUrl": "/v1/sessions/s1/blobs/a1" }
          ],
          "meta": {},
          "created_at": 1700000000000
        }
        """
        let userMsg = try JSONDecoder().decode(DecryptedMessage.self, from: Data(userJSON.utf8))
        #expect(userMsg.localId == "loc-1")
        #expect(userMsg.invokedAt == nil)
        #expect(userMsg.deliveryState == "queued")
        let normalizedUser = try #require(normalizeDecryptedMessage(userMsg))
        if case .user(let text, let attachments) = normalizedUser.content {
            #expect(text == "Hello Reins")
            #expect(attachments?.count == 1)
            #expect(attachments?[0].filename == "doc.pdf")
        } else {
            Issue.record("Expected user normalized content")
        }

        let assistantJSON = """
        {
          "id": "a1",
          "session_id": "s1",
          "seq": 2,
          "local_id": null,
          "role": "assistant",
          "content_rev": 2,
          "invoked_at": 1700000001000,
          "delivery_state": "invoked",
          "blocks": [
            { "type": "thinking", "thinking": "hmm" },
            { "type": "text", "text": "Done!" }
          ],
          "meta": {},
          "created_at": 1700000001000
        }
        """
        let assistantMsg = try JSONDecoder().decode(DecryptedMessage.self, from: Data(assistantJSON.utf8))
        let normalizedAssistant = try #require(normalizeDecryptedMessage(assistantMsg))
        if case .agent(let blocks) = normalizedAssistant.content {
            #expect(blocks.count == 2)
        } else {
            Issue.record("Expected agent normalized content")
        }

        let mediaJSON = """
        {
          "id": "g1",
          "session_id": "s1",
          "seq": 3,
          "local_id": null,
          "role": "assistant",
          "content_rev": 3,
          "invoked_at": 1700000002000,
          "delivery_state": "invoked",
          "blocks": [
            { "type": "generated_media", "id": "img-9", "filename": "chart.png", "mime_type": "image/png" }
          ],
          "meta": {},
          "created_at": 1700000002000
        }
        """
        let mediaMsg = try JSONDecoder().decode(DecryptedMessage.self, from: Data(mediaJSON.utf8))
        let normalizedMedia = try #require(normalizeDecryptedMessage(mediaMsg))
        if case .agent(let blocks) = normalizedMedia.content,
           case .generatedImage(let img) = blocks.first {
            #expect(img.imageId == "img-9")
            #expect(img.fileName == "chart.png")
        } else {
            Issue.record("Expected generatedImage block")
        }
    }

    @Test func decodesV1MessagesPageContextAndReadState() throws {
        let pageJSON = """
        {
          "messages": [],
          "page": {
            "read_through_revision": 5,
            "content_revision": 8,
            "direction": "latest",
            "limit": 50,
            "epoch": 2,
            "reset": false,
            "next_before_seq": 10,
            "next_before_at": 1700,
            "snapshot_head_seq": 20,
            "snapshot_head_at": 1800,
            "has_more": true
          }
        }
        """
        let pageResp = try JSONDecoder().decode(MessagesResponse.self, from: Data(pageJSON.utf8))
        #expect(pageResp.page.readThroughRevision == 5)
        #expect(pageResp.page.nextBeforeSeq == 10)
        #expect(pageResp.page.snapshotHeadSeq == 20)
        #expect(pageResp.page.hasMore == true)

        let ctxJSON = """
        {
          "messages": [],
          "target_message_id": "m-42",
          "page": { "epoch": 1, "next_before_seq": 3, "has_more": false }
        }
        """
        let ctx = try JSONDecoder().decode(MessageContextResponse.self, from: Data(ctxJSON.utf8))
        #expect(ctx.targetMessageId == "m-42")
        #expect(ctx.page.nextBeforeSeq == 3)

        let rsJSON = """
        {"contentRevision":12,"readRevision":12,"readStateVersion":5,"manualUnread":false}
        """
        let rs = try JSONDecoder().decode(SessionReadStateResponse.self, from: Data(rsJSON.utf8))
        #expect(rs.contentRevision == 12)
        #expect(rs.readState == SessionReadState(readRevision: 12, manualUnread: false, version: 5))
    }

    @Test func decodesV1SystemThinkingOnlyEventWithMetaPreserved() throws {
        let rawJSON = """
        {
          "id": "m-thk",
          "session_id": "s1",
          "seq": 9,
          "role": "system",
          "blocks": [{"type": "text", "text": "模型仅完成思考，未输出正文"}],
          "meta": {
            "source": "thinking_only_response",
            "event": {
              "type": "thinking-only",
              "message": "模型仅完成思考，未输出正文",
              "contextTokens": 167200
            }
          },
          "created_at": 1700000000900
        }
        """
        let msg = try JSONDecoder().decode(DecryptedMessage.self, from: Data(rawJSON.utf8))
        let normalized = normalizeDecryptedMessage(msg)
        if case .event(let ev) = normalized?.content {
            #expect(ev.type == "thinking-only")
            #expect(ev["contextTokens"]?.numberValue == 167_200)
        } else {
            Issue.record("Expected structured thinking-only AgentEvent")
        }
    }

    @Test func decodesV1SyncEventsAndSnakeCaseConfigs() throws {
        let connJSON = """
        {"type":"connection_changed","data":{"status":"connected","subscription_id":"sub-1","resume":"ok"}}
        """
        let conn = try JSONDecoder().decode(SyncEvent.self, from: Data(connJSON.utf8))
        if case .connectionChanged(_, let payload) = conn {
            #expect(payload?.subscriptionId == "sub-1")
            #expect(payload?.resume == .ok)
        } else {
            Issue.record("Expected connectionChanged")
        }

        let toastJSON = """
        {"type":"toast","namespace":"default","data":{"title":"Hi","body":"Done","session_id":"s1","url":"/s1"}}
        """
        let toast = try JSONDecoder().decode(SyncEvent.self, from: Data(toastJSON.utf8))
        if case .toast(_, let payload) = toast {
            #expect(payload.sessionId == "s1")
        } else {
            Issue.record("Expected toast")
        }

        let machinePatchJSON = """
        {"type":"machine_updated","namespace":"default","machine_id":"m1","active":false,"updated_at":1234,"machine":null}
        """
        let mp = try JSONDecoder().decode(SyncEvent.self, from: Data(machinePatchJSON.utf8))
        if case .machineUpdated(_, let mid, .patch(let patch)) = mp {
            #expect(mid == "m1")
            #expect(patch.active == false)
            #expect(patch.updatedAt == 1234)
        } else {
            Issue.record("Expected machineUpdated patch")
        }

        let uploadStatus = try JSONDecoder().decode(
            ResumableUploadStatus.self,
            from: Data(#"{"offset":524288,"chunk_size":524288}"#.utf8)
        )
        #expect(uploadStatus.chunkSize == 524288)

        let asrCfg = try JSONDecoder().decode(
            VoiceAsrConfigResponse.self,
            from: Data(#"{"available":true,"ws_url":"wss://hub/v1/voice/asr-ws","sample_rate":16000,"model":"hybrid-qwen3"}"#.utf8)
        )
        #expect(asrCfg.wsUrl == "wss://hub/v1/voice/asr-ws")
        #expect(asrCfg.sampleRate == 16000)

        let agyModels = try JSONDecoder().decode(
            AgentModelsResponse.self,
            from: Data(#"{"success":true,"available_models":[{"modelId":"gemini-2.5-pro"}],"current_model_id":"gemini-2.5-pro"}"#.utf8)
        )
        #expect(agyModels.availableModels?.first?.modelId == "gemini-2.5-pro")
        #expect(agyModels.currentModelId == "gemini-2.5-pro")

        let hubSettings = try JSONDecoder().decode(
            HubSettingsResponse.self,
            from: Data(#"{"client_profile":{"mode":"assistant","appTitle":"MyHome"}}"#.utf8)
        )
        #expect(hubSettings.clientProfile?.mode == .assistant)

        let scratch = try JSONDecoder().decode(
            ScratchlistEntry.self,
            from: Data(#"{"id":"e1","sessionId":"s1","text":"note","attachments":[],"createdAt":1,"updatedAt":2}"#.utf8)
        )
        #expect(scratch.entryId == "e1")
    }

    @Test func regressionAuditFixesDecodeCleanly() throws {
        // 1. System message normalizes to plain text, never raw JSON
        let sysJSON = """
        {
          "id": "sys-1",
          "session_id": "s1",
          "seq": 4,
          "local_id": null,
          "role": "system",
          "content_rev": 4,
          "invoked_at": 1700000003000,
          "delivery_state": "invoked",
          "blocks": [{"type": "text", "text": "Session resumed"}],
          "meta": {},
          "created_at": 1700000003000
        }
        """
        let sysMsg = try JSONDecoder().decode(DecryptedMessage.self, from: Data(sysJSON.utf8))
        let normSys = try #require(normalizeDecryptedMessage(sysMsg))
        if case .agent(let blocks) = normSys.content,
           case .text(let t) = blocks.first {
            #expect(t.text == "Session resumed")
        } else {
            Issue.record("Expected clean text block for system message")
        }

        // 2. Multi-block assistant message preserves generated_media alongside text
        let multiJSON = """
        {
          "id": "a-multi",
          "session_id": "s1",
          "seq": 5,
          "local_id": null,
          "role": "assistant",
          "content_rev": 5,
          "invoked_at": 1700000004000,
          "delivery_state": "invoked",
          "blocks": [
            {"type": "text", "text": "Here is the chart:"},
            {"type": "generated_media", "id": "media-42", "filename": "plot.png", "mime_type": "image/png"}
          ],
          "meta": {},
          "created_at": 1700000004000
        }
        """
        let multiMsg = try JSONDecoder().decode(DecryptedMessage.self, from: Data(multiJSON.utf8))
        let normMulti = try #require(normalizeDecryptedMessage(multiMsg))
        if case .agent(let blocks) = normMulti.content {
            #expect(blocks.count == 2)
            if case .text(let t) = blocks[0] { #expect(t.text == "Here is the chart:") }
            else { Issue.record("Expected text block first") }
            if case .generatedImage(let img) = blocks[1] {
                #expect(img.imageId == "media-42")
                #expect(img.fileName == "plot.png")
            } else {
                Issue.record("Expected generatedImage block second")
            }
        } else {
            Issue.record("Expected agent blocks")
        }

        // 3. session_ended with non-string reason does not throw, and machine_models_updated decodes
        let endedObj = """
        {"type":"session_ended","namespace":"default","session_id":"s1","reason":{"code":0,"detail":"eof"}}
        """
        let endedEvent = try JSONDecoder().decode(SyncEvent.self, from: Data(endedObj.utf8))
        #expect(endedEvent == .sessionEnded(namespace: "default", sessionId: "s1", reason: nil))

        let modelsEvJSON = """
        {"type":"machine_models_updated","namespace":"default","machine_id":"m1","agent":"agy"}
        """
        let modelsEv = try JSONDecoder().decode(SyncEvent.self, from: Data(modelsEvJSON.utf8))
        #expect(modelsEv == .machineModelsUpdated(namespace: "default", machineId: "m1", agent: "agy"))

        // 4. Session v1: last_preview -> summary fallback, effort -> modelReasoningEffort, empty model -> nil
        let sessJSON = """
        {
          "id": "s-empty-model",
          "namespace": "default",
          "machine_id": "m1",
          "agent": "codex",
          "directory": "/repo",
          "title": "Codex Task",
          "title_locked": false,
          "model": "",
          "effort": "high",
          "status": "idle",
          "pinned": false,
          "pin_mode": "none",
          "archived": false,
          "meta_rev": 1,
          "state_rev": 1,
          "content_rev": 2,
          "read_rev": 2,
          "read_state_ver": 1,
          "manual_unread": false,
          "pending_requests": {},
          "metadata": {},
          "created_at": 1700000000000,
          "updated_at": 1700000002000,
          "seq": 1,
          "message_count": 2,
          "last_preview": "Latest preview snippet"
        }
        """
        let sess = try JSONDecoder().decode(Session.self, from: Data(sessJSON.utf8))
        #expect(sess.model == nil)
        #expect(sess.effort == "high")
        #expect(sess.modelReasoningEffort == "high")
        #expect(sess.metadata?.summary?.text == "Latest preview snippet")

        // 5. Standalone QiqiWork URL scheme parses via BindLink
        let qiqiLink = try #require(BindLink.parse("qiqiwork://bind?hub=https%3A%2F%2Fhapi.example.com&code=secret%3Acompliance"))
        #expect(qiqiLink.hubUrl == "https://hapi.example.com")
        #expect(qiqiLink.accessToken == "secret:compliance")
    }
}
