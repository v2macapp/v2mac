import Foundation
import Testing

@Suite struct CLIProtocolTests {
    @Test func responseEnvelopeKeepsV1Fields() throws {
        let response = CLIWireResponse(ok: false, command: "rules apply", revision: "abc", data: nil,
                                       warnings: ["skipped"], error: .init(id: "conflict", message: "stale", exitCode: EX_TEMPFAIL), appHash: "def")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(object["apiVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == false)
        #expect(object["command"] as? String == "rules apply")
        #expect(object["revision"] as? String == "abc")
        #expect(object["warnings"] != nil)
        #expect(object["error"] != nil)
    }

    @Test func developmentEndpointCannotReachProduction() {
        #if DEBUG
        #expect(V2MacCLIIdentity.endpointName.contains("dev"))
        #expect(V2MacCLIIdentity.dataFolder == "v2mac-dev")
        #else
        #expect(!V2MacCLIIdentity.endpointName.contains("dev"))
        #expect(V2MacCLIIdentity.dataFolder == "v2mac")
        #endif
    }

    @Test func socketCarriesAWholeMessageUntilEOF() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let message = Data((0..<300_000).map { UInt8($0 & 0xff) }) // bigger than one read and the socket buffer
        let writer = Thread { _ = CLISocket.writeAll(fds[0], message); shutdown(fds[0], SHUT_WR) }
        writer.start()
        #expect(CLISocket.readAll(fds[1]) == message)
    }
}
