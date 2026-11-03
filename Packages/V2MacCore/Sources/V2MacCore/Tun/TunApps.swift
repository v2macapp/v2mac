import Foundation

/// App rules in TUN mode (spec 9.5). The core sees every TUN connection coming from the root
/// forwarder, so the forwarder, which still sees the real app, looks it up: it has one `process`
/// rule per app entry the core's rules name, and reaches the core's `tun-in` as a SOCKS user
/// named after the entry that matched. The core's rules then match those users.
///
/// Only these entries reach root: the forwarder builds its rules from them (`awkProgram`), never
/// from a rule or a server config.
public enum TunApps {
    /// The list's file in the helper's request directory, one entry per line.
    public static let file = "tun.apps"
    /// The SOCKS user for a connection no app entry matched. Never an entry (`isUsable`).
    static let noApp = "*"
    /// Not a secret: `tun-in` listens on loopback for this Mac's own processes, as before.
    static let password = "v2mac"
    static let limit = 512

    /// What root accepts: a SOCKS username (at most 255 bytes) with nothing that needs escaping in
    /// JSON, so the forwarder's config can be written without an encoder.
    public static func isUsable(_ entry: String) -> Bool {
        !entry.isEmpty && entry != noApp && entry.utf8.count <= 255
            && !entry.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The entries the rules name, in the order the forwarder tries them: exact paths, then folders,
    /// deepest first, then names. The forwarder takes the first that matches, and a more specific
    /// entry implies the wider ones (`implies`), so the core still sees all of them.
    static func entries(in rules: [JSONValue]) -> [String] {
        var seen = Set<String>()
        let all = rules.flatMap { $0["process"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
            .filter { isUsable($0) && seen.insert($0).inserted }
        func rank(_ entry: String) -> Int { entry.hasSuffix("/") ? 1 : entry.hasPrefix("/") ? 0 : 2 }
        let sorted = all.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            if ra == 1, a.element.count != b.element.count { return a.element.count > b.element.count }
            return a.offset < b.offset
        }
        return Array(sorted.map(\.element).prefix(limit))
    }

    /// True when every app that matches `found` also matches `entry`, as Xray matches them
    /// (`RuleTester.processMatches`): the same entry, a folder holding it, or the name of its path.
    // shortcut: an app matching both a name and an unrelated folder arrives as the folder only, so a
    // rule naming just the name misses it in TUN mode; send a set of entries if users mix the two.
    static func implies(_ found: String, _ entry: String) -> Bool {
        if found == entry { return true }
        if entry.hasSuffix("/") { return found.hasPrefix("/") && found.hasPrefix(entry) }
        if entry.hasPrefix("/") { return false }
        return found.hasPrefix("/") && !found.hasSuffix("/") && (found as NSString).lastPathComponent == entry
    }

    /// `tun-in`'s accounts: one per entry, and the one for everything else.
    static func accounts(_ entries: [String]) -> JSONValue {
        .array(([noApp] + entries).map { ["user": .string($0), "pass": .string(password)] })
    }

    /// The forwarder's way into the core as `user`.
    static func coreOutbound(tag: String, user: String, corePort: Int) -> JSONValue {
        [
            "tag": .string(tag),
            "protocol": "socks",
            "settings": ["servers": [[
                "address": "127.0.0.1", "port": .number(Double(corePort)),
                "users": [["user": .string(user), "pass": .string(password)]],
            ]]],
            // `autoOutboundsInterface` would bind this to the physical interface, and UDP
            // to loopback bound there is dropped: DNS and every other UDP flow got lost.
            "streamSettings": ["sockopt": ["interface": "lo0"]],
        ]
    }

    /// Turns the list (standard input, one entry per line) into the forwarder's second config file:
    /// an outbound and a `process` rule per entry, then everything else to the base config's `core`.
    /// Lines `isUsable` refuses are skipped, so the file can't add anything but these. `awk -v port=`.
    public static let awkProgram = #"""
    NR > \#(limit) { exit }
    length($0) == 0 || length($0) > 255 || $0 == "\#(noApp)" || index($0, "\"") || index($0, "\\") || $0 ~ /[[:cntrl:]]/ { next }
    {
      n++
      outs = outs sprintf("{\"tag\":\"app-%d\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":%d,\"users\":[{\"user\":\"%s\",\"pass\":\"\#(password)\"}]}]},\"streamSettings\":{\"sockopt\":{\"interface\":\"lo0\"}}},", n, port, $0)
      rules = rules sprintf("{\"process\":[\"%s\"],\"outboundTag\":\"app-%d\"},", $0, n)
    }
    END {
      sub(/,$/, "", outs)
      printf "{\"outbounds\":[%s],\"routing\":{\"rules\":[%s{\"network\":\"tcp,udp\",\"outboundTag\":\"core\"}]}}\n", outs, rules
    }
    """#
}
