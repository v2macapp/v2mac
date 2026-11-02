import Foundation
import Testing
@testable import V2MacCore

@Suite struct RuleDoctorTests {
    static let geo = GeoFixture.geo
    static let installed = RuleV2Tests.installed

    func findings(_ rules: [Rule], _ configure: (inout DoctorInput) -> Void = { _ in }) -> [DoctorFinding] {
        var input = DoctorInput(rules: rules)
        input.apps = Self.installed
        input.geo = Self.geo
        configure(&input)
        return RuleDoctor.diagnose(input)
    }

    func fixes(_ found: [DoctorFinding]) -> [DoctorFix] { found.compactMap(\.fixes.first) }

    @Test func rollsSubdomainsUpAcrossRules() throws {
        let a = Rule(name: "A", action: .proxy, items: [.host("full:www.shop.example"), .host("domain:api.shop.example")])
        let b = Rule(name: "B", action: .proxy, items: [.host("full:cdn.shop.example"), .host("domain:other.example")])
        let found = try #require(findings([a, b]).first { $0.title.contains("shop.example") })
        #expect(found.severity == .simplify)
        #expect(!found.preselected)
        let out = RuleDoctor.apply(fixes([found]), to: [a, b])
        #expect(out[0].items == [.host("domain:shop.example")])
        #expect(out[1].items == [.host("domain:other.example")])
    }

    /// App, hosts and subdomains all proxied, with the whole domain further down: one host entry is enough.
    @Test func narrowHostsAboveAWiderOneGo() throws {
        let narrow = Rule(name: "Web", action: .proxy, items: [.host("full:www.shop.example"), .host("full:api.shop.example")])
        let free = Rule(name: "Other", action: .direct, items: [.host("domain:free.example")])
        let wide = Rule(name: "Shop", action: .proxy, items: [.host("domain:shop.example")])
        let found = try #require(findings([narrow, free, wide]).first { $0.title.contains("does nothing") })
        #expect(found.preselected)
        #expect(RuleDoctor.apply(fixes([found]), to: [narrow, free, wide]).map(\.id) == [free.id, wide.id])
        // Something between them could take that traffic, so order matters and they stay.
        let between = Rule(name: "Pay", action: .direct, items: [.host("full:www.shop.example")])
        #expect(!findings([narrow, between, wide]).contains { $0.title.contains("does nothing") })
    }

    @Test func neverRollsUpSharedHosting() {
        let rule = Rule(name: "Pages", action: .proxy, items: [.host("full:a.github.io"), .host("full:b.github.io")])
        #expect(!findings([rule]).contains { $0.title.contains("github.io") })
    }

    @Test func rollUpNeverHidesARuleThatRoutesElsewhere() {
        let proxy = Rule(name: "P", action: .proxy, items: [.host("full:a.shop.example"), .host("full:b.shop.example")])
        let direct = Rule(name: "D", action: .direct, items: [.host("full:c.shop.example")])
        #expect(!findings([proxy, direct]).contains { $0.title.contains("one entry") })
    }

    @Test func replacesHostsWithTheirServiceList() throws {
        let rule = Rule(name: "Code", action: .proxy, items: [.host("domain:github.com"), .host("full:api.other.github.com"), .host("full:x.github.com")])
        // These hosts are one domain, so the inner ones are duplicates; use three names in the list.
        let list = GeoLists(siteFiles: ["geosite.dat": GeoFixture.sites(["svc": [(2, "a.example"), (2, "b.example"), (2, "c.example")]])], ipFiles: [:])
        let hosts = Rule(name: "Svc", action: .proxy, items: [.host("domain:a.example"), .host("domain:b.example"), .host("full:www.c.example")])
        let found = try #require(findings([hosts]) { $0.geo = list }.first { $0.title.contains("“svc”") })
        #expect(RuleDoctor.apply(fixes([found]), to: [hosts])[0].items == [.host("geosite:svc")])
        #expect(findings([rule]).contains { $0.title.contains("repeats itself") })
    }

