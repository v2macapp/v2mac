import Foundation
import Testing
@testable import V2MacCore

@Suite struct WarpTests {
    static let endpointKey = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEexample\n-----END PUBLIC KEY-----\n"

    static func registration(id: String, token: String?) -> Data {
        var body: [String: Any] = [
            "id": id,
            "account": ["id": "acc-1", "account_type": "free", "warp_plus": false, "license": "aaaa-bbbb-cccc", "premium_data": 0],
            "config": [
                "peers": [["public_key": endpointKey, "endpoint": ["v4": "198.51.100.7:0", "v6": "[2001:db8::7]:0"]]],
                "interface": ["addresses": ["v4": "172.16.0.2", "v6": "2001:db8:1::2"]],
            ],
        ]
        if let token { body["token"] = token }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static let account = WarpAccount(
        deviceID: "dev-1", token: "tok", privateKey: "cHJpdmF0ZQ==", endpointPublicKey: endpointKey,
        endpointV4: "198.51.100.7", endpointV6: "2001:db8::7", addressV4: "172.16.0.2", addressV6: "2001:db8:1::2",
        accountID: "acc-1", accountType: "free", license: "aaaa-bbbb-cccc", premiumData: 0
    )

    @Test func endpointHosts() {
        #expect(WarpClient.host(of: "198.51.100.7:0") == "198.51.100.7")
        #expect(WarpClient.host(of: "[2001:db8::7]:0") == "2001:db8::7")
        #expect(WarpClient.host(of: "2001:db8::7") == "2001:db8::7")
    }

    @Test func registerEnrollsAMasqueKey() async throws {
        let server = try await TestHTTPServer.start { path in
            switch path {
            case "/v0a4471/reg": .init(body: Self.registration(id: "dev-1", token: "tok"))
            case "/v0a4471/reg/dev-1": .init(body: Self.registration(id: "dev-1", token: nil))
            default: .init(status: 404)
            }
        }
        defer { server.stop() }
        let client = WarpClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)/v0a4471")!)
        let account = try await client.register()
        #expect(account.deviceID == "dev-1")
        #expect(account.token == "tok")
        #expect(account.endpointV4 == "198.51.100.7")
        #expect(account.endpointV6 == "2001:db8::7")
        #expect(account.license == "aaaa-bbbb-cccc")
        #expect(!account.isPlus)
        #expect(Data(base64Encoded: account.privateKey) != nil)
        #expect(server.userAgent == "WARP for Android")
    }

