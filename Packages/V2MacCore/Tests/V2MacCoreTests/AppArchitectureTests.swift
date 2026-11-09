import Testing
@testable import V2MacCore

@Suite struct AppArchitectureTests {
    @Test(arguments: [AppInstaller.Architecture.arm64, .x86_64])
    func releaseNames(architecture: AppInstaller.Architecture) throws {
        let urls = try #require(AppInstaller.assetURLs(repository: "owner/repo", tag: "v1.2.3", architecture: architecture))
        let intel = architecture == .x86_64
        #expect(urls.dmg.lastPathComponent == "V2Mac-1.2.3\(intel ? "-intel" : "").dmg")
        #expect(urls.checksum.absoluteString == urls.dmg.absoluteString + ".sha256")
        #expect(AppInstaller.manifestURL(repository: "owner/repo", tag: "v1.2.3", architecture: architecture)?.lastPathComponent == "files\(intel ? "-intel" : "").json")
    }
}
