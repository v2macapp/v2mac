import Foundation
import Network

/// The complete, bounded state a signed app may ask the managed helper to apply.
public struct PrivilegedSessionState: Codable, Equatable, Sendable {
    public var tunEnabled: Bool
    public var proxyPort: Int?
    public var killSwitchEnabled: Bool
    public var allowedAddresses: [String]
    /// The resolvers the kill switch leaves port 53 open to (`KillSwitch.resolverFile`).
    public var resolverAddresses: [String]
    /// Spec 9.8: the kill switch blocks the local network too.
    public var killSwitchBlocksLAN: Bool
    /// The app entries the TUN forwarder looks for (`TunApps`).
    public var apps: [String]

    public init(tunEnabled: Bool, proxyPort: Int?, killSwitchEnabled: Bool, allowedAddresses: [String],
                resolverAddresses: [String] = [], killSwitchBlocksLAN: Bool = false, apps: [String] = []) {
        self.tunEnabled = tunEnabled
        self.proxyPort = proxyPort
        self.killSwitchEnabled = killSwitchEnabled
        self.allowedAddresses = allowedAddresses
        self.resolverAddresses = resolverAddresses
        self.killSwitchBlocksLAN = killSwitchBlocksLAN
        self.apps = apps
    }

    public func validate() throws {
        guard proxyPort.map({ (1024...65535).contains($0) }) ?? true,
              allowedAddresses.count <= 4096, resolverAddresses.count <= 64,
              apps.count <= TunApps.limit, apps.allSatisfy(TunApps.isUsable),
              (allowedAddresses + resolverAddresses).allSatisfy({ address in
                  address.utf8.count <= 45 && address.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) || byte == 46 || byte == 58
                  }) && (IPv4Address(address) != nil || IPv6Address(address) != nil)
              })
        else { throw CocoaError(.coderInvalidValue) }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024 else { throw CocoaError(.coderInvalidValue) }
        let state = try JSONDecoder().decode(Self.self, from: data)
        try state.validate()
        return state
    }

    public static func validate(port: Int, interfaceName: String) throws {
        let suffix = interfaceName.dropFirst(4)
        guard (1024...65535).contains(port), interfaceName.hasPrefix("utun"),
              !suffix.isEmpty, suffix.count <= 5, suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              let index = UInt16(suffix), index >= 100
        else { throw CocoaError(.coderInvalidValue) }
    }

    /// Writes a validated snapshot into the daemon's root-owned request directory.
    public func write(to directory: URL) throws {
        try validate()
        let fm = FileManager.default
        func write(_ name: String, _ value: String?) throws {
            let url = directory.appendingPathComponent(name)
            if let value { try Data(value.utf8).write(to: url, options: .atomic) }
            else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try write(KillSwitch.allowFile, allowedAddresses.joined(separator: "\n") + "\n")
        try write(KillSwitch.resolverFile, resolverAddresses.joined(separator: "\n") + "\n")
        try write(KillSwitch.blockLANFlag, killSwitchBlocksLAN ? "" : nil)
        try write(KillSwitch.flag, killSwitchEnabled ? "" : nil)
        try write(SystemProxy.flag, proxyPort.map { "\($0)\n" })
        // Always written: the helper takes the file each time it reads it (`TunHelper.appsFunctions`).
        try write(TunApps.file, apps.map { $0 + "\n" }.joined())
        try write(TunHelper.onFlag, tunEnabled ? "" : nil)
    }
}
