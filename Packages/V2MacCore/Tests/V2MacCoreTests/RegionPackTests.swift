import Foundation
import os
import Testing
@testable import V2MacCore

@Suite(.serialized) struct RegionPackTests {
    func pack(server: TestHTTPServer) -> RegionPackDefinition {
        let base = "http://127.0.0.1:\(server.port)"
        return RegionPackDefinition(
            id: "xx", name: "Test", attribution: "test",
            geosite: RegionPackFile(url: URL(string: base + "/geosite.dat")!, file: "region-xx-geosite.dat", tags: ["xx"]),
            geoip: RegionPackFile(url: URL(string: base + "/geoip.dat")!, file: "region-xx-geoip.dat", tags: ["xx"])
        )
    }

    func serve(site: Data, ip: Data, siteSum: String? = nil, ipSum: String? = nil) async throws -> TestHTTPServer {
        try await TestHTTPServer.start { path in
            switch path {
            case "/geosite.dat": .init(body: site)
            case "/geoip.dat": .init(body: ip)
            case "/geosite.dat.sha256sum": .init(body: Data("\(siteSum ?? RegionPackInstaller.sha256(site))  release/geosite.dat\n".utf8))
            case "/geoip.dat.sha256sum": .init(body: Data("\(ipSum ?? RegionPackInstaller.sha256(ip))  release/geoip.dat\n".utf8))
            default: .init(status: 404)
            }
        }
    }

    @Test func parsesChecksumLine() throws {
        let hex = String(repeating: "ab", count: 32)
        #expect(try RegionPackInstaller.parseChecksum(Data("\(hex.uppercased())  release/x.dat\n".utf8)) == hex)
        #expect(throws: DownloadError.checksumMalformed) { try RegionPackInstaller.parseChecksum(Data("nope".utf8)) }
    }

    @Test func installsVerifiedFiles() async throws {
        let site = Data("geosite-bytes".utf8), ip = Data("geoip-bytes".utf8)
        let server = try await serve(site: site, ip: ip)
        defer { server.stop() }
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = pack(server: server)

        #expect(!RegionPackInstaller.isInstalled(p, assetDirectory: dir))
        try await RegionPackInstaller.install(p, assetDirectory: dir, downloader: FileDownloader(routes: [.direct]))
        #expect(RegionPackInstaller.isInstalled(p, assetDirectory: dir))
        #expect(try Data(contentsOf: dir.appendingPathComponent("region-xx-geosite.dat")) == site)
        #expect(try Data(contentsOf: dir.appendingPathComponent("region-xx-geoip.dat")) == ip)

        RegionPackInstaller.remove(p, assetDirectory: dir)
        #expect(!RegionPackInstaller.isInstalled(p, assetDirectory: dir))
    }

    @Test func checksumMismatchWritesNothing() async throws {
        let server = try await serve(site: Data("a".utf8), ip: Data("b".utf8), ipSum: String(repeating: "0", count: 64))
        defer { server.stop() }
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = pack(server: server)
        await #expect(throws: DownloadError.checksumMismatch(file: "region-xx-geoip.dat")) {
            try await RegionPackInstaller.install(p, assetDirectory: dir, downloader: FileDownloader(routes: [.direct]))
        }
        // The first file verified, but nothing is installed unless both pass.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    @Test func httpErrorIsReported() async throws {
        let server = try await TestHTTPServer.start { _ in .init(status: 404) }
        defer { server.stop() }
        await #expect(throws: DownloadError.http(404)) {
            try await FileDownloader(routes: [.direct]).download(URL(string: "http://127.0.0.1:\(server.port)/x")!)
        }
    }

    /// F17: with the kill switch on the app's downloads go only through the connection, and
    /// without one nothing is sent, not even to a server that answers.
    @Test func strictPolicyNeverFallsBackToDirect() async throws {
        #expect(NetworkPolicy.routes(proxyPort: 10808, strict: false) == [.localProxy(port: 10808), .direct])
        #expect(NetworkPolicy.routes(proxyPort: nil, strict: false) == [.direct])
        #expect(NetworkPolicy.routes(proxyPort: 10808, strict: true) == [.localProxy(port: 10808)])
        #expect(NetworkPolicy.routes(proxyPort: nil, strict: true).isEmpty)
        let hits = OSAllocatedUnfairLock(initialState: 0)
        let server = try await TestHTTPServer.start { _ in hits.withLock { $0 += 1 }; return .init(body: Data("x".utf8)) }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/x")!
        await #expect(throws: DownloadError.network(NetworkPolicy.noRouteMessage)) {
            try await FileDownloader(routes: NetworkPolicy.routes(proxyPort: nil, strict: true)).download(url)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: DownloadError.network(NetworkPolicy.noRouteMessage)) {
            try await ResumableDownload(routes: []).fetch(url, to: file, expectedSize: 1)
        }
        #expect(hits.withLock { $0 } == 0)
    }

    @Test func downloadSizeIsCapped() async throws {
        let server = try await TestHTTPServer.start { _ in .init(body: Data(repeating: 1, count: 5000)) }
        defer { server.stop() }
        await #expect(throws: DownloadError.tooLarge) {
            try await FileDownloader(routes: [.direct], maxBytes: 1000).download(URL(string: "http://127.0.0.1:\(server.port)/x")!)
        }
    }

    @Test func decodesBundledDefinitionFormat() throws {
        let json = """
        [{"id":"ir","name":"Iran","attribution":"x","geosite":{"url":"https://example.com/a.dat","file":"region-ir-geosite.dat","tags":["ir"]},"geoip":{"url":"https://example.com/b.dat","file":"region-ir-geoip.dat","tags":["ir"]}}]
        """
        let packs = try RegionPackDefinition.decodeList(Data(json.utf8))
        #expect(packs[0].route.domainRules == ["ext:region-ir-geosite.dat:ir"])
        #expect(packs[0].route.ipRules == ["ext:region-ir-geoip.dat:ir"])
    }
}
