import Foundation

/// What the Rules Doctor looks at (spec 8.6): the draft list and what the app knows about this Mac.
public struct DoctorInput: Sendable {
    public var rules: [Rule]
    public var apps: [InstalledApp] = []
    public var geo = GeoLists()
    /// Servers and groups on this Mac, with their names; nil skips the checks that need them.
    public var targets: [Rule.Via.Target: String]?
    public var failingTargets: Set<Rule.Via.Target> = []
    /// Where traffic no rule matched goes, when that is certain (not in Bypass or with a full config's fallback).
    public var defaultRoute: Rule.Action?
    public var mode = RoutingMode.global
    public var blockQUIC = false
    public var tun = false
    /// Hosts each app (its `.app` folder or executable) was seen connecting to.
    public var seenHosts: [String: Set<String>] = [:]

    public init(rules: [Rule]) { self.rules = rules }
}

/// One change to the list or a setting. A fix is one or more of these.
public enum DoctorEdit: Sendable, Hashable {
    case removeItems(UUID, [Rule.Item])
    /// Keeps the first copy of every item.
    case dropRepeats(UUID)
    case replaceItems(UUID, remove: [Rule.Item], add: [Rule.Item])
    case deleteRule(UUID)
    case insert(Rule, before: UUID)
    case setPorts(UUID, String)
    case clearNetwork(UUID)
    case clearOnlyApps(UUID)
    case setAction(UUID, Rule.Action)
    case turnOff(UUID)
    case rename(UUID, String)
    case merge(into: UUID, from: [UUID], name: String)
    case order([UUID])
    case turnOffBlockQUIC
    case useGlobalMode
}

public struct DoctorFix: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let title: String
    /// False only when every connection goes where it went before.
    public let changesRouting: Bool
    public let edits: [DoctorEdit]
}

public struct DoctorFinding: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, CaseIterable, Comparable {
        case error, conflict, warning, simplify, organize
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public let id = UUID()
    public let severity: Severity
    public let title: String
    public let detail: String
    /// The recommended fix first; empty when only the user can settle it, and `detail` says how.
    public let fixes: [DoctorFix]
    /// Ticked when the Doctor opens.
    public let preselected: Bool
}

/// Finds what is wrong or wasteful in a rule list and how to fix it (spec 8.6). Pure: it only proposes.
public enum RuleDoctor {
    public static func diagnose(_ input: DoctorInput) -> [DoctorFinding] {
        var run = Run(input)
        run.checkSettings()
        for rule in input.rules { run.checkHealth(rule) }
        run.checkCoverage()
        run.checkWiderBelow()
        run.checkRollUps()
        run.checkApps()
        run.checkTidyRules()
        run.checkOrganizing()
        return run.out.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }

    /// Applies the fixes in order; an edit whose rule is gone is passed over. A rule that loses its
    /// last item is deleted: with "Only when" left it would otherwise match all such traffic.
    public static func apply(_ fixes: [DoctorFix], to rules: [Rule]) -> [Rule] {
        var rules = rules
        func edit(_ id: UUID, _ change: (inout Rule) -> Void) {
            guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
            let hadItems = !rules[i].items.isEmpty
            change(&rules[i])
            if hadItems, rules[i].items.isEmpty { rules.remove(at: i) }
        }
        let edits = fixes.flatMap(\.edits)
        // Ordering first: it was worked out on the list as it stands.
        for case .order(let ids) in edits {
            let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            rules = rules.enumerated().sorted { (rank[$0.element.id] ?? $0.offset) < (rank[$1.element.id] ?? $1.offset) }.map(\.element)
        }
        for e in edits {
            switch e {
            case .removeItems(let id, let items): edit(id) { $0.items.removeAll(where: items.contains) }
            case .dropRepeats(let id):
                edit(id) { rule in
                    var seen = Set<Rule.Item>()
                    rule.items = rule.items.filter { seen.insert($0).inserted }
                }
            case .replaceItems(let id, let remove, let add):
                edit(id) { rule in
                    let at = rule.items.firstIndex(where: remove.contains) ?? rule.items.count
                    rule.items.removeAll(where: remove.contains)
                    let new = add.filter { !rule.items.contains($0) }
                    rule.items.insert(contentsOf: new, at: min(at, rule.items.count))
                }
            case .deleteRule(let id): rules.removeAll { $0.id == id }
            case .insert(let rule, let before):
                if let i = rules.firstIndex(where: { $0.id == before }), !rules.contains(where: { $0.id == rule.id }) { rules.insert(rule, at: i) }
            case .setPorts(let id, let ports): edit(id) { $0.only.ports = ports }
            case .clearNetwork(let id): edit(id) { $0.only.network = nil }
            case .clearOnlyApps(let id): edit(id) { $0.only.apps = [] }
            case .setAction(let id, let action): edit(id) { $0.action = action }
            case .turnOff(let id): edit(id) { $0.enabled = false }
            case .rename(let id, let name): edit(id) { $0.name = name }
            case .merge(let into, let from, let name):
                guard rules.contains(where: { $0.id == into }) else { continue }
                let moved = from.flatMap { id in rules.first { $0.id == id }?.items ?? [] }
                edit(into) { rule in
                    for item in moved where !rule.items.contains(item) { rule.items.append(item) }
                    rule.name = name
                }
                rules.removeAll { from.contains($0.id) }
            case .order, .turnOffBlockQUIC, .useGlobalMode: break
            }
        }
        return rules
    }

    /// Hosting and CDN domains whose subdomains belong to different people: never rolled up.
    static let sharedDomains: Set<String> = [
        "github.io", "githubusercontent.com", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app", "herokuapp.com",
        "web.app", "firebaseapp.com", "cloudfront.net", "amazonaws.com", "azurewebsites.net", "azureedge.net", "fastly.net",
        "akamaized.net", "akamaihd.net", "appspot.com", "blogspot.com", "wordpress.com", "ngrok.io", "ngrok.app", "duckdns.org",
    ]

    /// Turns "443; 80 8100-8000 70000" into "443,80,8000-8100"; nil when nothing is left.
    static func repairedPorts(_ text: String) -> String? {
        var out: [String] = []
        for token in text.split(whereSeparator: { ",;".contains($0) || $0.isWhitespace }) {
            let ends = token.replacingOccurrences(of: ":", with: "-").split(separator: "-").compactMap { Int($0) }
            guard (1...2).contains(ends.count), ends.allSatisfy({ (1...65535).contains($0) }) else { continue }
            let part = ends.count == 1 ? "\(ends[0])" : "\(min(ends[0], ends[1]))-\(max(ends[0], ends[1]))"
            if !out.contains(part) { out.append(part) }
        }
        return out.isEmpty ? nil : out.joined(separator: ",")
    }

