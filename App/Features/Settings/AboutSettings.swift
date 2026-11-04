import SwiftUI
import V2MacCore

struct AboutSettings: View {
    @State private var copied = false
    @State private var commandLineTool = CommandLineToolInstaller()
    @State private var reporting = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("V2Mac").font(.title2.bold())
                    Text("Version \(Prefs.appVersion)").font(.callout).foregroundStyle(.secondary)
                    Text(AboutLinks.tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Link(AboutLinks.repositoryText, destination: AboutLinks.repository).font(.callout)
                    HStack(spacing: 8) {
                        ShareLink(item: AboutLinks.repository, subject: Text("V2Mac"), message: Text(AboutLinks.tagline)) {
                            Label("Share V2Mac", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            copyLink()
                        } label: {
                            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } footer: {
                Text("V2Mac is free and has no ads. If it helps you, share it with someone who needs it.")
            }
            Section("Project") {
                AboutLinkRow("Star on GitHub", systemImage: "star", detail: "Source code", url: AboutLinks.repository)
                AboutLinkRow("What's New", systemImage: "sparkles", detail: "Release notes", url: AboutLinks.releases)
                Button { reporting = true } label: {
                    HStack {
                        Label("Report a Problem", systemImage: "ladybug")
                        Spacer()
                        Text("Open an issue").foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Section {
                HStack {
                    Label("v2mac", systemImage: "terminal")
                    Spacer()
                    switch commandLineTool.state {
                    case .installed:
                        Button("Remove") { commandLineTool.remove() }
                    case .absent:
                        Button("Install Command Line Tool") { commandLineTool.install() }
                    case .occupied:
                        Text("Another file uses /usr/local/bin/v2mac").foregroundStyle(.secondary)
                    }
                }
                if let error = commandLineTool.error { Text(error).foregroundStyle(.red) }
            } header: {
                Text("Command Line Tool")
            } footer: {
                Text("Adds a link at /usr/local/bin/v2mac. V2Mac never replaces a file owned by another program.")
            }
            Section {
                AboutLinkRow("LordVersa", systemImage: "person.crop.circle", detail: "github.com/LordVersA", url: AboutLinks.author)
                AboutLinkRow("noleaker", systemImage: "eye.slash", detail: "Stops browser leaks", url: AboutLinks.noleaker)
            } header: {
                Text("Developer")
            } footer: {
                HStack(spacing: 4) {
                    Text("Made with")
                    Image(systemName: "heart.fill").foregroundStyle(.red).accessibilityLabel("love")
                    Text("by LordVersa")
                }
            }
            Section {
                LabeledContent("Xray-core") {
                    Link("github.com/XTLS/Xray-core", destination: URL(string: "https://github.com/XTLS/Xray-core")!)
                }
            } footer: {
                Text("V2Mac is GPL-3.0 software. It bundles Xray-core (MPL-2.0) and v2fly/Loyalsoldier rule data; see THIRD_PARTY.md for licences and attributions.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $reporting) { ProblemReportSheet() }
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AboutLinks.repository.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct AboutLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: LocalizedStringKey
    let url: URL

    init(_ title: LocalizedStringKey, systemImage: String, detail: LocalizedStringKey, url: URL) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
