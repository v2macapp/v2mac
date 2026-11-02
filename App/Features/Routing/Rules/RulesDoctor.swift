import SwiftData
import SwiftUI
import V2MacCore

extension AppModel {
    /// What the Doctor checks: the draft, with what this Mac has and how it routes now.
    func doctorInput() -> DoctorInput {
        var input = DoctorInput(rules: rules.draft)
        input.apps = ruleCatalog.apps
        input.geo = ruleCatalog.lists
        var targets: [Rule.Via.Target: String] = [:]
        for server in (try? context.fetch(FetchDescriptor<Profile>())) ?? [] where !server.isStale { targets[.server(server.id)] = server.name }
        for group in (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? [] { targets[.group(group.id)] = group.name }
        input.targets = targets
        input.failingTargets = Set(connection.viaStatus.filter(\.value.allFailing).keys)
        input.mode = connection.routingMode
        input.blockQUIC = UserDefaults.standard.bool(forKey: "blockQUIC")
        input.tun = connection.tun.isEnabled
        let unmatched = CustomRule.Action(rawValue: UserDefaults.standard.string(forKey: "unmatchedRoute") ?? "")
        input.defaultRoute = switch (connection.routingMode, unmatched) {
        case (.direct, _), (.bypassRegions, nil): nil
        case (_, .proxy?): .proxy
        case (_, .direct?): .direct
        case (_, .block?): .block
        case (.rulesOnly, nil): .direct
        // A full config's own routing decides what no rule matched.
        case (.global, nil): connection.activeIsCustom ? nil : .proxy
        }
        for seen in connection.watcher.connections {
            if let app = seen.app { input.seenHosts[app, default: []].insert(seen.host) }
        }
        return input
    }
}

/// Spec 8.6: one button does what is safe; anything that needs a decision is a row with its own Fix.
/// Fixes change the draft, so Apply and ⌘Z still decide.
struct RulesDoctorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Changes the draft, with undo.
    let apply: ([DoctorFix]) -> Void
    @State private var findings: [DoctorFinding]?
    @State private var fixedAny = false

    private var automatic: [DoctorFinding] { (findings ?? []).filter { $0.preselected && !$0.fixes.isEmpty } }
    private var choices: [DoctorFinding] { (findings ?? []).filter { !$0.preselected || $0.fixes.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if findings?.isEmpty == false { list } else { Spacer(minLength: 0) }
            footer
        }
        .padding(24)
        .frame(width: 600, height: findings?.isEmpty == false ? 560 : 300)
        .task { await scan() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            let healthy = findings?.isEmpty == true
            Image(systemName: healthy ? "checkmark.seal.fill" : "stethoscope")
                .font(.system(size: 30))
                .foregroundStyle(healthy ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if findings == nil { Text("Checking your rules…") }
                    else if healthy { Text(fixedAny ? "All fixed" : "Your rules look healthy") }
                    else { Text("Found \(findings!.count) things to improve") }
                }
                .font(.title2.weight(.semibold))
                Text(fixedAny ? "Press Apply in the Rules window to start using the changes." : "Nothing changes until you press Apply.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if findings == nil { ProgressView().controlSize(.small) }
        }
    }

    private var list: some View {
        List {
            if !automatic.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(automatic) { finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title)
                                Text(finding.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    } label: {
                        Label("\(automatic.count) can be fixed automatically", systemImage: "wand.and.stars").fontWeight(.medium)
                    }
                }
            }
            if !choices.isEmpty {
                Section("Your choice") {
                    ForEach(choices) { ChoiceRow(finding: $0) { fix in Task { await run([fix]) } } }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            if !automatic.isEmpty {
                Button("Fix Automatically") { Task { await run(automatic.compactMap(\.fixes.first)) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func scan() async {
        await model.ruleCatalog.load()
        let input = model.doctorInput()
        let found = await Task.detached { RuleDoctor.diagnose(input) }.value
        findings = found
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugRulesDoctor") {
            for finding in found { print("[v2mac-debug] doctor \(finding.severity): \(finding.title) | \(finding.fixes.map(\.title).joined(separator: " / "))") }
        }
        #endif
    }

    /// A fix can uncover the next problem, so the list is checked again after each.
    private func run(_ fixes: [DoctorFix]) async {
        fixedAny = true
        apply(fixes)
        await scan()
    }
}

/// One decision: what is wrong, what fixing it does, and Fix (a menu when there is more than one way).
private struct ChoiceRow: View {
    let finding: DoctorFinding
    let fix: (DoctorFix) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: finding.severity.symbol).foregroundStyle(finding.severity.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).fontWeight(.medium)
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let first = finding.fixes.first, first.changesRouting {
                    Text(first.title).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let first = finding.fixes.first {
                if finding.fixes.count > 1 {
                    Menu("Fix") {
                        ForEach(finding.fixes) { option in Button(option.title) { fix(option) } }
                    } primaryAction: { fix(first) }
                    .fixedSize()
                    .help(first.title)
                } else {
                    Button("Fix") { fix(first) }.help(first.title)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

extension DoctorFinding.Severity {
    var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .conflict: "arrow.triangle.merge"
        case .warning: "exclamationmark.triangle.fill"
        case .simplify: "wand.and.stars"
        case .organize: "square.stack.3d.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .error: .red
        case .conflict: .purple
        case .warning: .orange
        case .simplify: .blue
        case .organize: .secondary
        }
    }
}