    /// What a mistyped host entry most likely meant: a URL's host, a list of that name, or a keyword.
    static func repaired(_ text: String, geo: GeoLists) -> Rule.Item? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = t.range(of: "://") { t = String(t[scheme.upperBound...]) }
        t = String(t.prefix { !"/?#".contains($0) })
        if let at = t.lastIndex(of: "@") { t = String(t[t.index(after: at)...]) }
        if let colon = t.lastIndex(of: ":"), Int(t[t.index(after: colon)...]) != nil { t = String(t[..<colon]) }
        if RuleMatchers.isIP(t) { return .host(t) }
        if let name = RuleMatchers.domainName(t) { return .host("domain:" + name) }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !t.isEmpty else { return nil }
        if geo.containsList("geosite:" + t) { return .host("geosite:" + t) }
        return t.count >= 4 ? .host("keyword:" + t) : nil
    }

    /// Lists the Go regular expressions of the core cannot compile, though Swift's can.
    static func isUsableRegex(_ pattern: String) -> Bool {
        guard (try? Regex(pattern)) != nil else { return false }
        return !["(?=", "(?!", "(?<=", "(?<!", "\\1", "\\2"].contains { pattern.contains($0) }
    }
}

/// Which of an index's entries cover a given entry, each with the owner the index was given.
private struct CoverIndex {
    private var exact: [String: [Int]] = [:]
    private var domains: [String: [Int]] = [:]
    private var keywords: [(String, Int)] = []
    private var regexes: [(String, Regex<AnyRegexOutput>, Int)] = []
    private var sites: [(String, SiteSet, Int)] = []
    private var cidrs: [(String, Int)] = []
    private var geoips: [(String, Int)] = []
    private let geo: GeoLists

    init(geo: GeoLists) { self.geo = geo }

    mutating func add(_ entry: String, owner: Int, sets: inout [String: SiteSet]) {
        exact[entry, default: []].append(owner)
        if entry.hasPrefix("domain:") { domains[String(entry.dropFirst(7)), default: []].append(owner) }
        else if entry.hasPrefix("keyword:") { keywords.append((String(entry.dropFirst(8)), owner)) }
        else if entry.hasPrefix("regexp:") { if let r = try? Regex(String(entry.dropFirst(7))) { regexes.append((entry, r, owner)) } }
        else if entry.hasPrefix("geoip:"), !entry.hasPrefix("geoip:!") { geoips.append((entry, owner)) }
        else if entry.hasPrefix("geosite:") || entry.hasPrefix("ext:") {
            // A list narrowed by @attribute holds less than its name says, so it only covers itself.
            if !entry.contains("@"), let set = SiteSet.make(entry, geo: geo, cache: &sets) { sites.append((entry, set, owner)) }
        } else if entry.contains("/"), RuleMatchers.isIP(entry) { cidrs.append((entry, owner)) }
    }

    /// (owner, the entry that covers). Includes `entry` itself when present.
    func coverers(of entry: String) -> [(owner: Int, by: String)] {
        var out = (exact[entry] ?? []).map { (owner: $0, by: entry) }
        let isFull = entry.hasPrefix("full:"), isDomain = entry.hasPrefix("domain:")
        if isFull || isDomain {
            let host = String(entry.dropFirst(isFull ? 5 : 7))
            var name = Substring(host)
            while true {
                for o in domains[String(name)] ?? [] where !(isDomain && name == host) { out.append((o, "domain:\(name)")) }
                guard let dot = name.firstIndex(of: ".") else { break }
                name = name[name.index(after: dot)...]
            }
            for (k, o) in keywords where host.contains(k) { out.append((o, "keyword:" + k)) }
            for (e, set, o) in sites where set.covers(host, subdomains: isDomain) { out.append((o, e)) }
            if isFull { for (e, r, o) in regexes where host.contains(r) { out.append((o, e)) } }
        } else if entry.hasPrefix("keyword:") {
            let word = entry.dropFirst(8)
            for (k, o) in keywords where k != word && word.contains(k) { out.append((o, "keyword:" + k)) }
        } else if RuleMatchers.isIP(entry) {
            for (e, o) in cidrs where e != entry && TidyUp.contains(e, entry) { out.append((o, e)) }
            for (e, o) in geoips where geo.ipList(GeoLists.key(e) ?? "", covers: entry) { out.append((o, e)) }
        }
        return out
    }
}

/// A site list's plain entries, for asking about a whole domain rather than one host.
struct SiteSet {
    var domains = Set<String>(), fulls = Set<String>(), keywords: [String] = []
    var hasRegex = false

    static func make(_ entry: String, geo: GeoLists, cache: inout [String: SiteSet]) -> SiteSet? {
        guard let key = GeoLists.key(entry), let list = geo.sites[key] else { return nil }
        if let known = cache[key] { return known }
        var set = SiteSet()
        for e in list {
            switch e.kind {
            case .domain: set.domains.insert(e.value)
            case .full: set.fulls.insert(e.value)
            case .keyword: set.keywords.append(e.value)
            case .regex: set.hasRegex = true
            }
        }
        cache[key] = set
        return set
    }

    /// With `subdomains`, whether every name under `host` is in the list too.
    func covers(_ host: String, subdomains: Bool) -> Bool {
        if !subdomains, fulls.contains(host) { return true }
        if keywords.contains(where: host.contains) { return true }
        var name = Substring(host)
        while true {
            if domains.contains(String(name)) { return true }
            guard let dot = name.firstIndex(of: ".") else { return false }
            name = name[name.index(after: dot)...]
        }
    }

    /// Whether any traffic could match both this list and `host` or its subdomains.
    func touches(_ host: String) -> Bool {
        if hasRegex || !keywords.isEmpty || covers(host, subdomains: false) { return true }
        return (domains.union(fulls)).contains { $0.hasSuffix("." + host) }
    }
}

private struct Run {
    let input: DoctorInput
    var rules: [Rule] { input.rules }
    var out: [DoctorFinding] = []
    var sets: [String: SiteSet] = [:]
    /// Items already reported as removable, so a roll-up does not count them too.
    var removable = Set<Rule.Item>()
    let siteTags: Set<String>
    /// Rules the core will really get.
    let live: Set<UUID>

