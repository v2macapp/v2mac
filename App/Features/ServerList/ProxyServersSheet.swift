import SwiftUI
import V2MacCore

struct ProxyServersRequest: Identifiable {
    let id = UUID()
    let profileIDs: [UUID]
}

/// Starts one local proxy per chosen server, on consecutive free ports (spec 12.13).
struct ProxyServersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ProxyServersRequest
    @AppStorage("proxyServersFirstPort") private var firstPort = 20800
    @AppStorage("proxyServersAllowLAN") private var allowLAN = false
    @State private var username = ""
    @State private var password = ""

    private var servers: [ActiveServer] {
        request.profileIDs.compactMap { model.profile(id: $0) }.compactMap(ActiveServer.init)
            .filter { model.proxyServers.proxy(for: $0.id) == nil }
    }

    /// Only one of the two set: the proxy would silently ask for nothing.
    private var halfCredentials: Bool { username.isEmpty != password.isEmpty }

    var body: some View {
        let servers = servers
        let ports = model.proxyServers.plannedPorts(count: servers.count, from: firstPort, allowLAN: allowLAN)
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Proxy Servers").font(.title2.weight(.semibold))
            Text("Each server gets its own local proxy (SOCKS5 and HTTP on one port), beside the main connection. All traffic through a proxy goes to its server.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("First port", value: $firstPort, format: .number.grouping(.never))
                Toggle("Allow other devices on the network", isOn: $allowLAN)
                if allowLAN {
                    TextField("Username (optional)", text: $username)
                    SecureField("Password (optional)", text: $password)
                    if halfCredentials {
                        Text("Set both a username and a password, or neither.").font(.caption).foregroundStyle(.red)
                    } else if username.isEmpty {
                        Label("Anyone on your network can use this proxy. Set a username and password.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            if servers.isEmpty {
                Text("The chosen servers already have proxies.").foregroundStyle(.secondary)
            } else {
                List(Array(zip(servers, ports)), id: \.0.id) { server, port in
                    HStack {
                        Text(server.name).lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(allowLAN ? "0.0.0.0" : "127.0.0.1"):\(port)")
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
                if ports.count < servers.count {
                    Text("Not enough free ports from \(String(firstPort)).").font(.callout).foregroundStyle(.red)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(servers.count == 1 ? "Create Proxy" : "Create \(servers.count) Proxies") {
                    model.proxyServers.create(servers, options: .init(firstPort: firstPort, allowLAN: allowLAN,
                                                                      username: username, password: password))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(servers.isEmpty || ports.count < servers.count || (allowLAN && halfCredentials))
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
    }
}

/// A running proxy as one line: name, address, state, copy and stop.
struct ProxyServerRow: View {
    let proxy: ProxyServerService.Proxy
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
                .help(help)
            Text(proxy.name).lineLimit(1)
            Spacer(minLength: 4)
            Text(proxy.address).font(.callout.monospaced()).foregroundStyle(.secondary)
            CopyButton("Copy address") { proxy.address }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy address")
            Button(action: stop) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Stop this proxy").accessibilityLabel("Stop this proxy")
        }
    }

    private var color: Color {
        switch proxy.state {
        case .running: .green
        case .failed: .red
        default: .orange
        }
    }

    private var help: String {
        if case .failed(let message) = proxy.state { return message }
        return proxy.state == .running ? String(localized: "Running") : String(localized: "Starting…")
    }
}

/// The toolbar's list of running proxies, with their count as a badge.
struct ProxyServersButton: View {
    let service: ProxyServerService
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Label("Proxy Servers", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: "\(service.proxies.count)")
                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                .background(service.proxies.contains { if case .failed = $0.state { true } else { false } } ? .red : .green, in: .capsule)
                .offset(x: 6, y: -4)
                .allowsHitTesting(false)
        }
        .help("Proxy servers running beside the main connection")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Proxy Servers").font(.headline)
                ForEach(service.proxies) { proxy in
                    ProxyServerRow(proxy: proxy) { service.stop(proxy.id) }
                }
                Divider()
                HStack {
                    CopyButton("Copy All") { service.proxies.map(\.address).joined(separator: "\n") }
                    Spacer()
                    Button("Stop All", role: .destructive) { Task { await service.stopAll() } }
                }
            }
            .padding(14)
            .frame(width: 380)
        }
    }
}
