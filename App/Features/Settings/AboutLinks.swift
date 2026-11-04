import AppKit

/// Where the About tab and the About panel point. Add a row in `AboutSettings` for every new link.
enum AboutLinks {
    static var tagline: String { String(localized: "A free, open-source Xray client for macOS.") }
    static let repositoryText = "github.com/v2macapp/v2mac"
    static let repository = URL(string: "https://github.com/v2macapp/v2mac")!
    static let releases = URL(string: "https://github.com/v2macapp/v2mac/releases")!
    static let newIssue = URL(string: "https://github.com/v2macapp/v2mac/issues/new?template=bug_report.md")!
    static let author = URL(string: "https://github.com/LordVersA")!
    static let noleaker = URL(string: "https://github.com/v2macapp/noleaker")!

    /// The app menu's About panel, with the same tagline and links as the About tab.
    @MainActor static func showAboutPanel() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 4
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        func link(_ text: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: text, attributes: plain.merging([.link: url]) { _, new in new })
        }
        let credits = NSMutableAttributedString(string: tagline + "\n", attributes: plain)
        credits.append(link(repositoryText, repository))
        credits.append(NSAttributedString(string: "\n" + String(localized: "Made by") + " ", attributes: plain))
        credits.append(link("LordVersa", author))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