    init(_ input: DoctorInput) {
        self.input = input
        let tags = Set(input.geo.sites.keys.compactMap { $0.hasPrefix("geosite.dat:") ? String($0.dropFirst(12)) : nil })
        siteTags = tags
        live = Set(input.rules.filter { $0.enabled && !$0.xrayRules(apps: input.apps, siteTags: tags, target: ("outboundTag", "x")).isEmpty }.map(\.id))
    }

    func name(_ rule: Rule) -> String { rule.name.isEmpty ? String(localized: "Untitled") : rule.name }

    func title(_ action: Rule.Action) -> String {
        switch action {
        case .proxy: String(localized: "Proxy")
        case .direct: String(localized: "Direct")
        case .block: String(localized: "Block")
        case .via(let via): String(localized: "Via \(input.targets?[via.target] ?? via.name)")
        }
    }

    mutating func add(_ severity: DoctorFinding.Severity, _ title: String, _ detail: String, _ fixes: [DoctorFix], preselected: Bool? = nil) {
        out.append(DoctorFinding(severity: severity, title: title, detail: detail, fixes: fixes,
                                 preselected: preselected ?? (fixes.first.map { !$0.changesRouting } ?? false)))
    }

    func fix(_ title: String, routing: Bool = false, _ edits: DoctorEdit...) -> DoctorFix {
        DoctorFix(title: title, changesRouting: routing, edits: edits)
    }

    func texts(_ items: [Rule.Item]) -> String {
        let shown = items.prefix(6).map(\.text).joined(separator: ", ")
        return items.count > 6 ? String(localized: "\(shown) and \(items.count - 6) more") : shown
    }

    /// An item as compiled entries, in the forms `CoverIndex` reads.
    func entries(_ item: Rule.Item) -> [String] {
        switch item {
        case .app(let entry): return AppMatchers.processes(for: entry, apps: input.apps).map { "process:" + $0 }
        case .country(let code): return ["country:" + code.lowercased()]
        case .host(let text):
            let m = RuleMatchers(parsing: text)
            guard m.invalid.isEmpty else { return [] }
            return (m.domains + m.ips).map { $0.hasPrefix("regexp:") ? $0 : $0.lowercased() }
        }
    }

    func installed(_ entry: String) -> InstalledApp? {
        let lower = entry.lowercased()
        return input.apps.first { $0.lowerID == lower || $0.name == lower || $0.name == lower + ".app" || $0.path == entry }
    }

    /// An app entry that names nothing on this Mac.
    func isMissingApp(_ entry: String) -> Bool {
        if entry.hasPrefix("/") || entry.hasPrefix("~") { return false }
        let found = AppMatchers.processes(for: entry, apps: input.apps)
        return found.isEmpty || (entry.contains(".") && installed(entry) == nil)
    }

    // MARK: Settings

    mutating func checkSettings() {
        if input.mode == .direct, rules.contains(where: { $0.enabled && $0.action != .block }) {
            add(.warning, String(localized: "Direct mode ignores all but Block rules"),
                String(localized: "Your Proxy, Direct and Via rules do nothing until the routing mode changes."),
                [fix(String(localized: "Switch to Global mode"), routing: true, .useGlobalMode)])
        }
    }

    // MARK: One rule at a time

    mutating func checkHealth(_ rule: Rule) {
        let label = name(rule)
        if rule.items.isEmpty, rule.only.isEmpty {
            add(.warning, String(localized: "“\(label)” is empty"), String(localized: "It has nothing to match, so it never does anything."),
                [fix(String(localized: "Delete the rule"), .deleteRule(rule.id))])
            return
        }
        checkPorts(rule, label)
        checkEntries(rule, label)
        checkConditions(rule, label)
        checkVia(rule, label)
        if input.tun, rule.enabled, rule.needsApps { checkTun(rule, label) }
    }

    private mutating func checkPorts(_ rule: Rule, _ label: String) {
        let ports = rule.only.ports.replacingOccurrences(of: " ", with: "")
        guard !ports.isEmpty, !Rule.OnlyWhen.validPorts(ports) else { return }
        var fixes = [fix(String(localized: "Turn the rule off"), .turnOff(rule.id)), fix(String(localized: "Delete the rule"), .deleteRule(rule.id))]
        var repaired = false
        if let good = RuleDoctor.repairedPorts(rule.only.ports) {
            fixes.insert(fix(String(localized: "Use the ports \(good)"), routing: true, .setPorts(rule.id, good)), at: 0)
            repaired = true
        }
        add(.error, String(localized: "“\(label)” has invalid ports: \(rule.only.ports)"),
            String(localized: "The core gets no rule at all from it until they are fixed."), fixes, preselected: repaired)
    }