    @Test func dropsAnAppItsHostsCover() throws {
        let rule = Rule(name: "Chat", action: .proxy, items: [.app("com.example.chat"), .host("domain:chat.example")])
        let seen = findings([rule]) { $0.seenHosts = ["/Applications/Chat.app": ["a.chat.example", "chat.example"]] }
        let found = try #require(seen.first { $0.title.contains("doesn't need") })
        #expect(found.detail.contains("2"))
        #expect(found.fixes[0].changesRouting)
        #expect(RuleDoctor.apply(fixes([found]), to: [rule])[0].items == [.host("domain:chat.example")])
        // It went somewhere the hosts do not cover: the app stays.
        let elsewhere = findings([rule]) { $0.seenHosts = ["/Applications/Chat.app": ["chat.example", "else.example"]] }
        #expect(!elsewhere.contains { $0.title.contains("doesn't need") })
    }

    @Test func narrowEntryBelowAWideOneBecomesAnException() throws {
        let wide = Rule(name: "All", action: .proxy, items: [.host("domain:shop.example")])
        let narrow = Rule(name: "Local", action: .direct, items: [.host("full:pay.shop.example"), .host("domain:other.example")])
        let found = try #require(findings([wide, narrow]).first { $0.severity == .conflict })
        #expect(!found.preselected)
        let out = RuleDoctor.apply([found.fixes[0]], to: [wide, narrow])
        #expect(out.map(\.action) == [.direct, .proxy, .direct])
        #expect(out[0].items == [.host("full:pay.shop.example")])
        #expect(out[2].items == [.host("domain:other.example")])
    }

    @Test func sameEntryInTwoRulesOffersEitherWinner() throws {
        let a = Rule(name: "A", action: .proxy, items: [.host("domain:x.example")])
        let b = Rule(name: "B", action: .direct, items: [.host("domain:x.example"), .host("domain:y.example")])
        let found = try #require(findings([a, b]).first { $0.severity == .conflict })
        #expect(found.preselected)
        #expect(RuleDoctor.apply([found.fixes[0]], to: [a, b])[1].items == [.host("domain:y.example")])
        #expect(RuleDoctor.apply([found.fixes[1]], to: [a, b]).map(\.id) == [b.id])
    }

    @Test func conditionsDecideWhetherARuleIsHidden() {
        let wide = Rule(name: "W", action: .proxy, items: [.host("domain:x.example")], only: .init(ports: "443"))
        let later = Rule(name: "L", action: .direct, items: [.host("full:a.x.example")])
        #expect(!findings([wide, later]).contains { $0.severity == .conflict })
        let inside = Rule(name: "L", action: .direct, items: [.host("full:a.x.example")], only: .init(ports: "443"))
        #expect(findings([wide, inside]).contains { $0.severity == .conflict })
        let off = Rule(name: "Off", action: .proxy, items: [.host("domain:x.example")], enabled: false)
        #expect(!findings([off, later]).contains { $0.severity == .conflict })
    }

    @Test func coverageUsesGeoListsAndRanges() {
        let list = Rule(name: "Git", action: .proxy, items: [.host("geosite:github")])
        let host = Rule(name: "One", action: .proxy, items: [.host("full:api.github.com")])
        #expect(findings([list, host]).contains { $0.title.contains("already covers") })
        let block = Rule(name: "Range", action: .block, items: [.host("8.8.0.0/16")])
        let single = Rule(name: "DNS", action: .proxy, items: [.host("8.8.8.8/32")])
        #expect(findings([block, single]).contains { $0.severity == .conflict })
        let us = Rule(name: "US", action: .direct, items: [.host("geoip:us")])
        #expect(findings([us, single]).contains { $0.severity == .conflict })
    }

    @Test func emptiedRuleWithConditionsIsDeletedNotWidened() {
        let rule = Rule(name: "R", action: .block, items: [.host("10.0.0.0/8")], only: .init(ports: "443"))
        let found = findings([rule])
        #expect(RuleDoctor.apply(fixes(found), to: [rule]).isEmpty)
    }