    @Test func refusalCarriesCloudflaresMessage() async throws {
        let failure = Data(#"{"success":false,"errors":[{"code":1001,"message":"Invalid license"}]}"#.utf8)
        let server = try await TestHTTPServer.start { _ in .init(status: 400, body: failure) }
        defer { server.stop() }
        let client = WarpClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)/v0a4471")!)
        await #expect(throws: WarpError.api("Invalid license")) {
            try await client.setLicense("x", on: Self.account)
        }
    }

    @Test func outboundUsesMasqueWithThePinnedKey() {
        let o = Self.account.outbound
        #expect(o["protocol"]?.stringValue == "masque")
        #expect(o["settings"]?["address"]?.stringValue == "198.51.100.7")
        #expect(o["streamSettings"]?["network"]?.stringValue == "masque")
        #expect(o["streamSettings"]?["tlsSettings"]?["serverName"]?.stringValue == WarpClient.serverName)
        let warp = o["streamSettings"]?["masqueSettings"]?["warp"]
        #expect(warp?["publicKey"]?.stringValue == Self.endpointKey)
        #expect(warp?["address"]?.arrayValue?.count == 2)
        #expect(Self.account.profile.protocolName == "masque")
        var plus = Self.account
        plus.accountType = "unlimited"
        #expect(plus.isPlus && plus.profile.name == "Cloudflare WARP+")
    }

    @Test func exitChainsWarpThroughTheServer() throws {
        let options = RunOptions(metricsPort: 20000, warpExit: Self.account.outbound)
        let c = try ConfigBuilder.buildGlobal(outbound: ["protocol": "freedom"], options: options)
        #expect(c["outbounds"]?[0]?["tag"]?.stringValue == "proxy")
        #expect(c["outbounds"]?[0]?["protocol"]?.stringValue == "masque")
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue == "warp-upstream")
        #expect(c["outbounds"]?[1]?["tag"]?.stringValue == "warp-upstream")
        #expect(ConfigBuilder.serverTag(options) == "warp-upstream")
        #expect(ConfigBuilder.serverTag(RunOptions(metricsPort: 1)) == "proxy")
    }

    func tagged(_ c: JSONValue, _ tag: String) -> JSONValue? { c["outbounds"]?.arrayValue?.first { $0["tag"]?.stringValue == tag } }
    func dialer(_ o: JSONValue?) -> String? { o?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue }

    @Test func viaServersExitThroughWarpToo() throws {
        let options = RunOptions(metricsPort: 1, warpExit: Self.account.outbound)
        let c = try ConfigBuilder.build(outbound: ViaConfigTests.trojan.config, options: options, routing: .global, custom: ViaConfigTests.custom())
        for tag in ["via-g0-m0", "via-g0-m1", "via-s1-m0", "via-s2-m0"] {
            #expect(tagged(c, tag)?["protocol"] == "masque")
            #expect(dialer(tagged(c, tag)) == "warp-up-" + tag)
            #expect(tagged(c, "warp-up-" + tag) != nil)
        }
        // A full config's chain stays behind its exit, which WARP now dials through.
        let chain = try #require(tagged(c, "warp-up-via-s2-m0"))
        #expect(dialer(chain) == "via-hop-2-0-hop")
        // The renamed servers are not balancer members or probed as such.
        #expect(!(c["outbounds"]?.arrayValue ?? []).contains { $0["tag"]?.stringValue?.hasPrefix("via-") == true && $0["protocol"] == "socks" && dialer($0) == nil && $0["tag"] != "via-hop-2-0-hop" })
    }

    @Test func fullConfigExitsGoThroughWarp() throws {
        let options = RunOptions(metricsPort: 1, warpExit: Self.account.outbound)
        var config = ViaConfigTests.chainConfig
        config = config.setting("outbounds", to: .array([["protocol": "vless", "settings": ["vnext": [["address": "a.example", "port": 443]]]]] + config["outbounds"]!.arrayValue!))
        let c = try ConfigBuilder.buildCustom(config: config, options: options, routing: .global)
        let outbounds = try #require(c["outbounds"]?.arrayValue)
        // The untagged first outbound stays the default, now as WARP.
        #expect(outbounds[0]["protocol"] == "masque")
        #expect(dialer(outbounds[0]) == "warp-up-0")
        #expect(tagged(c, "warp-up-0")?["protocol"] == "vless")
        #expect(tagged(c, "exit")?["protocol"] == "masque")
        #expect(dialer(tagged(c, "warp-up-exit")) == "hop")
        // A hop is not an exit.
        #expect(tagged(c, "hop")?["protocol"] == "socks")
        #expect(tagged(c, "warp-up-hop") == nil)
    }

    @Test func warpServerIsNotWrappedInWarp() {
        let options = RunOptions(metricsPort: 1, warpExit: Self.account.outbound)
        let config: JSONValue = ["outbounds": [Self.account.outbound.setting("tag", to: "w")]]
        #expect(ConfigBuilder.warpingExits(of: config, options: options) == config)
    }

    @Test func traceSaysWhetherTrafficArrivesOverWarp() {
        #expect(ExitLookup.warpField(Data("ip=1.2.3.4\nwarp=off\ngateway=off\n".utf8)) == "off")
        #expect(ExitLookup.warpField(Data("warp=plus\n".utf8)) == "plus")
        #expect(ExitLookup.warpField(Data("ip=1.2.3.4\n".utf8)) == nil)
    }
}
