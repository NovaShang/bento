import XCTest

@testable import ACPKit

/// Fixtures below are captured from a live `opencode acp` session
/// (OpenRouter GLM 5.2, 2026-07-19) plus spec examples — decoding must be
/// lenient to extra fields and unknown discriminators.
final class SchemaCodableTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testInitializeResponseWithExtraFields() throws {
        let json = """
            {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"mcpCapabilities":{"http":true,"sse":true},"promptCapabilities":{"embeddedContext":true,"image":true},"sessionCapabilities":{"close":{},"fork":{},"list":{},"resume":{}}},"authMethods":[{"description":"Run `opencode auth login`","name":"Login with opencode","id":"opencode-login"}],"agentInfo":{"name":"OpenCode","version":"1.18.3"}}
            """
        let resp = try decoder.decode(InitializeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.protocolVersion, 1)
        XCTAssertEqual(resp.agentCapabilities?.loadSession, true)
        XCTAssertEqual(resp.agentCapabilities?.promptCapabilities?.image, true)
        XCTAssertNil(resp.agentCapabilities?.promptCapabilities?.audio)
        XCTAssertEqual(resp.authMethods?.first?.id, "opencode-login")
        XCTAssertEqual(resp.agentInfo?.name, "OpenCode")
    }

    func testAgentMessageChunk() throws {
        let json = """
            {"sessionId":"ses_1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"PONG"}}}
            """
        let note = try decoder.decode(SessionNotification.self, from: Data(json.utf8))
        guard case .agentMessageChunk(let block) = note.update else {
            return XCTFail("wrong case: \(note.update)")
        }
        XCTAssertEqual(block.textValue, "PONG")
    }

    func testUnknownUpdatePreserved() throws {
        let json = """
            {"sessionId":"ses_1","update":{"sessionUpdate":"usage_update","used":13543,"size":1048576,"cost":{"amount":0.0013,"currency":"USD"}}}
            """
        let note = try decoder.decode(SessionNotification.self, from: Data(json.utf8))
        guard case .unknown(let type, let payload) = note.update else {
            return XCTFail("wrong case: \(note.update)")
        }
        XCTAssertEqual(type, "usage_update")
        XCTAssertEqual(payload["used"]?.intValue, 13543)
        XCTAssertEqual(payload["cost"]?["currency"]?.stringValue, "USD")
    }

    func testToolCallWithDiffContent() throws {
        let json = """
            {"sessionId":"ses_1","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"Edit main.swift","kind":"edit","status":"in_progress","content":[{"type":"diff","path":"/tmp/main.swift","oldText":"let a = 1","newText":"let a = 2"}],"locations":[{"path":"/tmp/main.swift","line":10}],"rawInput":{"foo":"bar"}}}
            """
        let note = try decoder.decode(SessionNotification.self, from: Data(json.utf8))
        guard case .toolCall(let call) = note.update else {
            return XCTFail("wrong case: \(note.update)")
        }
        XCTAssertEqual(call.toolCallId, "call_1")
        XCTAssertEqual(call.kind, .edit)
        XCTAssertEqual(call.status, .inProgress)
        XCTAssertEqual(call.locations?.first?.line, 10)
        guard case .diff(let path, let oldText, let newText) = call.content?.first else {
            return XCTFail("expected diff")
        }
        XCTAssertEqual(path, "/tmp/main.swift")
        XCTAssertEqual(oldText, "let a = 1")
        XCTAssertEqual(newText, "let a = 2")
        XCTAssertEqual(call.rawInput?["foo"]?.stringValue, "bar")
    }

    func testSubagentToolCallCarriesParentToolUseId() throws {
        // A subagent's tool call: the adapter stamps the spawning Task/Agent
        // call's id under `_meta.claudeCode.parentToolUseId`. This is the only
        // on-wire attribution, so it must survive decoding.
        let json = """
            {"sessionId":"ses_1","update":{"sessionUpdate":"tool_call","toolCallId":"child_1","title":"Read foo.swift","kind":"read","status":"in_progress","_meta":{"claudeCode":{"parentToolUseId":"task_42"}}}}
            """
        let note = try decoder.decode(SessionNotification.self, from: Data(json.utf8))
        guard case .toolCall(let call) = note.update else {
            return XCTFail("wrong case: \(note.update)")
        }
        XCTAssertEqual(call.parentToolUseId, "task_42")
    }

    func testMainAgentToolCallHasNoParent() throws {
        let json = """
            {"toolCallId":"c","kind":"read"}
            """
        let call = try decoder.decode(ToolCallUpdate.self, from: Data(json.utf8))
        XCTAssertNil(call.parentToolUseId)
    }

    func testUnknownToolKindAndStatusFallBack() throws {
        let json = """
            {"toolCallId":"c","kind":"telepathy","status":"quantum"}
            """
        let call = try decoder.decode(ToolCallUpdate.self, from: Data(json.utf8))
        XCTAssertEqual(call.kind, .other)
        XCTAssertEqual(call.status, .pending)
    }

    func testPlanUpdate() throws {
        let json = """
            {"sessionId":"s","update":{"sessionUpdate":"plan","entries":[{"content":"Check tests","priority":"high","status":"in_progress"}]}}
            """
        let note = try decoder.decode(SessionNotification.self, from: Data(json.utf8))
        guard case .plan(let entries) = note.update else { return XCTFail() }
        XCTAssertEqual(entries.first?.status, .inProgress)
        XCTAssertEqual(entries.first?.priority, .high)
    }

    func testPermissionRequestRoundTrip() throws {
        let json = """
            {"sessionId":"s","toolCall":{"toolCallId":"c1","title":"Run ls","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}
            """
        let req = try decoder.decode(RequestPermissionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.options.count, 2)
        XCTAssertEqual(req.options[0].kind, .allowOnce)

        let selected = RequestPermissionResponse(outcome: .selected(optionId: "allow"))
        let data = try encoder.encode(selected)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let outcome = obj["outcome"] as! [String: Any]
        XCTAssertEqual(outcome["outcome"] as? String, "selected")
        XCTAssertEqual(outcome["optionId"] as? String, "allow")

        let cancelled = try encoder.encode(RequestPermissionResponse(outcome: .cancelled))
        let cobj = try JSONSerialization.jsonObject(with: cancelled) as! [String: Any]
        XCTAssertEqual((cobj["outcome"] as! [String: Any])["outcome"] as? String, "cancelled")
    }

    func testPromptRequestEncoding() throws {
        let req = PromptRequest(sessionId: "s1", prompt: [.text("hello")])
        let data = try encoder.encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["sessionId"] as? String, "s1")
        let prompt = obj["prompt"] as! [[String: Any]]
        XCTAssertEqual(prompt[0]["type"] as? String, "text")
        XCTAssertEqual(prompt[0]["text"] as? String, "hello")
    }

    func testStopReasonFallback() throws {
        XCTAssertEqual(
            try decoder.decode(PromptResponse.self, from: Data(#"{"stopReason":"cancelled"}"#.utf8)).stopReason,
            .cancelled)
        XCTAssertEqual(
            try decoder.decode(PromptResponse.self, from: Data(#"{"stopReason":"weird_new"}"#.utf8)).stopReason,
            .endTurn)
    }

    func testMcpServerEncoding() throws {
        let stdio = McpServer.stdio(name: "fs", command: "mcp-fs", args: ["--root", "/tmp"], env: [])
        let obj = try JSONSerialization.jsonObject(with: encoder.encode(stdio)) as! [String: Any]
        XCTAssertNil(obj["type"])  // stdio has no discriminator in v1
        XCTAssertEqual(obj["command"] as? String, "mcp-fs")

        let http = McpServer.http(name: "web", url: "https://x", headers: [])
        let hobj = try JSONSerialization.jsonObject(with: encoder.encode(http)) as! [String: Any]
        XCTAssertEqual(hobj["type"] as? String, "http")
    }

    func testClientCapabilitiesAdvertiseElicitationForm() throws {
        let caps = ClientCapabilities(
            fs: FileSystemCapability(readTextFile: false, writeTextFile: false),
            terminal: false,
            elicitation: ElicitationCapability(form: .init()))
        let obj = try JSONSerialization.jsonObject(with: encoder.encode(caps)) as! [String: Any]
        let elicitation = obj["elicitation"] as! [String: Any]
        // `{}` under `form` is the SDK's "supported" marker.
        XCTAssertNotNil(elicitation["form"] as? [String: Any])
        XCTAssertNil(elicitation["url"])
    }

    func testElicitationFormParsesAskUserQuestionShape() throws {
        // The exact shape claude-agent-acp emits for a single multiple-choice
        // question plus its free-text "Other" companion.
        let json = #"""
        {
          "mode": "form",
          "sessionId": "ses_1",
          "toolCallId": "toolu_1",
          "message": "Which approach should we take?",
          "requestedSchema": {
            "type": "object",
            "properties": {
              "question_0": {
                "type": "string",
                "title": "Approach",
                "oneOf": [
                  {"const": "Fast", "title": "Fast", "description": "Ship now",
                   "_meta": {"_claude/askUserQuestionOption": {"preview": "diff --git a b"}}},
                  {"const": "Careful", "title": "Careful"}
                ]
              },
              "question_0_custom": {
                "type": "string", "title": "Other",
                "description": "Type your own answer instead of choosing an option above (optional)."
              }
            }
          }
        }
        """#
        let request = try decoder.decode(CreateElicitationRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.mode, "form")
        XCTAssertEqual(request.toolCallId, "toolu_1")

        let form = try XCTUnwrap(ElicitationForm(requestedSchema: request.requestedSchema))
        XCTAssertEqual(form.fields.count, 2)
        XCTAssertEqual(form.fields[0].key, "question_0")
        guard case .select(let options) = form.fields[0].kind else { return XCTFail() }
        XCTAssertEqual(options.map(\.value), ["Fast", "Careful"])
        XCTAssertEqual(options[0].detail, "Ship now")
        XCTAssertEqual(options[0].preview, "diff --git a b")
        XCTAssertTrue(form.fields[1].isCustomCompanion)
        guard case .text = form.fields[1].kind else { return XCTFail() }
    }

    func testElicitationFormMultiSelectAndOrdering() throws {
        let json = #"""
        {
          "type": "object",
          "properties": {
            "question_1": {"type": "array", "title": "Extras",
                           "items": {"anyOf": [{"const": "A"}, {"const": "B"}]}},
            "question_0": {"type": "string", "oneOf": [{"const": "X"}]},
            "question_10": {"type": "boolean", "title": "Confirm"}
          }
        }
        """#
        let schema = try decoder.decode(JSONValue.self, from: Data(json.utf8))
        let form = try XCTUnwrap(ElicitationForm(requestedSchema: schema))
        // Natural sort: question_0 < question_1 < question_10.
        XCTAssertEqual(form.fields.map(\.key), ["question_0", "question_1", "question_10"])
        guard case .multiSelect(let extras) = form.fields[1].kind else { return XCTFail() }
        XCTAssertEqual(extras.map(\.value), ["A", "B"])
        guard case .boolean = form.fields[2].kind else { return XCTFail() }
    }

    func testCreateElicitationResponseEncoding() throws {
        let accept = CreateElicitationResponse.accept([
            "question_0": .string("Fast"), "picks": .array([.string("A"), .string("B")]),
        ])
        let obj = try JSONSerialization.jsonObject(with: encoder.encode(accept)) as! [String: Any]
        XCTAssertEqual(obj["action"] as? String, "accept")
        let content = obj["content"] as! [String: Any]
        XCTAssertEqual(content["question_0"] as? String, "Fast")
        XCTAssertEqual(content["picks"] as? [String], ["A", "B"])

        let cancel = try JSONSerialization.jsonObject(
            with: encoder.encode(CreateElicitationResponse.cancel)) as! [String: Any]
        XCTAssertEqual(cancel["action"] as? String, "cancel")
        XCTAssertNil(cancel["content"])
    }

    func testUnknownContentBlockPreserved() throws {
        let json = #"{"type":"video","url":"https://x/v.mp4"}"#
        let block = try decoder.decode(ContentBlock.self, from: Data(json.utf8))
        guard case .unknown(let type, let payload) = block else { return XCTFail() }
        XCTAssertEqual(type, "video")
        XCTAssertEqual(payload["url"]?.stringValue, "https://x/v.mp4")
        // Round-trips verbatim.
        let re = try encoder.encode(block)
        let obj = try JSONSerialization.jsonObject(with: re) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "video")
    }
}
