import Foundation
import Testing
@testable import V2MacCore

@Suite struct ProblemReportTests {
    @Test func removesWhatIdentifiesTheUser() {
        let log = """
        Fetching https://sub.example.net/api/abc?token=s3cret failed
        vless://11111111-2222-3333-4444-555555555555@edge.example.org:443?pbk=key#Mine
        dial tcp 203.0.113.9:443 and [2001:db8::1]:443 via edge.example.org
        id 11111111-2222-3333-4444-555555555555
        password: hunter2 "publicKey":"abcDEF"
        open /Users/somebody/Library/x failed for me@example.com
        🇫🇷 My Server: timeout
        blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5
        """
        let safe = ProblemReport.redact(log, known: ["🇫🇷 My Server"])
        for leak in ["example", "s3cret", "11111111", "203.0.113.9", "2001:db8", "hunter2", "abcDEF", "somebody", "me@", "My Server", "QUJDREVG"] {
            #expect(!safe.contains(leak), "\(leak) in \(safe)")
        }
    }

    @Test func dropsLinesThatShowBrowsingOrSearches() {
        let log = "keep this\n2026/10/31 from 127.0.0.1:50000 accepted tcp:secret-site:443 [proxy]\npkg-search secret words: nothing found"
        #expect(ProblemReport.redact(log) == "keep this")
    }

    /// The lines that find a bug must survive, or the report is useless.
    @Test func keepsWhatDiagnosesAProblem() {
        let log = """
        Setting up libibverbs1:arm64 (56.1-1) ...
        Cannot open audit interface - aborting.
        fatal: `/sbin/groupadd -g 103 rdma' returned error code 1. Exiting.
        qemu-system-arm depends on libibverbs1 (>= 1.1.6)
        12:34:56 listening on 127.0.0.1:10808
        """
        #expect(ProblemReport.redact(log) == log)
    }

    @Test func removesTerminalCodes() {
        #expect(ProblemReport.redact("\u{1B}[0;1;31mFAILED\u{1B}[0m unmounting") == "FAILED unmounting")
    }

    @Test func crashSummaryTakesOnlyPickedFields() throws {
        let header = #"{"app_name":"V2Mac","app_version":"1.3.0","os_version":"macOS 26.1","name":"V2Mac"}"#
        let body = #"""
        {"captureTime":"2026-10-31","procPath":"/Users/somebody/V2Mac.app","modelCode":"Mac14,2",
         "asi":{"libsystem":["secret message"]},"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","codes":"0x1"},
         "termination":{"namespace":"SIGNAL","code":11,"indicator":"Segmentation fault","details":["secret detail"]},
         "faultingThread":0,"usedImages":[{"name":"V2Mac","path":"/Users/somebody/V2Mac"}],
         "threads":[{"frames":[{"imageIndex":0,"imageOffset":16,"symbol":"AppModel.start()"},{"imageIndex":0,"imageOffset":32}]}]}
        """#
        let summary = try #require(ProblemReport.crashSummary(header + "\n" + body))
        #expect(summary.contains("EXC_BAD_ACCESS") && summary.contains("AppModel.start()") && summary.contains("+32"))
        for leak in ["somebody", "secret", "Mac14"] { #expect(!summary.contains(leak)) }
        #expect(ProblemReport.crashSummary("not a report") == nil)
    }

    @Test func staysShortEnoughForAnIssue() {
        let line = String(repeating: "x y ", count: 25) + "\n"
        let long = String(repeating: line, count: 5_000)
        let crash = String(repeating: "c", count: 50_000)
        let report = ProblemReport.build(.init(versions: ["V2Mac 1"], appLog: long,
                                               files: (0..<4).map { (title: "f\($0)", text: long) },
                                               crashes: [crash, crash, crash], known: []))
        #expect(report.count < 65_536)
    }
}