    private mutating func checkEntries(_ rule: Rule, _ label: String) {
        var unreadable: [Rule.Item] = [], rewrite: [(Rule.Item, [Rule.Item])] = [], unusable: [Rule.Item] = [], broad: [Rule.Item] = [], gone: [Rule.Item] = []
        for item in rule.items {
            switch item {
            case .app(let entry): if isMissingApp(entry) { gone.append(item) }
            case .country(let code): if !GeoTags.isCountry(code) { unreadable.append(item) }
            case .host:
                let parsed = entries(item)
                if parsed.isEmpty { unreadable.append(item); continue }
                if item.kind == .invalid { rewrite.append((item, parsed.map(Rule.Item.host))) }
                for entry in parsed {
                    if entry.hasPrefix("regexp:"), !RuleDoctor.isUsableRegex(String(entry.dropFirst(7))) { unusable.append(item) }
                    else if entry.hasPrefix("keyword:"), entry.count - 8 < 3 { broad.append(item) }
                    else if !input.geo.isEmpty, entry.hasPrefix("geosite:") || entry.hasPrefix("geoip:") || entry.hasPrefix("ext:"),
                            !input.geo.containsList(entry.replacingOccurrences(of: "geoip:!", with: "geoip:")), !entry.hasPrefix("geoip:private") { unusable.append(item) }
                }
            }
        }
        if !unreadable.isEmpty {
            let repairs = unreadable.compactMap { item -> (Rule.Item, Rule.Item)? in
                guard case .host(let text) = item, let good = RuleDoctor.repaired(text, geo: input.geo) else { return nil }
                return (item, good)
            }
            var fixes = [fix(String(localized: "Remove them"), .removeItems(rule.id, unreadable))]
            if !repairs.isEmpty {
                var edits = repairs.map { DoctorEdit.replaceItems(rule.id, remove: [$0.0], add: [$0.1]) }
                let rest = unreadable.filter { item in !repairs.contains { $0.0 == item } }
                if !rest.isEmpty { edits.append(.removeItems(rule.id, rest)) }
                let summary = repairs.prefix(3).map { "\($0.0.text) → \($0.1.text)" }.joined(separator: ", ")
                fixes.insert(DoctorFix(title: String(localized: "Read as \(summary)"), changesRouting: true, edits: edits), at: 0)
            }
            add(.error, String(localized: "“\(label)” has entries V2Mac cannot read"),
                String(localized: "Ignored until fixed: \(texts(unreadable))"), fixes, preselected: true)
        }
        if !rewrite.isEmpty {
            add(.warning, String(localized: "“\(label)” shows working entries as not understood"),
                String(localized: "They work, but in an old form: \(texts(rewrite.map(\.0)))"),
                [DoctorFix(title: String(localized: "Rewrite them"), changesRouting: false,
                           edits: rewrite.map { .replaceItems(rule.id, remove: [$0.0], add: $0.1) })])
        }
        if !unusable.isEmpty {
            add(.error, String(localized: "“\(label)” has entries the core cannot use"),
                String(localized: "A list that is not in the geo files, or a pattern the core cannot compile, can stop it from starting: \(texts(unusable))"),
                [fix(String(localized: "Remove them"), .removeItems(rule.id, unusable))])
        }
        if !broad.isEmpty {
            add(.warning, String(localized: "“\(label)” has very short keywords"),
                String(localized: "These match far more sites than intended: \(texts(broad))"),
                [fix(String(localized: "Remove them"), routing: true, .removeItems(rule.id, broad))])
        }
        if !gone.isEmpty {
            add(.warning, String(localized: "“\(label)” names apps that are not on this Mac"),
                String(localized: "They match nothing: \(texts(gone))"),
                [fix(String(localized: "Remove them"), .removeItems(rule.id, gone))], preselected: false)
        }
        let local = rule.items.filter(TidyUp.isCoveredByBuiltIns)
        if !local.isEmpty {
            removable.formUnion(local)
            add(.simplify, String(localized: "“\(label)” lists local addresses"),
                String(localized: "Local network goes direct before any rule, so these never reach it: \(texts(local))"),
                [fix(String(localized: "Remove them"), .removeItems(rule.id, local))])
        }
    }

    private mutating func checkConditions(_ rule: Rule, _ label: String) {
        let only = rule.only
        let udpOnly: [Rule.Sniffed] = [.quic], tcpOnly: [Rule.Sniffed] = [.tls, .http]
        if !only.protocols.isEmpty,
           (only.network == .tcp && only.protocols.allSatisfy(udpOnly.contains)) || (only.network == .udp && only.protocols.allSatisfy(tcpOnly.contains)) {
            add(.error, String(localized: "“\(label)” can never match"),
                String(localized: "Its network and protocol conditions contradict each other: QUIC runs over UDP, TLS and HTTP over TCP."),
                [fix(String(localized: "Remove the network condition"), routing: true, .clearNetwork(rule.id)),
                 fix(String(localized: "Delete the rule"), .deleteRule(rule.id))], preselected: false)
        }
        if !only.apps.isEmpty, AppMatchers(parsing: only.apps.joined(separator: "\n"), apps: input.apps).processes.isEmpty {
            add(.error, String(localized: "“\(label)” is left out: none of its “Only when” apps are on this Mac"),
                String(localized: "Removing the condition makes the rule apply to every app."),
                [fix(String(localized: "Turn the rule off"), .turnOff(rule.id)),
                 fix(String(localized: "Remove the app condition"), routing: true, .clearOnlyApps(rule.id))], preselected: false)
        }
        let isQUIC = only.protocols == [.quic] || (only.network == .udp && only.ports.trimmingCharacters(in: .whitespaces) == "443")
        if input.blockQUIC, input.mode != .direct, rule.enabled, isQUIC, rule.action != .block {
            add(.conflict, String(localized: "Block QUIC stops “\(label)” from ever matching"),
                String(localized: "It refuses UDP 443 before your rules are checked."),
                [fix(String(localized: "Turn off Block QUIC"), routing: true, .turnOffBlockQUIC),
                 fix(String(localized: "Delete the rule"), .deleteRule(rule.id))], preselected: false)
        } else if input.blockQUIC, input.mode != .direct, rule.enabled, isQUIC {
            add(.simplify, String(localized: "“\(label)” repeats Block QUIC"), String(localized: "The built-in rule already blocks this traffic first."),
                [fix(String(localized: "Delete the rule"), .deleteRule(rule.id))])
        }
    }

    private mutating func checkVia(_ rule: Rule, _ label: String) {
        guard case .via(let via) = rule.action else { return }
        if let targets = input.targets, targets[via.target] == nil {
            var fixes = [fix(String(localized: "Use the connected server"), routing: true, .setAction(rule.id, .proxy)),
                         fix(String(localized: "Delete the rule"), routing: true, .deleteRule(rule.id))]
            if let same = targets.first(where: { $0.value == via.name && sameKind($0.key, via.target) })?.key {
                var new = via
                new.target = same
                fixes.insert(fix(String(localized: "Link it to “\(via.name)” on this Mac"), routing: true, .setAction(rule.id, .via(new))), at: 0)
            }
            add(.error, String(localized: "“\(label)” uses “\(via.name)”, which is not on this Mac"),
                via.fallsBack ? String(localized: "Its traffic uses the current server.") : String(localized: "Its traffic is blocked."),
                fixes, preselected: fixes.count == 3)
        } else if input.failingTargets.contains(via.target), !via.fallsBack {
            var new = via
            new.fallsBack = true
            add(.warning, String(localized: "No server of “\(via.name)” answers"),
                String(localized: "“\(label)” fails closed: its traffic stops until one does."),
                [fix(String(localized: "Fall back to the connected server"), routing: true, .setAction(rule.id, .via(new)))], preselected: false)
        }
    }

    private func sameKind(_ a: Rule.Via.Target, _ b: Rule.Via.Target) -> Bool {
        switch (a, b) {
        case (.server, .server), (.group, .group): true
        default: false
        }
    }

