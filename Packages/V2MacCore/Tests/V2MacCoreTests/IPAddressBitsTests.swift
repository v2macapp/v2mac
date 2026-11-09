import Testing
@testable import V2MacCore

@Suite struct IPAddressBitsTests {
    @Test func carriesAndShiftsAcrossWords() {
        let boundary = IPAddressBits(1) << 64
        #expect((boundary - 1).low == .max)
        #expect((boundary - 1).high == 0)
        #expect((boundary - 1) + 1 == boundary)
        #expect(boundary >> 64 == 1)
        #expect(boundary.trailingZeroBitCount == 64)
        #expect(IPAddressBits.max >> 128 == 0)
        #expect(~IPAddressBits(0) == .max)
    }

    @Test func ipv6Prefixes() {
        let geo = GeoLists()
        #expect(RuleTester.ipMatches("::/64", "::ffff:ffff:ffff:ffff", geo: geo))
        #expect(!RuleTester.ipMatches("::/64", "0:0:0:1::", geo: geo))
        #expect(RuleTester.ipMatches("::ffff:0:0/96", "::ffff:192.0.2.1", geo: geo))
        #expect(!RuleTester.ipMatches("::ffff:0:0/96", "::fffe:192.0.2.1", geo: geo))
        #expect(RuleTester.ipMatches("::/0", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", geo: geo))
        #expect(RuleTester.ipMatches("::1/128", "::1", geo: geo))
        #expect(!RuleTester.ipMatches("::1/128", "::2", geo: geo))
        for invalid in ["", "::/129", "::/-1", "::/no", "::/", "::/0/1"] {
            #expect(!RuleTester.ipMatches(invalid, "::1", geo: geo))
        }
        #expect(RuleMatchers.range("::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == ["::/0"])
        #expect(RuleMatchers.range("::-::ffff:ffff:ffff:ffff") == ["::/64"])
    }
    @Test func geoIPv6Ranges() {
        let geo = GeoLists(siteFiles: [:], ipFiles: ["geoip.dat": GeoFixture.ips([
            "low": ["::/64"], "mapped": ["::ffff:0:0/96"], "all": ["::/0"], "one": ["::1/128"]
        ])])
        #expect(geo.ipList("geoip.dat:low", contains: "::ffff:ffff:ffff:ffff"))
        #expect(!geo.ipList("geoip.dat:low", contains: "0:0:0:1::"))
        #expect(geo.ipList("geoip.dat:mapped", covers: "::ffff:192.0.2.0/120"))
        #expect(!geo.ipList("geoip.dat:mapped", covers: "::/64"))
        #expect(geo.ipList("geoip.dat:all", covers: "::/0"))
        #expect(!geo.ipList("geoip.dat:all", covers: "::/129"))
        #expect(!geo.ipList("geoip.dat:all", covers: "::/"))
        #expect(geo.ipList("geoip.dat:one", contains: "::1"))
        #expect(!geo.ipList("geoip.dat:one", contains: "::2"))
    }

}