    @Test func repairsErrors() throws {
        let rule = Rule(name: "Bad", action: .proxy, items: [.host("https://www.shop.example/path"), .host("not valid!"), .host("geosite:nothing"), .host("regexp:(?=x)y")],
                        only: .init(ports: "8100-8000; 443 99999"))
        let found = findings([rule])
        let read = try #require(found.first { $0.title.contains("cannot read") })
        #expect(read.preselected)
        let usable = try #require(found.first { $0.title.contains("cannot use") })
        #expect(usable.detail.contains("geosite:nothing") && usable.detail.contains("(?=x)y"))
        let out = RuleDoctor.apply(fixes(found.filter { $0.severity == .error }), to: [rule])
        #expect(out[0].items == [.host("domain:www.shop.example")])
        #expect(out[0].only.ports == "8000-8100,443")
        #expect(Rule.OnlyWhen.validPorts(out[0].only.ports))
    }

    @Test func oldFormHostsAreRewrittenWithoutChangingRouting() throws {
        let rule = Rule(name: "Old", action: .proxy, items: [.host("mail.example")])
        let found = try #require(findings([rule]).first { $0.title.contains("not understood") })
        #expect(found.preselected)
        #expect(RuleDoctor.apply(fixes([found]), to: [rule])[0].items == [.host("domain:mail.example")])
    }

    @Test func findsContradictionsAndSettings() {
        let quic = Rule(name: "Q", action: .proxy, items: [.host("domain:a.example")], only: .init(network: .tcp, protocols: [.quic]))
        #expect(findings([quic]).contains { $0.title.contains("never match") })
        let udp = Rule(name: "U", action: .proxy, only: .init(ports: "443", network: .udp))
        let blocked = findings([udp]) { $0.blockQUIC = true }.first { $0.title.contains("Block QUIC") }
        #expect(blocked?.fixes.first?.edits == [.turnOffBlockQUIC])
        let via = Rule(name: "V", action: .via(.init(target: .server(UUID()), name: "Home")), items: [.host("domain:a.example")])
        let home = UUID()
        let relink = findings([via]) { $0.targets = [.server(home): "Home"] }.first { $0.severity == .error }
        #expect(relink?.fixes.first?.edits == [.setAction(via.id, .via(.init(target: .server(home), name: "Home")))])
        #expect(findings([via]) { $0.mode = .direct }.contains { $0.fixes.first?.edits == [.useGlobalMode] })
    }

    @Test func tunModeOffersHostsForAnApp() throws {
        let rule = Rule(name: "Chat", action: .proxy, items: [.app("com.example.chat")])
        let found = try #require(findings([rule]) { $0.tun = true; $0.seenHosts = ["/Applications/Chat.app": ["a.chat.example", "b.chat.example"]] }.first { $0.title.contains("TUN") })
        #expect(RuleDoctor.apply(fixes([found]), to: [rule])[0].items == [.host("domain:chat.example")])
        let nothing = try #require(findings([rule]) { $0.tun = true }.first { $0.title.contains("TUN") })
        #expect(nothing.fixes.isEmpty)
    }

    @Test func trailingRulesMatchingTheDefaultAreOptional() throws {
        let block = Rule(name: "B", action: .block, items: [.host("domain:a.example")])
        let proxy = Rule(name: "P", action: .proxy, items: [.host("domain:b.example")])
        let found = try #require(findings([proxy, block, proxy]) { $0.defaultRoute = .proxy }.first { $0.title.contains("at the end") })
        #expect(!found.preselected)
        #expect(!findings([proxy, block]) { $0.defaultRoute = .proxy }.contains { $0.title.contains("at the end") })
    }