    /// In TUN mode the core cannot see apps: what an app reaches must be named by host instead.
    private mutating func checkTun(_ rule: Rule, _ label: String) {
        var edits: [DoctorEdit] = [], names: [String] = []
        for item in rule.items {
            guard case .app(let entry) = item else { continue }
            var hosts = Set(seen(entry).compactMap { EntryGroups.registeredDomain(ofHost: $0) }.map { Rule.Item.host("domain:" + $0) })
            if let stem = stem(entry), input.geo.containsList("geosite:" + stem) { hosts = [.host("geosite:" + stem)] }
            guard !hosts.isEmpty else { continue }
            edits.append(.replaceItems(rule.id, remove: [item], add: hosts.sorted { $0.text < $1.text }))
            names.append(entry)
        }
        add(.warning, String(localized: "“\(label)” matches apps, which TUN mode cannot see"),
            edits.isEmpty ? String(localized: "It applies only to apps set to use the proxy port. Use the app with this window open, then run the Doctor again to replace it with the hosts it reaches.")
                : String(localized: "It applies only to apps set to use the proxy port. Hosts make it work for every connection."),
            edits.isEmpty ? [] : [DoctorFix(title: String(localized: "Replace \(names.joined(separator: ", ")) with the hosts it reaches"), changesRouting: true, edits: edits)],
            preselected: false)
    }

    /// The app's name as a brand ("Spotify.app" → "spotify"), when it is one word.
    func stem(_ entry: String) -> String? {
        guard let app = installed(entry) else { return nil }
        let name = app.name.replacingOccurrences(of: ".app", with: "")
        return name.contains(" ") ? nil : name
    }

    func seen(_ entry: String) -> Set<String> {
        let processes = AppMatchers.processes(for: entry, apps: input.apps)
        return input.seenHosts.reduce(into: []) { out, pair in
            if processes.contains(where: { RuleTester.processMatches($0, pair.key + "/") || RuleTester.processMatches($0, pair.key) }) { out.formUnion(pair.value) }
        }
    }

    // MARK: Rules against each other

    /// Whether every connection meeting `narrow` also meets `wide`. App items ignore "Only when" apps (`Rule.xrayRules`).
    func implies(_ narrow: Rule.OnlyWhen, _ wide: Rule.OnlyWhen, forApp: Bool) -> Bool {
        if let n = wide.network, n != narrow.network { return false }
        if !wide.protocols.isEmpty, narrow.protocols.isEmpty || !Set(narrow.protocols).isSubset(of: wide.protocols) { return false }
        if !forApp, !wide.apps.isEmpty, narrow.apps.isEmpty || !Set(narrow.apps).isSubset(of: wide.apps) { return false }
        let widePorts = wide.ports.replacingOccurrences(of: " ", with: "")
        guard !widePorts.isEmpty else { return true }
        let narrowPorts = narrow.ports.replacingOccurrences(of: " ", with: "")
        guard !narrowPorts.isEmpty, Rule.OnlyWhen.validPorts(narrowPorts) else { return false }
        return Self.ranges(narrowPorts).allSatisfy { r in Self.ranges(widePorts).contains { $0.lowerBound <= r.lowerBound && r.upperBound <= $0.upperBound } }
    }

    static func ranges(_ ports: String) -> [ClosedRange<Int>] {
        ports.split(separator: ",").compactMap { part in
            let ends = part.split(separator: "-").compactMap { Int($0) }
            guard let low = ends.first, let high = ends.last, low <= high else { return nil }
            return low...high
        }
    }

    mutating func checkCoverage() {
        var earlier = CoverIndex(geo: input.geo)
        var catchAlls: [Int] = []
        for (i, rule) in rules.enumerated() where live.contains(rule.id) {
            var own = CoverIndex(geo: input.geo)
            for item in rule.items { for e in entries(item) { own.add(e, owner: i, sets: &sets) } }
            var inside: [Rule.Item] = [], repeats: [Rule.Item] = [], byRule: [Int: [Rule.Item]] = [:], seenItems = Set<Rule.Item>()
            for item in rule.items {
                if !seenItems.insert(item).inserted { repeats.append(item); continue }
                if TidyUp.isCoveredByBuiltIns(item) { continue }
                let parts = entries(item)
                guard !parts.isEmpty else { continue }
                if parts.allSatisfy({ part in own.coverers(of: part).contains { $0.by != part } }) { inside.append(item); continue }
                let forApp = item.isApp
                let candidates = parts.map { part in
                    Set(earlier.coverers(of: part).map(\.owner).filter { implies(rule.only, rules[$0].only, forApp: forApp) })
                        .union(catchAlls.filter { implies(rule.only, rules[$0].only, forApp: forApp) })
                }
                // One earlier rule must take every part of the item, the first that does.
                if let first = candidates.dropFirst().reduce(candidates[0], { $0.intersection($1) }).min() { byRule[first, default: []].append(item) }
            }
            if !inside.isEmpty || !repeats.isEmpty {
                removable.formUnion(inside)
                var edits: [DoctorEdit] = repeats.isEmpty ? [] : [.dropRepeats(rule.id)]
                if !inside.isEmpty { edits.append(.removeItems(rule.id, inside)) }
                add(.simplify, String(localized: "“\(name(rule))” repeats itself"),
                    String(localized: "Already covered by other entries in the same rule: \(texts(inside + repeats))"),
                    [DoctorFix(title: String(localized: "Remove the extra entries"), changesRouting: false, edits: edits)])
            }
            if rule.items.isEmpty, let first = catchAlls.first(where: { implies(rule.only, rules[$0].only, forApp: false) }) {
                add(rules[first].action == rule.action ? .simplify : .conflict,
                    String(localized: "“\(name(rule))” never matches: “\(name(rules[first]))” takes all its traffic first"),
                    String(localized: "“\(name(rules[first]))” comes earlier and matches everything this rule would."),
                    [fix(String(localized: "Delete “\(name(rule))”"), .deleteRule(rule.id))])
            }
            for j in byRule.keys.sorted() { report(rule, covered: byRule[j]!, by: rules[j]) }
            if rule.items.isEmpty { catchAlls.append(i) }
            for item in rule.items { for e in entries(item) { earlier.add(e, owner: i, sets: &sets) } }
            for case .country(let code) in rule.items {
                for e in CountryRuleOptions().rules(for: code, siteTags: siteTags) { earlier.add(e, owner: i, sets: &sets) }
            }
        }
    }

