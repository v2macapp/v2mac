import Foundation
import Testing

/// Scripts/check-tun.sh must never pass when tcpdump measured nothing (review F06, from its
/// reproduce_checks.py). Every command it could reach is a harmless stub: no real sudo, capture or network.
@Suite struct CheckTunScriptTests {
    static let script = TestSupport.vendorCore.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/check-tun.sh").path

    func run(tcpdump: String) throws -> Int32 {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stubs = [
            "tcpdump": tcpdump,
            // Only these harmless forms; never forward anything else.
            "sudo": #"case "$1" in -v) exit 0;; tcpdump) shift; exec tcpdump "$@";; kill) exit 0;; *) exit 99;; esac"#,
            "scutil": #"if [ "$1" = --dns ]; then printf 'resolver #1\n  nameserver[0] : 1.1.1.1\n'; else echo 'PrimaryInterface : en-test'; fi"#,
            "route": "echo 'interface: utun999'",
            "dig": "exit 0", "dscacheutil": "exit 0", "curl": "echo ip=203.0.113.25",
            "uuidgen": "echo 12345678-1234-1234-1234-123456789abc",
        ]
        for (name, body) in stubs {
            let file = dir.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [Self.script]
        p.environment = ["PATH": "\(dir.path):/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func failingTcpdumpIsInconclusive() throws {
        #expect(try run(tcpdump: "echo 'intentional test capture failure' >&2; exit 1") == 2)
    }

    @Test func emptyCaptureIsInconclusive() throws {
        #expect(try run(tcpdump: "exec sleep 3") == 2)
    }
}
