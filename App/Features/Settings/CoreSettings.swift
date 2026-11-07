import SwiftUI
import V2MacCore

struct CoreSettings: View {
    @Environment(AppModel.self) private var model

    private var updates: UpdateService { model.updates }
    /// Review F16: a core V2Mac did not sign for is an explicit, warned choice.
    @State private var confirmInstall: CoreRelease?

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: updates.coreVersion ?? String(localized: "Unknown"))
                LabeledContent("Source", value: updates.coreIsUpdatedCopy ? String(localized: "Updated copy") : String(localized: "Bundled"))
                statusRow
            } header: {
                Text("Xray-core")
            } footer: {
                Text("This build checks its own core against a hash signed into the app. A newer core from Xray's releases (Advanced) is checked only against the hash Xray publishes beside it, and self-tested before it replaces the current one.")
            }
            HStack {
                Button("Check for Newer Core (Advanced)") { Task { await updates.checkCore() } }
                    .disabled(updates.coreStatus == .checking || updates.coreStatus == .installing)
                if case .available(let release) = updates.coreStatus {
                    Button("Install \(release.version)…") { confirmInstall = release }
                }
                Button("Revert to Bundled") { Task { await updates.revertToBundled() } }
                    .disabled(!updates.coreIsUpdatedCopy || updates.coreStatus == .installing)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Install Xray \(confirmInstall?.version ?? "")?", isPresented: Binding(get: { confirmInstall != nil }, set: { if !$0 { confirmInstall = nil } })) {
            Button("Install Anyway") { if let release = confirmInstall { Task { await updates.installCore(release) } } }
        } message: {
            Text("V2Mac has not checked this version. It is verified only against the hash in the same Xray release, so a tampered release would pass. Revert to Bundled undoes it.")
        }
        .animation(.default, value: updates.coreStatus)
        .task { await updates.refreshCoreInfo() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updates.coreStatus {
        case .idle: EmptyView()
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("You have the latest core.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let release):
            LabeledContent("Available", value: release.version + (release.publishedAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
        case .installing:
            DownloadProgressView(title: "Downloading core…", progress: updates.coreProgress, rate: updates.coreDownloadRate)
        case .installed(let version):
            Label("Installed \(version).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        }
    }
}