    /// Narrow entries above a wider entry doing the same thing: with nothing between them that could
    /// route the traffic elsewhere, the wide one alone gives the same result.
    mutating func checkWiderBelow() {
        guard rules.count <= 400 else { return }
        for (i, rule) in rules.enumerated() where live.contains(rule.id) && !rule.items.isEmpty {
            var left = rule.items.filter { !$0.isApp && !removable.contains($0) }
            for j in rules.indices.dropFirst(i + 1) where live.contains(rules[j].id) && !left.isEmpty {
                let later = rules[j]
                if later.action != rule.action {
                    if mayOverlap(rule, later) { break }
                    continue
                }
                guard !later.items.isEmpty, implies(rule.only, later.only, forApp: false) else { continue }
                var index = CoverIndex(geo: input.geo)
                for e in later.items.flatMap(entries) { index.add(e, owner: j, sets: &sets) }
                let covered = left.filter { item in
                    let parts = entries(item)
                    return !parts.isEmpty && parts.allSatisfy { !index.coverers(of: $0).isEmpty }
                }
                guard !covered.isEmpty else { continue }
                left.removeAll(where: covered.contains)
                removable.formUnion(covered)
                let all = covered.count == rule.items.count
                add(.simplify,
                    all ? String(localized: "“\(name(rule))” does nothing: “\(name(later))” already covers it")
                        : String(localized: "“\(name(later))” already covers part of “\(name(rule))”"),
                    String(localized: "“\(name(later))” further down sends them to \(title(rule.action)) too, and nothing in between routes them elsewhere: \(texts(covered))"),
                    [all ? fix(String(localized: "Delete “\(name(rule))”"), .deleteRule(rule.id))
                         : fix(String(localized: "Remove the extra entries"), .removeItems(rule.id, covered))])
            }
        }
    }

    private mutating func report(_ rule: Rule, covered: [Rule.Item], by first: Rule) {
        removable.formUnion(covered)
        let all = covered.count == rule.items.count
        if first.action == rule.action {
            add(.simplify,
                all ? String(localized: "“\(name(rule))” does nothing: “\(name(first))” already covers it")
                    : String(localized: "“\(name(first))” already covers part of “\(name(rule))”"),
                String(localized: "Both send it to \(title(rule.action)), and the earlier rule wins: \(texts(covered))"),
                [all ? fix(String(localized: "Delete “\(name(rule))”"), .deleteRule(rule.id))
                     : fix(String(localized: "Remove the extra entries"), .removeItems(rule.id, covered))])
            return
        }
        let detail = String(localized: "“\(name(first))” comes earlier and sends these to \(title(first.action)), so they never reach \(title(rule.action)): \(texts(covered))")
        let keep = fix(String(localized: "Keep today's routing and remove them from “\(name(rule))”"), .removeItems(rule.id, covered))
        if covered.allSatisfy(first.items.contains) {
            add(.conflict, String(localized: "“\(name(rule))” and “\(name(first))” claim the same entries"), detail,
                [keep, fix(String(localized: "Let “\(name(rule))” have them instead"), routing: true, .removeItems(first.id, covered))])
        } else {
            // A narrower entry below a wider one is almost always meant as an exception to it.
            let exception = Rule(name: String(localized: "\(name(rule)) (exception)"), action: rule.action, items: covered, only: rule.only)
            add(.conflict, String(localized: "“\(name(first))” hides entries of “\(name(rule))”"), detail,
                [fix(String(localized: "Make them an exception above “\(name(first))”"), routing: true, .insert(exception, before: first.id), .removeItems(rule.id, covered)), keep])
        }
    }

    // MARK: Summarising

    private struct Member { let rule: Int; let item: Rule.Item; let host: String }

    /// A plain host item's name, unless another finding already removes it.
    private func plainHost(_ item: Rule.Item) -> String? {
        guard !removable.contains(item), case .host = item else { return nil }
        let parts = entries(item)
        guard parts.count == 1 else { return nil }
        for prefix in ["domain:", "full:"] where parts[0].hasPrefix(prefix) { return String(parts[0].dropFirst(prefix.count)) }
        return nil
    }

    /// Would moving `hosts` up to rule `target`, wider, take traffic from a rule that routes elsewhere?
    private mutating func wouldHide(_ action: Rule.Action, after target: Int, hosts: [String], parent: String?) -> Bool {
        for rule in rules[(target + 1)...] where live.contains(rule.id) && rule.action != action {
            if rule.items.isEmpty { return true }
            for item in rule.items where !item.isApp {
                for entry in entries(item) {
                    if entry.hasPrefix("keyword:") || entry.hasPrefix("regexp:") { return true }
                    if entry.hasPrefix("geosite:") || entry.hasPrefix("ext:") {
                        if let set = SiteSet.make(entry, geo: input.geo, cache: &sets), !hosts.contains(where: set.touches) { continue }
                        return true
                    }
                    let name = entry.hasPrefix("domain:") ? String(entry.dropFirst(7)) : entry.hasPrefix("full:") ? String(entry.dropFirst(5)) : nil
                    guard let name else { continue }
                    let roots = parent.map { [$0] } ?? hosts
                    if roots.contains(where: { name == $0 || name.hasSuffix("." + $0) || $0.hasSuffix("." + name) }) { return true }
                }
            }
        }
        return false
    }

    mutating func checkRollUps() {
        // Rules that do the same thing are one pool: hosts spread over them still roll up.
        var pools: [String: [Member]] = [:]
        var order: [String] = []
        var services = Set<Rule.Item>()
        checkServices(&services)
        for (i, rule) in rules.enumerated() where live.contains(rule.id) {
            for item in rule.items where !services.contains(item) {
                guard let host = plainHost(item), let parent = EntryGroups.registeredDomain(ofHost: host), parent != host,
                      !RuleDoctor.sharedDomains.contains(parent) else { continue }
                let key = "\(rule.action)|\(rule.only)|\(parent)"
                if pools[key] == nil { order.append(key) }
                pools[key, default: []].append(Member(rule: i, item: item, host: host))
            }
        }
        for key in order {
            let members = pools[key]!
            guard Set(members.map(\.host)).count >= 2, let first = members.first else { continue }
            let parent = EntryGroups.registeredDomain(ofHost: first.host)!
            let rule = rules[first.rule]
            guard !wouldHide(rule.action, after: first.rule, hosts: members.map(\.host), parent: parent) else { continue }
            var edits: [DoctorEdit] = [.replaceItems(rule.id, remove: members.filter { $0.rule == first.rule }.map(\.item), add: [.host("domain:" + parent)])]
            for other in Set(members.map(\.rule)).subtracting([first.rule]).sorted() {
                edits.append(.removeItems(rules[other].id, members.filter { $0.rule == other }.map(\.item)))
            }
            add(.simplify, String(localized: "Replace \(members.count) hosts with one entry: \(parent)"),
                String(localized: "“\(name(rule))” then covers all of \(parent): \(texts(members.map(\.item)))"),
                [DoctorFix(title: String(localized: "Use \(parent) and all its subdomains"), changesRouting: true, edits: edits)], preselected: false)
        }
    }

