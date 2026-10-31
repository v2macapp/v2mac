import SwiftData
import SwiftUI
import V2MacCore

/// Settings → About → Report a Problem: shows the redacted report, editable, before anything leaves the Mac.
struct ProblemReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem").font(.title2.bold())
            Text("Server names and addresses, subscription links, keys, sites you visit and your account name were removed. Nothing is sent: V2Mac copies this text and opens GitHub, where you paste it. Read it first, and delete anything you don't want to share.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let report {
                TextEditor(text: Binding(get: { report }, set: { self.report = $0 }))
                    .font(.system(.caption, design: .monospaced))
                    .border(.separator)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Copy and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report ?? "", forType: .string)
                    openURL(AboutLinks.newIssue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(report == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { report = await makeReport() }
    }

    private func makeReport() async -> String {
        let profiles = (try? model.context.fetch(FetchDescriptor<Profile>())) ?? []
        let groups = (try? model.context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let known = profiles.flatMap { [$0.name, $0.address] } + groups.flatMap { [$0.name, $0.subscriptionURL] }
            + [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName, Host.current().localizedName ?? ""]
        let versions = ["V2Mac \(Prefs.appVersion)", "Xray \(model.updates.coreVersion ?? "?")", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        let appLog = model.logs.lines.map(\.text).joined(separator: "\n")
        let sandbox = model.sandbox.files.root
        // Reading the files and redacting against every server name takes a moment with long lists.
        return await Task.detached {
            let names = ["sandbox.log", "sandbox.log.1", "vm.log", "vm.log.1"]
            let vms = (try? Data(contentsOf: sandbox.appendingPathComponent("vms.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            return ProblemReport.build(.init(
                versions: versions, appLog: appLog,
                files: names.map { (title: $0, text: ProblemReport.tail(of: sandbox.appendingPathComponent($0))) },
                crashes: ProblemReport.recentCrashes(in: URL.libraryDirectory.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory)),
                known: known + vms.compactMap { $0["name"] as? String }))
        }.value
    }
}
