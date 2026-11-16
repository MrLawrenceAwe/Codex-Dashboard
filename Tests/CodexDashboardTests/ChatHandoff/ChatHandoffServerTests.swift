import XCTest
import Foundation
@testable import CodexDashboard

@MainActor
final class ChatHandoffServerTests: XCTestCase {
    private final class Client {
        let socket: URLSessionWebSocketTask
        var nextID = 0
        let binary: Bool
        var notifications: [String] = []
        var approvals = 0
        init(_ endpoint: ChatHandoffServer.Endpoint, binary: Bool = false) {
            self.binary = binary
            var components = URLComponents(string: endpoint.url)!
            let secret = components.password!
            components.user = nil; components.password = nil
            var request = URLRequest(url: components.url!)
            request.setValue("Basic " + Data("dashboard:\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()
        }
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            try await socket.send(binary ? .data(data) : .string(String(decoding: data, as: UTF8.self)))
            while true {
                let message = try await socket.receive()
                let raw: Data
                switch message { case .string(let text): raw = Data(text.utf8); case .data(let data): raw = data; @unknown default: continue }
                let object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
                if let method = object["method"] as? String {
                    notifications.append(method)
                    if method == "item/commandExecution/requestApproval", let approvalID = object["id"] as? String {
                        approvals += 1
                        let response = try JSONSerialization.data(withJSONObject: ["id": approvalID, "result": ["decision": "accept"]])
                        try await socket.send(.data(response))
                    }
                }
                if (object["id"] as? Int) == id { return object }
            }
        }
    }