    /// Lists too general to stand for one service.
    private static func isServiceList(_ tag: String) -> Bool {
        !tag.contains("category-") && !tag.contains("geolocation-") && !tag.contains("tld-") && !tag.contains("!") && tag != "private"
    }

    private mutating func checkServices(_ used: inout Set<Rule.Item>) {
        let candidates = rules.enumerated().filter { live.contains($0.element.id) && $0.element.items.compactMap(plainHost).count >= 3 }
        guard !candidates.isEmpty, !siteTags.isEmpty else { return }
        // Every name to the service lists that hold it, smallest list first when one must be picked.
        var lists: [String: [String]] = [:]
        for tag in siteTags where Self.isServiceList(tag) {
            guard let list = input.geo.sites["geosite.dat:" + tag], list.count <= 3000 else { continue }
            for entry in list where entry.kind == .domain || entry.kind == .full { lists[entry.value, default: []].append(tag) }
        }
        for (i, rule) in candidates {
            var hits: [String: [Rule.Item]] = [:], hosts: [Rule.Item: String] = [:]
            for item in rule.items {
                guard let host = plainHost(item) else { continue }
                hosts[item] = host
                var name = Substring(host), tags = Set<String>()
                while true {
                    tags.formUnion(lists[String(name)] ?? [])
                    guard let dot = name.firstIndex(of: ".") else { break }
                    name = name[name.index(after: dot)...]
                }
                for tag in tags { hits[tag, default: []].append(item) }
            }
            let best = hits.filter { $0.value.count >= 3 }.max {
                ($0.value.count, -(input.geo.sites["geosite.dat:" + $0.key]?.count ?? 0), $1.key) < ($1.value.count, -(input.geo.sites["geosite.dat:" + $1.key]?.count ?? 0), $0.key)
            }
            guard let best, !rule.items.contains(.host("geosite:" + best.key)),
                  !wouldHide(rule.action, after: i, hosts: best.value.compactMap { hosts[$0] }, parent: nil) else { continue }
            used.formUnion(best.value)
            add(.simplify, String(localized: "Replace \(best.value.count) hosts with the “\(best.key)” list"),
                String(localized: "“\(name(rule))” then follows the service's own list, updated with the geo files: \(texts(best.value))"),
                [DoctorFix(title: String(localized: "Use the “\(best.key)” list"), changesRouting: true,
                           edits: [.replaceItems(rule.id, remove: best.value, add: [.host("geosite:" + best.key)])])], preselected: false)
        }
    }

    /// An app whose traffic the hosts of rules doing the same thing already catch: the hosts alone are
    /// simpler, and work in TUN mode as well.
    mutating func checkApps() {
        for rule in rules where live.contains(rule.id) && rule.only.isEmpty {
            let same = rules.filter { live.contains($0.id) && $0.action == rule.action && $0.only.isEmpty }
            var hosts = CoverIndex(geo: input.geo)
            let hostEntries = same.flatMap(\.items).filter { !$0.isApp }.flatMap(entries)
            guard !hostEntries.isEmpty else { continue }
            for e in hostEntries { hosts.add(e, owner: 0, sets: &sets) }
            for case .app(let entry) in rule.items where !isMissingApp(entry) {
                let visited = seen(entry)
                let evidence = !visited.isEmpty && visited.allSatisfy { h in
                    !hosts.coverers(of: RuleMatchers.isIP(h) ? h : "full:" + h.lowercased()).isEmpty
                }
                let brand = stem(entry)
                let byName = brand.map { b in
                    hostEntries.contains { $0 == "geosite:" + b || EntryGroups.brand(ofHost: $0.split(separator: ":").last.map(String.init) ?? "") == b }
                } ?? false
                guard evidence || (visited.isEmpty && byName) else { continue }
                let label = input.apps.first { $0 == installed(entry) }.map { ($0.path as NSString).lastPathComponent } ?? entry
                add(.simplify, String(localized: "“\(name(rule))” doesn't need \(label): hosts already cover it"),
                    evidence ? String(localized: "All \(visited.count) hosts it connected to while this window was open are in your \(title(rule.action)) rules.")
                             : String(localized: "A \(title(rule.action)) rule already has its service. Any other host it uses stops matching."),
                    [fix(String(localized: "Remove the app"), routing: true, .removeItems(rule.id, [.app(entry)]))], preselected: false)
            }
        }
    }

    mutating func checkTidyRules() {
        for suggestion in TidyUp.merges(rules) {
            guard case .merge(let into, let from, let new) = suggestion.kind,
                  let a = rules.first(where: { $0.id == into }), let b = rules.first(where: { $0.id == from }) else { continue }
            add(.simplify, String(localized: "Merge “\(name(a))” and “\(name(b))” into “\(new)”"),
                String(localized: "One has the apps, the other the hosts; one rule with both does the same."),
                [fix(String(localized: "Merge them"), .merge(into: into, from: [from], name: new))])
        }
        for rule in rules where live.contains(rule.id) {
            for suggestion in TidyUp.collapses(rule, installed: input.apps) {
                guard case .collapseApps(let id, let items, let bundleID) = suggestion.kind else { continue }
                add(.simplify, String(localized: "Collapse \(items.count) spellings of one app in “\(name(rule))”"),
                    String(localized: "\(items.joined(separator: ", ")) → \(bundleID). It stops matching a program of the same name outside the app."),
                    [fix(String(localized: "Collapse them"), routing: true, .replaceItems(id, remove: items.map(Rule.Item.app), add: [.app(bundleID)]))], preselected: false)
            }
        }
        for rule in rules where !rule.enabled {
            if let twin = rules.first(where: { $0.enabled && $0.action == rule.action && $0.items == rule.items && $0.only == rule.only }) {
                add(.simplify, String(localized: "“\(name(rule))” is off and the same as “\(name(twin))”"),
                    String(localized: "Turning it on would change nothing."), [fix(String(localized: "Delete “\(name(rule))”"), .deleteRule(rule.id))])
            }
        }
        // Rules at the end that send traffic where it would go anyway.
        guard let route = input.defaultRoute else { return }
        var trailing: [Rule] = []
        for rule in rules.reversed() where rule.enabled {
            guard rule.action == route else { break }
            if live.contains(rule.id) { trailing.append(rule) }
        }
        if !trailing.isEmpty {
            let names = trailing.reversed().map(name).joined(separator: ", ")
            add(.simplify, String(localized: "Rules at the end change nothing right now"),
                String(localized: "Unmatched traffic goes to \(title(route)) anyway. They matter again if the routing mode or Everything Else changes: \(names)"),
                [DoctorFix(title: String(localized: "Delete them"), changesRouting: false, edits: trailing.map { .deleteRule($0.id) })], preselected: false)
        }
    }

