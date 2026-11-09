import SwiftUI

extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(compatGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill((tint ?? .clear).opacity(0.12)) }
            }
        }
    }

    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glassProminent) }
        else { self.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass) }
        else { self.buttonStyle(.bordered) }
    }

    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) { self.glassEffectID(id, in: namespace) }
        else { self }
    }

    @ViewBuilder
    func completionSymbolEffect() -> some View {
        if #available(macOS 15, *) { self.symbolEffect(.bounce, options: .nonRepeating) }
        else { self }
    }

    @ViewBuilder
    func rotatingSymbol(isActive: Bool) -> some View {
        if #available(macOS 15, *) { self.symbolEffect(.rotate, isActive: isActive) }
        else { self }
    }
}

struct CompatGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing, content: content) }
        else { content() }
    }
}

struct CompatToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
    }
}

extension ToolbarItem {
    @ToolbarContentBuilder
    func compatHiddenBackground() -> some ToolbarContent {
        if #available(macOS 26, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

extension Scene {
    // SceneBuilder supports availability-only blocks, but has no buildEither for an else.
    func launchSuppressed(_ suppressed: Bool = true) -> some Scene {
        if #available(macOS 15, *) {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                self.defaultLaunchBehavior(suppressed ? .suppressed : .presented)))
        }
        return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
    }
}

@available(macOS 26, *)
private func compatGlass(tint: Color?, interactive: Bool) -> Glass {
    if interactive { return .regular.tint(tint).interactive() }
    if let tint { return .regular.tint(tint) }
    return .regular
}