    func testRoutesAccountsWithoutOverlappingWritersOrReplayingRejectedTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-test-\(UUID())")
        let history = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("codex")
        try Self.fakeServer.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        var windows: [ChatHandoffServer.Window] = []
        for name in ["A", "B"] {
            let home = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let claims = Data("{\"email\":\"\(name)@example.test\",\"https://api.openai.com/auth\":{\"chatgpt_plan_type\":\"plus\"}}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let credential: [String: Any] = ["tokens": ["account_id": name, "id_token": "e30.\(claims).test", "access_token": "test"]]
            try JSONSerialization.data(withJSONObject: credential).write(to: home.appendingPathComponent("auth.json"))
            windows.append(.init(id: name == "A" ? "main" : name, home: home, accountIdentifier: name, token: UUID().uuidString))
        }
        let server = ChatHandoffServer(configuration: .init(root: root.appendingPathComponent("broker"), historyHome: history, executable: fake, windows: windows))
        defer { Task { try? await server.shutdown(); try? FileManager.default.removeItem(at: root) } }
        let endpoints = try await server.start()
        let a = Client(endpoints[0]), b = Client(endpoints[1], binary: true)
        defer { a.socket.cancel(); b.socket.cancel() }
        _ = try await a.call("initialize")
        _ = try await b.call("initialize")
        let first = try await a.call("turn/start", ["threadId": "same"])
        XCTAssertNil(first["error"])
        let accountA = (first["result"] as? [String: Any])?["account"] as? String
        XCTAssertEqual(accountA, "A")
        let overlap = try await b.call("turn/start", ["threadId": "same"])
        XCTAssertNotNil(overlap["error"])
        let steer = try await b.call("turn/steer", ["threadId": "same"])
        XCTAssertNotNil(steer["error"])
        let read = try await b.call("thread/read", ["threadId": "same"])
        XCTAssertNil(read["error"])
        let settings = try await b.call("configRequirements/read")
        XCTAssertNil(settings["error"])
        let write = try await b.call("config/batchWrite")
        XCTAssertNotNil(write["error"])
        _ = try await a.call("turn/interrupt", ["threadId": "same", "turnId": "A"])
        let second = try await b.call("turn/start", ["threadId": "same"])
        XCTAssertEqual((second["result"] as? [String: Any])?["account"] as? String, "B")
        _ = try await b.call("turn/interrupt", ["threadId": "same", "turnId": "B"])
        let aFile = windows[0].home.appendingPathComponent("auth.json")
        let originalA = try Data(contentsOf: aFile)
        try Data(contentsOf: windows[1].home.appendingPathComponent("auth.json")).write(to: aFile)
        let invalid = try await a.call("turn/start", ["threadId": "same"])
        XCTAssertNotNil(invalid["error"], "A mismatched credential must not start a turn")
        try originalA.write(to: aFile)
        let third = try await a.call("turn/start", ["threadId": "same"])
        XCTAssertEqual((third["result"] as? [String: Any])?["account"] as? String, "A")
        _ = try await a.call("turn/interrupt", ["threadId": "same", "turnId": "A"])
        XCTAssertFalse(a.notifications.contains("account/updated"))
        XCTAssertFalse(b.notifications.contains("account/updated"))

        // Reopen the main window on the same endpoint using saved account B.
        // Old connections stay bound to A and cannot act with B's credentials.
        let bCredential = try Data(contentsOf: windows[1].home.appendingPathComponent("auth.json"))
        try bCredential.write(to: aFile, options: .atomic)
        let stale = try await a.call("turn/start", ["threadId": "same"])
        XCTAssertNotNil(stale["error"])
        let switched = Client(endpoints[0])
        defer { switched.socket.cancel() }
        let initialized = try await switched.call("initialize")
        XCTAssertNil(initialized["error"])
        let switchedTurn = try await switched.call("turn/start", ["threadId": "same"])
        XCTAssertEqual((switchedTurn["result"] as? [String: Any])?["account"] as? String, "B")
        _ = try await switched.call("turn/interrupt", ["threadId": "same", "turnId": "B"])
        let separateTurn = try await b.call("turn/start", ["threadId": "same"])
        XCTAssertEqual((separateTurn["result"] as? [String: Any])?["account"] as? String, "B")
        _ = try await b.call("turn/interrupt", ["threadId": "same", "turnId": "B"])
        // A second broker cannot acquire the same history while its owner lives.
        let duplicate = ChatHandoffServer(configuration: server.configuration)
        do { _ = try await duplicate.start(); XCTFail("Two owners were admitted") } catch {}
        try await server.shutdown()
        let events = try String(contentsOf: history.appendingPathComponent("writers"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(events, ["A", "B", "A", "B", "B"], "Only admitted turns reached the writer")
        XCTAssertEqual(a.approvals, 2)
        XCTAssertEqual(b.approvals, 2)
        XCTAssertEqual(switched.approvals, 1)
        let approvals = try String(contentsOf: history.appendingPathComponent("approvals"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(approvals, ["A", "B", "A", "B", "B"], "Approvals are routed back with the original server IDs")
    }

    private static let fakeServer = #"""
#!/usr/bin/env python3
import os,json,sys,pathlib,uuid
home=pathlib.Path(os.environ['CODEX_HOME'])
account=json.loads((home/'auth.json').read_text())['tokens']['account_id']
history=pathlib.Path(os.environ['CODEX_SQLITE_HOME'])
def send(obj): print(json.dumps(obj),flush=True)
for line in sys.stdin:
 r=json.loads(line);m=r.get('method');i=r.get('id');result={}
 if m is None and r.get('result',{}).get('decision')=='accept':
  assert i==1
  with (history/'approvals').open('a') as f:f.write(account+'\n')
  continue
 if m=='initialize':
  send({'method':'account/updated','params':{'accountId':account}})
  result={'userAgent':'fake'}
 elif m in ['thread/resume','thread/read']:result={'thread':{'id':'same','turns':[]}}
 elif m=='turn/start':
  with (history/'writers').open('a') as f:f.write(account+'\n')
  active=str(uuid.uuid4())
  send({'method':'turn/started','params':{'turn':{'id':active}}})
  send({'id':1,'method':'item/commandExecution/requestApproval','params':{'threadId':'same','turnId':active}})
  result={'turn':{'id':active},'account':account}
 elif m=='turn/interrupt': send({'method':'turn/completed','params':{'turn':{'id':active}}})
 if i is not None:send({'id':i,'result':result})
"""#
}
