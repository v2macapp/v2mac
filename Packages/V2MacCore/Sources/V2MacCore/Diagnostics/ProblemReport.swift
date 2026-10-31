import Foundation

/// The text a user pastes into an issue: logs with everything identifying removed, and crash reports
/// reduced to fields that hold no user data. It stays on the Mac until the user posts it.
public enum ProblemReport {
    /// GitHub takes 65536 characters in an issue; sections are capped to stay under that.
    private static let logLimit = 8_000
    private static let crashLimit = 4_000

    public struct Input: Sendable {
        public var versions: [String]
        public var appLog: String
        /// Log files by title, read with `tail(of:)`.
        public var files: [(title: String, text: String)]
        /// From `recentCrashes(in:)`.
        public var crashes: [String]
        /// Server and group names, addresses, subscription URLs, the account and computer names.
        public var known: [String]

        public init(versions: [String], appLog: String, files: [(title: String, text: String)], crashes: [String], known: [String]) {
            self.versions = versions
            self.appLog = appLog
            self.files = files
            self.crashes = crashes
            self.known = known
        }
    }

    public static func build(_ input: Input) -> String {
        let known = cleaned(known: input.known)
        var parts = ["### Versions\n" + input.versions.map { "- " + $0 }.joined(separator: "\n")]
        func section(_ title: String, _ text: String) {
            let safe = redact(text, known: known)
            guard !safe.isEmpty else { return }
            parts.append("### \(title)\n```\n\(safe.suffix(logLimit))\n```")
        }
        section("App log", input.appLog)
        for file in input.files { section(file.title, file.text) }
        for crash in input.crashes { parts.append("### Crash\n```\n\(crash.prefix(crashLimit))\n```") }
        return parts.joined(separator: "\n\n")
    }

    /// Longest first, so a name holding another name goes whole. Very short names would only mangle the log.
    private static func cleaned(known: [String]) -> [String] {
        Set(known.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter { $0.count >= 3 }.sorted { $0.count > $1.count }
    }

    /// Removes what can identify the user, their servers or where they go. It removes too much rather than
    /// too little: anything shaped like a host name goes, also a file name like `vm.log`.
    public static func redact(_ text: String, known: [String] = []) -> String {
        // Connection lines say where the user went and when; no redaction makes that pattern safe to share.
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(" accepted ") && !$0.contains("pkg-search ") }
            .joined(separator: "\n")
        for name in cleaned(known: known) {
            result = result.replacingOccurrences(of: name, with: "<name>", options: .caseInsensitive)
        }
        let hex = "[0-9a-fA-F]{1,4}"
        let rules: [(pattern: String, template: String)] = [
            // The VM's console has terminal codes.
            (#"\x1B(?:\[[0-9;?]*[A-Za-z]|\][^\x07]*\x07?)"#, ""),
            (#"/Users/[^/\s]+"#, "~"),
            (#"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+"#, "<url>"),
            (#"[\w.+-]+@[\w-]+\.[\w.-]+"#, "<email>"),
            (#"(?i)\b([\w-]*(?:password|passwd|secret|token|apikey|api_key|private_?key|public_?key|short_?id|uuid|psk)[\w-]*)"?\s*[:=]\s*"?[^\s",&]+"#, "$1=<secret>"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "<id>"),
            // Loopback and the any-address say nothing about the user and help reading the log.
            (#"(?<![\d.])(?!127\.)(?!0\.0\.0\.0)(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#, "<ip>"),
            ("(?<![\\w:.])(?:(?:\(hex):){7}\(hex)|(?:\(hex):){1,7}:(?:\(hex)(?::\(hex)){0,6})?|::\(hex)(?::\(hex)){0,6})(?![\\w:])", "<ip>"),
            (#"(?<![\p{L}\p{N}/_-])(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+\p{L}{2,}\b"#, "<host>"),
            (#"(?<![/\w])[A-Za-z0-9+_=-]{32,}"#, "<token>"),
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                // A rule that doesn't compile must not let the text through unredacted.
                return "(log removed: redaction failed)"
            }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.template)
        }
        return result
    }

    /// The end of a log file; empty when it doesn't exist.
    public static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Bytes are 4 times the characters kept at most, so redaction still has enough to fill the section.
        try? handle.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// The newest crash reports of V2Mac, its sandbox helper and the core from the last two weeks.
    public static func recentCrashes(in folder: URL, now: Date = .now, limit: Int = 3) -> [String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast }
        return files
            .filter { $0.pathExtension == "ips" && ($0.lastPathComponent.hasPrefix("V2Mac") || $0.lastPathComponent.hasPrefix("xray")) }
            .filter { now.timeIntervalSince(date($0)) < 14 * 86_400 }
            .sorted { date($0) > date($1) }
            .prefix(limit)
            .compactMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap(crashSummary) }
    }

    /// A macOS `.ips` report (a JSON header line, then JSON). Fields are picked, never removed: the report
    /// also holds paths, the Mac's model, launch details and the app's own crash messages.
    static func crashSummary(_ ips: String) -> String? {
        let parts = ips.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]
        else { return nil }
        var lines = ["\(header["app_name"] ?? "?") \(header["app_version"] ?? "?"), \(header["os_version"] ?? "?"), \(body["captureTime"] ?? "?")"]
        if let exception = body["exception"] as? [String: Any] {
            lines.append("Exception: \(exception["type"] ?? "?") \(exception["signal"] ?? "") \(exception["codes"] ?? "")")
        }
        if let termination = body["termination"] as? [String: Any] {
            lines.append("Termination: \(termination["namespace"] ?? "?") \(termination["code"] ?? "") \(termination["indicator"] ?? "")")
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        if let index = body["faultingThread"] as? Int, threads.indices.contains(index),
           let frames = threads[index]["frames"] as? [[String: Any]] {
            lines.append("Crashed thread \(index):")
            for frame in frames.prefix(40) {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                lines.append("  \(image)  \(frame["symbol"] as? String ?? "+\(frame["imageOffset"] ?? "?")")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
