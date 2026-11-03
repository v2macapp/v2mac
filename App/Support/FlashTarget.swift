import SwiftUI

extension EnvironmentValues {
    /// The Settings window's scroll reader, so a flash target in a long tab can scroll itself into view.
    @Entry var flashScroll: ScrollViewProxy?
}

extension View {
    /// Marks the spot a notification click points at (`AppModel.focusAnchor`): it scrolls into view
    /// and pulses twice with a soft accent highlight.
    func flashTarget(_ anchor: String) -> some View { modifier(FlashTarget(anchor: anchor)) }
}

private struct FlashTarget: ViewModifier {
    let anchor: String
    @Environment(AppModel.self) private var model
    @Environment(\.flashScroll) private var scroll
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = false

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(isLit ? 0.22 : 0))
                    .padding(-4)
            }
            .onChange(of: model.focusAnchor, initial: true) { _, focus in
                guard focus == anchor else { return }
                model.focusAnchor = nil
                Task {
                    // Lets a window or Settings tab that just opened finish its layout first.
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(reduceMotion ? nil : .smooth) { scroll?.scrollTo(anchor, anchor: .center) }
                    #if DEBUG
                    print("[v2mac-debug] flash \(anchor), scrolls: \(scroll != nil)")
                    #endif
                    for _ in 0..<2 {
                        withAnimation(.easeOut(duration: 0.25)) { isLit = true }
                        try? await Task.sleep(for: .milliseconds(450))
                        withAnimation(.easeIn(duration: 0.35)) { isLit = false }
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                }
            }
    }
}