    /// Fixes that claim to keep routing keep it: every host, address and app routes the same before and after.
    @Test func routingPreservingFixesKeepRouting() {
        let rules = [
            Rule(name: "Local", action: .direct, items: [.host("10.0.0.0/8"), .host("domain:ok.example")]),
            Rule(name: "Direct shop", action: .direct, items: [.host("domain:d.example"), .host("full:a.d.example")]),
            Rule(name: "Ads", action: .block, items: [.host("domain:ads.example"), .host("domain:ads.example")]),
            Rule(name: "P1", action: .proxy, items: [.host("domain:p.example")]),
            Rule(name: "P2", action: .proxy, items: [.host("full:x.p.example"), .host("domain:q.example")]),
            Rule(name: "Conflict", action: .direct, items: [.host("domain:q.example"), .host("full:a.d.example"), .host("domain:r.example")]),
            Rule(name: "Git", action: .proxy, items: [.host("geosite:github")]),
            Rule(name: "Git host", action: .direct, items: [.host("full:api.github.com")]),
            Rule(name: "Range", action: .block, items: [.host("8.8.0.0/16")]),
            Rule(name: "Inside", action: .proxy, items: [.host("8.8.8.0/24"), .host("9.9.9.9/32")]),
            Rule(name: "Web", action: .proxy, items: [.host("domain:w.example")], only: .init(ports: "443")),
            Rule(name: "Web80", action: .direct, items: [.host("domain:w.example")], only: .init(ports: "80")),
            Rule(name: "Narrow", action: .proxy, items: [.host("full:a.n.example")]),
            Rule(name: "Wide", action: .proxy, items: [.host("domain:n.example")]),
            Rule(name: "Off", action: .block, items: [.host("domain:p.example")], enabled: false),
        ]
        let hosts = ["ok.example", "d.example", "a.d.example", "ads.example", "p.example", "x.p.example", "q.example", "r.example", "github.com",
                     "api.github.com", "w.example", "a.n.example", "b.n.example", "none.example", "sub.w.example"]
        let queries = hosts.flatMap { h in [443, 80].map { RouteQuery(host: h, port: $0) } }
            + ["8.8.8.8", "8.8.1.1", "9.9.9.9", "10.1.1.1", "1.1.1.1"].map { RouteQuery(ips: [$0]) }
        func routes(_ list: [Rule]) -> [String?] {
            let routing = RuleTester.routing(plan: .global, custom: CustomRules(rules: list))
            return queries.map { RuleTester.route($0, routing: routing, geo: Self.geo)?.outbound }
        }
        let found = findings(rules)
        let safe = found.compactMap { $0.fixes.first { !$0.changesRouting } }
        #expect(!safe.isEmpty)
        #expect(found.contains { $0.severity == .organize })
        #expect(routes(RuleDoctor.apply(safe, to: rules)) == routes(rules))
    }

    @Test func groupingKeepsOverlappingRulesInOrder() throws {
        let direct = Rule(name: "D", action: .direct, items: [.host("domain:d.example")])
        let wide = Rule(name: "W", action: .direct, items: [.host("domain:shop.example")])
        let block = Rule(name: "B", action: .block, items: [.host("full:a.shop.example")])
        let free = Rule(name: "F", action: .block, items: [.host("domain:free.example")])
        let found = try #require(findings([direct, wide, block, free]).first { $0.title.contains("Group") })
        let out = RuleDoctor.apply(fixes([found]), to: [direct, wide, block, free])
        // The free block rule moves to the top; the other stays below the wider Direct rule it overlaps.
        #expect(out.first?.id == free.id)
        #expect(out.firstIndex { $0.id == wide.id }! < out.firstIndex { $0.id == block.id }!)
    }

    @Test func diagnosingARepairedListFindsLess() {
        let rules = [Rule(name: "A", action: .proxy, items: [.host("domain:x.example"), .host("full:a.x.example"), .host("10.0.0.0/8")])]
        let first = findings(rules)
        let second = findings(RuleDoctor.apply(first.filter(\.preselected).compactMap(\.fixes.first), to: rules))
        #expect(second.isEmpty)
    }
}
