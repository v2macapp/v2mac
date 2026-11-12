import SwiftUI
import V2MacCore

/// This session's and the total traffic, shown when the usage in the bar or the menu bar
/// panel is clicked (spec 12.8).
struct UsageDetails: View {
    let connection: ConnectionController

    var body: some View {
        let usage = connection.usage
        VStack(alignment: .leading, spacing: 12) {
            section("This Session", up: usage.sessionUp, down: usage.sessionDown, proxy: usage.sessionProxy,
                    note: usage.sessionStart.map { String(localized: "Since \($0.formatted(date: .abbreviated, time: .shortened))") })
            Divider()
            section("Total", up: usage.totalUp, down: usage.totalDown, proxy: usage.totalProxy,
                    note: usage.totalSince.map { String(localized: "Since \($0.formatted(date: .abbreviated, time: .omitted))") })
            Button("Reset Total") { connection.resetTotalUsage() }
                .controlSize(.small)
                .disabled(usage.total == 0)
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
    }

    /// `proxy`: what went through the server, when known (usage counted before 1.12 has no split).
    private func section(_ title: LocalizedStringKey, up: Int64, down: Int64, proxy: Int64?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(Format.bytes(up + down)).font(.headline.monospacedDigit())
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Label("Downloaded", systemImage: "arrow.down")
                    Text(Format.bytes(down)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    Label("Uploaded", systemImage: "arrow.up")
                    Text(Format.bytes(up)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let proxy {
                    GridRow {
                        Label { Text("Proxy") } icon: { Image(systemName: "lock.shield").foregroundStyle(Color.accentColor) }
                        Text(Format.bytes(proxy)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        Label { Text("Direct") } icon: { Image(systemName: "arrow.right.circle").foregroundStyle(.green) }
                        Text(Format.bytes(max(up + down - proxy, 0))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

/// "1.2 GB" for this session, which opens `UsageDetails` when clicked.
struct SessionUsageButton: View {
    let connection: ConnectionController
    var showsTitle = false
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 4) {
                if showsTitle { Text("This session") }
                Label {
                    if let proxy = connection.usage.sessionProxy {
                        ProxyOfTotal(proxy: Format.bytes(proxy), total: Format.bytes(connection.usage.session))
                    } else {
                        Text(Format.bytes(connection.usage.session))
                    }
                } icon: { Image(systemName: "chart.bar") }
                    .contentTransition(.numericText())
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Traffic this session. Click for details and the total.")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { UsageDetails(connection: connection) }
    }
}