    // MARK: Organizing

    /// Whether some connection could match both rules, so their order matters. Errs towards yes.
    private mutating func mayOverlap(_ a: Rule, _ b: Rule) -> Bool {
        if let x = a.only.network, let y = b.only.network, x != y { return false }
        let pa = a.only.ports.replacingOccurrences(of: " ", with: ""), pb = b.only.ports.replacingOccurrences(of: " ", with: "")
        if !pa.isEmpty, !pb.isEmpty, !Self.ranges(pa).contains(where: { r in Self.ranges(pb).contains(where: { r.overlaps($0) }) }) { return false }
        if a.items.isEmpty || b.items.isEmpty { return true }
        if a.items.allSatisfy(\.isApp), b.items.allSatisfy(\.isApp) {
            return !Set(a.items.flatMap(entries)).isDisjoint(with: b.items.flatMap(entries))
        }
        if a.items.contains(where: \.isApp) || b.items.contains(where: \.isApp) { return true }
        let ea = a.items.flatMap(entries), eb = b.items.flatMap(entries)
        for (x, y) in [(ea, eb), (eb, ea)] {
            var index = CoverIndex(geo: input.geo)
            for e in x { index.add(e, owner: 0, sets: &sets) }
            if y.contains(where: { !index.coverers(of: $0).isEmpty }) { return true }
        }
        func isIP(_ e: String) -> Bool { RuleMatchers.isIP(e) || e.hasPrefix("geoip:") || e.hasPrefix("country:") || (e.hasPrefix("ext:") && e.contains("ip")) }
        func isPlain(_ e: String) -> Bool { e.hasPrefix("domain:") || e.hasPrefix("full:") }
        // A name resolves to some address, and a keyword or pattern can hit any name.
        if ea.contains(where: isIP) != eb.contains(where: isIP) || ea.contains(where: { !isIP($0) }) && eb.contains(where: isIP) { return true }
        if ea.allSatisfy(isIP), eb.allSatisfy(isIP) { return !ea.allSatisfy(RuleMatchers.isIP) || !eb.allSatisfy(RuleMatchers.isIP) ? true : false }
        for (x, y) in [(ea, eb), (eb, ea)] where x.contains(where: { !isPlain($0) }) {
            for entry in x where !isPlain(entry) {
                guard entry.hasPrefix("geosite:") || entry.hasPrefix("ext:"), !entry.contains("@"),
                      let set = SiteSet.make(entry, geo: input.geo, cache: &sets), y.allSatisfy(isPlain) else { return true }
                if y.contains(where: { set.touches(String($0.split(separator: ":").last ?? "")) }) { return true }
            }
        }
        // Two plain names overlap only when one is inside the other, which the index answered.
        return false
    }

    mutating func checkOrganizing() {
        let unnamed = rules.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.name == String(localized: "New rule") }
        let renames = unnamed.compactMap { rule -> DoctorEdit? in
            guard let first = rule.items.first else { return nil }
            return .rename(rule.id, rule.items.count > 1 ? String(localized: "\(first.text) and \(rule.items.count - 1) more") : first.text)
        }
        if !renames.isEmpty {
            add(.organize, String(localized: "Name rules after what they match"), String(localized: "They have no name of their own, which makes the list harder to read."),
                [DoctorFix(title: String(localized: "Name them"), changesRouting: false, edits: renames)])
        }
        // shortcut: pairwise rule checks are skipped past 400 rules; merge some first, then this appears.
        guard rules.count > 1, rules.count <= 400 else { return }
        func rank(_ rule: Rule) -> Int {
            guard rule.enabled else { return 4 }
            return switch rule.action { case .block: 0; case .via: 1; case .proxy: 2; case .direct: 3 }
        }
        var before = [Set<Int>](repeating: [], count: rules.count)
        for j in rules.indices where rules[j].enabled {
            for i in rules[..<j].indices where rules[i].enabled && rules[i].action != rules[j].action {
                if mayOverlap(rules[i], rules[j]) { before[j].insert(i) }
            }
        }
        // Rules take their group's place unless a rule they could overlap must stay ahead of them.
        var placed: [Int] = [], left = Set(rules.indices)
        while !left.isEmpty {
            let ready = left.filter { before[$0].isSubset(of: placed) }
            let next = ready.min { (rank(rules[$0]), $0) < (rank(rules[$1]), $1) }!
            placed.append(next)
            left.remove(next)
        }
        if placed != Array(rules.indices) {
            add(.organize, String(localized: "Group the rules by what they do"),
                String(localized: "Block, Via, Proxy, Direct, then the ones that are off. Rules that could match the same traffic keep their order, so routing stays the same."),
                [DoctorFix(title: String(localized: "Reorder them"), changesRouting: false, edits: [.order(placed.map { rules[$0].id })])], preselected: false)
        }
        // Neighbours that do the same thing.
        var i = 0
        while i < rules.count {
            var j = i + 1
            if rules[i].enabled, !rules[i].items.isEmpty {
                while j < rules.count, rules[j].enabled, !rules[j].items.isEmpty, rules[j].action == rules[i].action, rules[j].only == rules[i].only { j += 1 }
            }
            if j - i >= 2 {
                let run = Array(rules[i..<j])
                let label = title(run[0].action)
                add(.organize, String(localized: "Merge \(run.count) neighbouring \(label) rules into one"),
                    String(localized: "They do the same thing, but separate rules are easier to turn on and off: \(run.map(name).joined(separator: ", "))"),
                    [DoctorFix(title: String(localized: "Merge them"), changesRouting: false,
                               edits: [.merge(into: run[0].id, from: run.dropFirst().map(\.id), name: label)])], preselected: false)
            }
            i = j
        }
    }
}
