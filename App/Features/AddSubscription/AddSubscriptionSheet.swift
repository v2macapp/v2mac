import SwiftData
import SwiftUI
import V2MacCore

struct AddSubscriptionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind = AddDraft.Kind.custom
    @State private var url = ""
    @State private var configText = ""
    @State private var name = ""
    @State private var viaProxy = false
    @State private var color = GroupColor.blue
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var duplicateID: UUID?
    /// The last direct fetch failed on the network, so the host may only be reachable through a proxy.
    @State private var directFetchBlocked = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .subscription ? "Add Subscription" : "Add Custom Configs").font(.headline)

            Form {
                Picker("Type", selection: $kind.animation(.snappy)) {
                    Text("Custom Config").tag(AddDraft.Kind.custom)
                    Text("Subscription URL").tag(AddDraft.Kind.subscription)
                }
                // Separate groups so the fields of one type blur out as the other's blur in.
                switch kind {
                case .subscription:
                    Group {
                        TextField("URL", text: $url, prompt: Text("https://sub.example.com/abc123"))
                            .focused($urlFocused)
                        TextField("Name", text: $name, prompt: Text("(auto)"))
                        LabeledContent("Color") { GroupColorPicker(selection: $color) }
                        Toggle("Fetch via proxy", isOn: $viaProxy)
                            .disabled(!model.connection.isRunning)
                        if !model.connection.isRunning {
                            Text("Connect to a server first to fetch through it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .transition(.blurReplace)
                case .custom:
                    Group {
                        LabeledContent("Configs") {
                            ConfigTextEditor(text: $configText)
                                .overlay(alignment: .topLeading) {
                                    if configText.isEmpty {
                                        Text("Paste one or more share links or Xray JSON configs")
                                            .font(.callout.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 7).padding(.vertical, 6)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .background(.background.secondary, in: .rect(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                                .frame(minHeight: 120, maxHeight: .infinity)
                        }
                        Text("They are added to the Custom Configs group.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .transition(.blurReplace)
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(isFetching)
            .onChange(of: kind) { clearError() }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 16) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if directFetchBlocked {
                        if model.connection.isRunning {
                            Text("This link may only be reachable through your proxy.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Try via Proxy") { viaProxy = true; add() }
                        } else {
                            Text("This link may only be reachable through a VPN or proxy. Connect to a server first, then turn on “Fetch via proxy”.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let duplicateID {
                        Button("Update Existing") {
                            model.sidebarSelection = .group(duplicateID)
                            Task { await model.subscriptions.update(groupID: duplicateID, viaProxy: viaProxy) }
                            dismiss()
                        }
                    }
                }
                .transition(.opacity)
            }

            HStack {
                if kind == .custom {
                    Button("Enter Details Manually…") {
                        model.opensEditorAfterAddSheet = true
                        dismiss()
                    }
                    .help("Fill in a server's protocol, address and options yourself")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if isFetching {
                    ProgressView().controlSize(.small).frame(width: 60)
                } else {
                    Button("Add") { add() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        // Resizable, so a long config can be read; the editor takes the extra height. The padding
        // goes outside the flexible frame, or the sheet is sized without the bottom padding.
        .frame(minWidth: 420, idealWidth: 480, maxWidth: .infinity, minHeight: kind == .custom ? 380 : nil, maxHeight: .infinity, alignment: .top)
        .padding(20)
        .animation(.snappy, value: errorMessage)
        .animation(.snappy, value: isFetching)
        .onAppear(perform: start)
    }

    private var input: String { kind == .subscription ? url : configText }

    private func start() {
        let draft = model.addDraft
        model.addDraft = AddDraft()
        kind = draft.kind
        configText = draft.configText
        errorMessage = draft.error
        // The next one in the row, so a new subscription differs from the last without choosing.
        let groups = (try? model.context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        color = .automatic(groups.filter { !$0.isManual }.count)
        if kind == .subscription { urlFocused = true }
        name = draft.name
        if !draft.url.isEmpty {
            url = draft.url
        } else if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  AddDraft.isSubscriptionURL(clip) {
            url = clip
        }
        #if DEBUG
        print("[v2mac-debug] add sheet: \(kind), url \(url), name \(name), configs \(configText.prefix(60)), error \(errorMessage ?? "-")")
        #endif
    }

    private func clearError() {
        errorMessage = nil
        duplicateID = nil
        directFetchBlocked = false
    }

    private func add() {
        clearError()
        isFetching = true
        switch kind {
        case .subscription: addSubscription()
        case .custom: addCustom()
        }
    }

    private func addCustom() {
        Task {
            defer { isFetching = false }
            do {
                model.sidebarSelection = .group(try await model.subscriptions.addCustom(text: configText))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addSubscription() {
        Task {
            defer { isFetching = false }
            do {
                let id = try await model.subscriptions.add(urlString: url, name: name, viaProxy: viaProxy)
                model.group(id: id)?.colorName = color.rawValue
                model.save()
                model.sidebarSelection = .group(id)
                dismiss()
            } catch let AddSubscriptionError.duplicate(id) {
                errorMessage = AddSubscriptionError.duplicate(id).localizedDescription
                duplicateID = id
            } catch {
                errorMessage = error.localizedDescription
                if !viaProxy, case SubscriptionError.network = error { directFetchBlocked = true }
            }
        }
    }
}

/// A plain-text editor for pasted configs: scrolls, never swaps in smart quotes (they break JSON),
/// and colours JSON so keys, strings, numbers and literals are told apart.
private struct ConfigTextEditor: NSViewRepresentable {
    @Binding var text: String

    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    private static let string = #""(?:[^"\\\n]|\\.)*""#
    /// Applied in order, so a later rule wins: a number inside a string stays a string, a string before `:` is a key.
    private static let rules: [(NSRegularExpression, NSColor)] = ([
        (#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, NSColor.systemPurple),
        (#"\b(?:true|false|null)\b"#, .systemOrange),
        (string, .systemRed),
        (string + #"(?=\s*:)"#, .systemBlue),
    ] as [(String, NSColor)]).map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = false
        view.font = Self.font
        view.textContainerInset = NSSize(width: 2, height: 6)
        view.string = text
        Self.highlight(view)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            // SwiftUI sheets have a fixed size; let this one be dragged larger to read a long config.
            view.window?.styleMask.insert(.resizable)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let view = scroll.documentView as! NSTextView
        view.isEditable = context.environment.isEnabled
        if view.string != text {
            view.string = text
            Self.highlight(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            ConfigTextEditor.highlight(view)
        }
    }

    static func highlight(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: all)
        // Share links are left plain; only text that starts like JSON is coloured.
        if let first = view.string.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
            for (regex, color) in rules {
                regex.enumerateMatches(in: storage.string, range: all) { match, _, _ in
                    if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
                }
            }
        }
        storage.endEditing()
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }
}
