import Foundation
import Testing
@testable import V2MacCore

@Suite struct KillSwitchTests {
    @Test func rulesAreValidPf() throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        check.arguments = ["-n", "-f", "-"]
        let input = Pipe()
        let output = Pipe()
        check.standardInput = input
        check.standardError = output
        check.standardOutput = output
        try check.run()
        // The helper writes the rules with a final newline, which pf needs.
        input.fileHandleForWriting.write(Data((KillSwitch.rules(tunInterface: "utun123") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check.waitUntilExit()
        #expect(check.terminationStatus == 0, "\(text)")
    }

    /// Golden copy (spec 9.8): a change to what passes must show up here.
    @Test func rulesPassExactlyTheAllowList() {
        #expect(KillSwitch.rules(tunInterface: "utun123") == """
        table <v2mac_allow> persist
        table <v2mac_dns> persist
        table <v2mac_lan> persist
        pass quick on lo0 all flags any no state
        pass out quick on utun123 all flags any no state
        pass out quick inet proto udp from any port 68 to any port 67 no state
        pass out quick inet6 proto udp from any port 546 to any port 547 no state
        pass out quick inet6 proto ipv6-icmp from any to { fe80::/10, ff02::/16 } icmp6-type { routersol, neighbrsol, neighbradv } no state
        pass out quick proto { tcp, udp } from any to <v2mac_dns> port 53 flags any no state
        pass out quick from any to <v2mac_lan> flags any no state
        pass out quick from any to <v2mac_allow> flags any no state
        block return out quick all
        """)
    }

    /// Runs `body` after the helper's kill switch functions, with `pfctl` and `ifconfig` stubs that
    /// log their arguments to `calls` and answer from files in the directory: `info`, `main`,
    /// `anchor`, `states`, `ifconfig` and `t-<table>` (one address per line, for `-T test`).
    private func runHelper(_ body: String, files: [String: String] = [:]) throws -> (dir: URL, calls: [String], output: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let pfctl = """
        #!/bin/sh
        D="\(dir.path)"
        echo "pfctl $*" >> "$D/calls"
        case "$*" in
          "-s info") cat "$D/info" ;;
          "-s rules") cat "$D/main" ;;
          "-a a -s rules") cat "$D/anchor" ;;
          "-s states") cat "$D/states" ;;
          "-E") echo "Token : 42" ;;
          *"-T test "*) grep -qxF "$7" "$D/t-$4" 2>/dev/null ;;
          *"-T replace -f -") cat > /dev/null ;;
        esac
        """
        let stubs = ["pfctl": pfctl, "ifconfig": "#!/bin/sh\ncat \"\(dir.path)/ifconfig\"\n"]
        for (tool, text) in stubs {
            let stub = bin.appendingPathComponent(tool)
            try text.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        let script = """
        PATH="\(bin.path):/usr/bin:/bin"; STATE_DIR="\(dir.path)"; ROOT_DIR="\(dir.path)"; KS_ANCHOR=a; KS_MARKER="\(dir.path)/marker"
        KS_RULES=rules
        \(TunHelper.killSwitchFunctions)
        \(body)
        """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        let calls = (try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (dir, calls, output)
    }

    /// The helper checks the lists on every turn of its loop: unchanged, they start no process.
    @Test func tablesAreReloadedOnlyWhenAListChanges() throws {
        let (dir, calls, _) = try runHelper("""
        echo 1.2.3.4 > "$STATE_DIR/killswitch.allow"
        printf '192.168.1.1\\nnot an address\\n' > "$STATE_DIR/killswitch.dns"
        ks_allow; ks_allow; ks_allow
        echo 5.6.7.8 >> "$STATE_DIR/killswitch.allow"
        ks_allow; ks_allow
        touch "$STATE_DIR/killswitch.blocklan"
        ks_allow; ks_allow
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(calls.filter { $0.contains("-t v2mac_allow -T replace") }.count == 3)
        #expect(calls.filter { $0.contains("-t v2mac_dns -T replace") }.count == 3)
        #expect(calls.filter { $0.contains("-t v2mac_lan -T replace") }.count == 2)
        #expect(calls.last == "pfctl -a a -t v2mac_lan -T flush")
        #expect(try String(contentsOf: dir.appendingPathComponent("allow"), encoding: .utf8) == "1.2.3.4\n5.6.7.8\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("dns"), encoding: .utf8) == "192.168.1.1\n")
    }

    /// Spec 9.8, F02: the state the app shows is pf read back, and a change under the block
    /// turns it into an error that re-arms.
    @Test func readBackReportsWhatPfEnforces() throws {
        let main = "anchor \"com.apple/*\" all\n"
        let (dir, _, output) = try runHelper("""
        ks_armed=1; ks_digest=$(pfctl -a a -s rules | shasum)
        ks_check; echo "$ks_armed $(cat "$ROOT_DIR/killswitch.status")"
        echo "pass out all" >> "$ROOT_DIR/anchor"
        ks_check; echo "$ks_armed $(cat "$ROOT_DIR/killswitch.status")"
        ks_armed=1; : > "$ROOT_DIR/anchor"
        ks_check; echo "$ks_armed $(cat "$ROOT_DIR/killswitch.status")"
        ks_armed=1; echo "Status: Disabled" > "$ROOT_DIR/info"
        ks_check; echo "$ks_armed $(cat "$ROOT_DIR/killswitch.status")"
        echo "Status: Enabled" > "$ROOT_DIR/info"; echo "" > "$ROOT_DIR/main"
        ks_check; echo "$ks_armed $(cat "$ROOT_DIR/killswitch.status")"
        """, files: ["info": "Status: Enabled for 0 days\n", "main": main, "anchor": "block return out quick all\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(output.split(separator: "\n") == [
            "1 armed",
            "broken The kill switch's firewall rules were changed or removed.",
            "broken The kill switch's firewall rules were changed or removed.",
            "broken The firewall was turned off.",
            "broken The firewall's main rules no longer include Apple's anchors.",
        ])
    }

    /// Spec 9.8, F02: arming kills the flows pf tracks whose far end the block refuses, one pair
    /// of hosts at a time, and leaves the TUN's, loopback's and allowed ones alone.
    @Test func armingKillsOnlyTheFlowsTheBlockRefuses() throws {
        let states = """
        ALL tcp 192.168.1.5:50000 -> 203.0.113.9:443       ESTABLISHED:ESTABLISHED
        ALL tcp 192.168.1.5:50001 -> 198.51.100.7:443       ESTABLISHED:ESTABLISHED
        ALL udp 192.168.1.5:5353 -> 192.168.1.1:53       MULTIPLE:SINGLE
        ALL tcp 198.18.0.1:40000 -> 93.184.216.34:80       ESTABLISHED:ESTABLISHED
        ALL tcp 127.0.0.1:1000 -> 127.0.0.1:2000       ESTABLISHED:ESTABLISHED
        ALL tcp 2001:db8::5[50000] -> 2001:db8::99[443]       ESTABLISHED:ESTABLISHED
        ALL tcp 192.168.1.5:22 <- 203.0.113.50:6000       ESTABLISHED:ESTABLISHED

        """
        let ifconfig = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        \tinet6 ::1 prefixlen 128
        \tinet6 fe80::1%lo0 prefixlen 64 scopeid 0x1
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.1.5 netmask 0xffffff00 broadcast 192.168.1.255
        utun100: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        \tinet 198.18.0.1 --> 198.18.0.1 netmask 0xffffffff

        """
        let (dir, calls, _) = try runHelper("""
        echo 198.51.100.7 > "$STATE_DIR/killswitch.allow"
        ks_arm; echo "$ks_armed" > "$ROOT_DIR/armed"
        """, files: ["info": "Status: Enabled\n", "main": "anchor \"com.apple/*\" all\n", "anchor": "block return out quick all\n",
                     "states": states, "ifconfig": ifconfig, "t-v2mac_allow": "198.51.100.7\n", "t-v2mac_lan": "192.168.1.1\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(calls.filter { $0.hasPrefix("pfctl -k") } == [
            "pfctl -k 192.168.1.5 -k 203.0.113.9",
            "pfctl -k 2001:db8::5 -k 2001:db8::99",
            "pfctl -k 192.168.1.5 -k 203.0.113.50",
        ])
        #expect(!calls.contains { $0.contains("-F") && !$0.contains("-a a") })
        #expect(try String(contentsOf: dir.appendingPathComponent("armed"), encoding: .utf8) == "1\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("killswitch.status"), encoding: .utf8) == "armed\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("marker"), encoding: .utf8) == "42\n")
    }

    @Test func hostsOfAnOutboundAndOfAFullConfig() {
        let outbound: JSONValue = ["protocol": "vless", "settings": ["vnext": [["address": "a.example.com", "port": 443]]]]
        #expect(KillSwitch.hosts(in: outbound, kind: .outbound) == ["a.example.com"])
        let custom: JSONValue = ["outbounds": [
            ["protocol": "trojan", "settings": ["servers": [["address": "203.0.113.7", "port": 443]]]],
            ["protocol": "wireguard", "settings": ["peers": [["endpoint": "[2001:db8::1]:51820"], ["endpoint": "wg.example.com:51820"]]]],
            ["protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": 9050]]]],
            ["protocol": "freedom"],
        ]]
        #expect(KillSwitch.hosts(in: custom, kind: .custom) == ["2001:db8::1", "203.0.113.7", "wg.example.com"])
    }

    @Test func addressesKeepLiteralsAndResolveNames() async {
        let found = await KillSwitch.addresses(of: ["203.0.113.7", "2001:db8::1", "localhost"])
        #expect(found.contains("203.0.113.7"))
        #expect(found.contains("2001:db8::1"))
        #expect(found.contains("127.0.0.1"))
        #expect(found.allSatisfy { !$0.contains("%") })
    }
}

@Suite struct SystemProxyTests {
    @Test func stateOfTheSettings() {
        #expect(SystemProxy.state(of: [:], port: 10808) == .none)
        #expect(SystemProxy.state(of: ["HTTPEnable": 0, "SOCKSEnable": 0], port: 10808) == .none)
        let ours: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 10808,
                                   "SOCKSEnable": 1, "SOCKSProxy": "localhost", "SOCKSPort": 10808]
        #expect(SystemProxy.state(of: ours, port: 10808) == .ours)
        #expect(SystemProxy.state(of: ours, port: 10809) == .other)
        var mixed = ours
        mixed["HTTPSEnable"] = 1
        mixed["HTTPSProxy"] = "10.0.0.2"
        mixed["HTTPSPort"] = 3128
        #expect(SystemProxy.state(of: mixed, port: 10808) == .other)
        #expect(SystemProxy.state(of: ["ProxyAutoConfigEnable": 1], port: 10808) == .other)
    }
}
