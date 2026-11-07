import Foundation

/// One request per connection on a Unix socket in the app's 0700 data folder: the CLI writes the
/// request JSON and shuts its write side; the app answers with the response JSON and closes.
/// (An NSXPCListenerEndpoint cannot be written to a file, so the CLI never found the app.)
enum CLISocket {
    static let maxMessage = 16 << 20

    static func open() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        if fd >= 0 { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        return fd
    }

    /// Calls bind or connect with the socket path's address; -1 with ENAMETOOLONG for a long path.
    static func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        let path = Array(V2MacCLIIdentity.endpointURL.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { errno = ENAMETOOLONG; return -1 }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }

    static func setTimeout(_ fd: Int32, seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Everything up to EOF; nil on an error, a timeout or more than `maxMessage` bytes.
    static func readAll(_ fd: Int32) -> Data? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { return data }
            if n < 0 { if errno == EINTR { continue }; return nil }
            data.append(buffer, count: n)
            if data.count > maxMessage { return nil }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }
}

enum V2MacCLIIdentity {
    #if DEBUG
    static let endpointName = "cli-v1-dev.sock"
    static let appIdentifier = "io.github.lordversa.v2mac.dev"
    static let cliIdentifier = "io.github.lordversa.v2mac.dev.cli"
    static let dataFolder = "v2mac-dev"
    #else
    static let endpointName = "cli-v1.sock"
    static let appIdentifier = "io.github.lordversa.v2mac"
    static let cliIdentifier = "io.github.lordversa.v2mac.cli"
    static let dataFolder = "v2mac"
    #endif

    static var endpointURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolder, isDirectory: true)
            .appendingPathComponent(endpointName)
    }
}

struct CLIWireRequest: Codable {
    var apiVersion = 1
    var arguments: [String]
    var stdin: String?
    var clientHash: String
}

struct CLIWireResponse: Codable {
    var apiVersion = 1
    var ok: Bool
    var command: String
    var revision: String?
    var data: String?
    var warnings: [String] = []
    var error: CLIWireError?
    var appHash: String

    private enum CodingKeys: String, CodingKey { case apiVersion, ok, command, revision, data, warnings, error, appHash }

    init(apiVersion: Int = 1, ok: Bool, command: String, revision: String? = nil, data: String? = nil,
         warnings: [String] = [], error: CLIWireError? = nil, appHash: String) {
        self.apiVersion = apiVersion; self.ok = ok; self.command = command; self.revision = revision
        self.data = data; self.warnings = warnings; self.error = error; self.appHash = appHash
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try values.decode(Int.self, forKey: .apiVersion)
        ok = try values.decode(Bool.self, forKey: .ok)
        command = try values.decode(String.self, forKey: .command)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        data = try values.decodeIfPresent(String.self, forKey: .data)
        warnings = try values.decode([String].self, forKey: .warnings)
        error = try values.decodeIfPresent(CLIWireError.self, forKey: .error)
        appHash = try values.decode(String.self, forKey: .appHash)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(apiVersion, forKey: .apiVersion); try values.encode(ok, forKey: .ok)
        try values.encode(command, forKey: .command); try values.encode(warnings, forKey: .warnings)
        if let revision { try values.encode(revision, forKey: .revision) } else { try values.encodeNil(forKey: .revision) }
        if let data { try values.encode(data, forKey: .data) } else { try values.encodeNil(forKey: .data) }
        if let error { try values.encode(error, forKey: .error) } else { try values.encodeNil(forKey: .error) }
        try values.encode(appHash, forKey: .appHash)
    }
}

struct CLIWireError: Codable {
    var id: String
    var message: String
    var exitCode: Int32
}
