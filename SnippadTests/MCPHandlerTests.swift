import XCTest
@testable import Snippad

@MainActor
final class MCPHandlerTests: XCTestCase {

    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("MCP-\(UUID().uuidString).snippad")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func call(_ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let response = try XCTUnwrap(MCPHandler.handle(request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func tool(_ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let result = try XCTUnwrap(try call("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), result["isError"] as? Bool ?? false)
    }

    func testInitializeAndList() throws {
        let initResult = try XCTUnwrap(try call("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2025-06-18")
        let tools = try XCTUnwrap((try call("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["clipboard_read", "clipboard_write", "history_list", "history_get",
                                            "snippad_read", "snippad_write", "snippad_copy",
                                            "history_update_text", "history_move", "history_copy_files",
                                            "history_copy_file_contents", "lists_get", "apps_list"]))
        XCTAssertEqual(names.count, tools.count, "tool names are unique")
    }

    func testNotificationsGetNoAnswer() throws {
        let note = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(MCPHandler.handle(note))
    }

    func testUnknownMethodAndTool() throws {
        XCTAssertEqual((try call("nope")["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((try call("tools/call", ["name": "nope"])["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testSnippadFileTools() throws {
        let path = file.path
        var r = try tool("snippad_write", ["path": path, "snippets": [
            ["name": "user", "value": "me", "next": "pw"],
            ["name": "pw", "value": "secret", "once": true, "expires": "5m"],
        ]])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(try SnippadParser.parse(String(contentsOf: file, encoding: .utf8)), [
            Snippet(id: 0, name: "user", value: "me", next: "pw"),
            Snippet(id: 1, name: "pw", value: "secret", expires: 300, once: true),
        ])

        r = try tool("snippad_set_snippet", ["path": path, "name": "pw", "new_name": "password", "expires": 0])
        XCTAssertFalse(r.isError, r.text)
        var snippets = try SnippadParser.parse(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(snippets[0].next, "password", "the chain follows the rename")
        XCTAssertNil(snippets[1].expires)

        r = try tool("snippad_delete_snippet", ["path": path, "name": "password"])
        XCTAssertFalse(r.isError, r.text)
        snippets = try SnippadParser.parse(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(snippets, [Snippet(id: 0, name: "user", value: "me")])

        r = try tool("snippad_read", ["path": path])
        XCTAssertTrue(r.text.contains("\"user\""))
    }

    func testPasswordsAreMaskedAndKept() throws {
        var r = try tool("snippad_write", ["path": file.path, "snippets": [["name": "pw", "value": "hunter2", "password": true]]])
        XCTAssertFalse(r.isError, r.text)
        r = try tool("snippad_read", ["path": file.path])
        XCTAssertFalse(r.text.contains("hunter2"))
        XCTAssertTrue(r.text.contains("••••••••"))
        // Writing back what was read keeps the password.
        r = try tool("snippad_write", ["path": file.path, "snippets": [["name": "pw", "value": "••••••••", "password": true],
                                                                        ["name": "x", "value": "y"]]])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(try SnippadParser.parse(String(contentsOf: file, encoding: .utf8))[0].value, "hunter2")
        r = try tool("snippad_set_snippet", ["path": file.path, "name": "pw", "value": "••••••••", "once": true])
        XCTAssertEqual(try SnippadParser.parse(String(contentsOf: file, encoding: .utf8))[0],
                       Snippet(id: 0, name: "pw", value: "hunter2", once: true, password: true))
    }

    func testToolErrorsAreResults() throws {
        XCTAssertTrue(try tool("snippad_read", ["path": "/tmp/not-a-snippad.txt"]).isError)
        XCTAssertTrue(try tool("snippad_write", ["path": file.path, "snippets": [["name": "a", "value": "b", "next": "x"]]]).isError)
        XCTAssertTrue(try tool("history_get", ["id": "nope"]).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a rejected write leaves no file")
    }
}
