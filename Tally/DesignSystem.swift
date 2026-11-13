import SwiftUI

/// Liquid Glass on iOS 26, a material fallback on iOS 18, and a solid surface when Reduce Transparency is on.
struct TallyGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        }
    }
}

extension View {
    func tallyGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(TallyGlass(shape: shape, interactive: interactive))
    }

    /// Removes the system's blurred scroll-edge band; a short fade keeps the status bar readable instead.
    @ViewBuilder func hidingTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: .top) } else { self }
    }

    /// Pushed screens keep the system back button, but the bar is the page color: content slides
    /// away under it instead of through a tall blur.
    func tallyTopFade() -> some View {
        hidingTopScrollEdge()
            .toolbarBackground(Color.tallyCanvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }

    /// Main tabs: a plain bold title with small borderless icons, pinned over the content.
    func tallyRootScreen<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(RootScreen(title: title, trailing: trailing(), accessory: EmptyView()))
    }

    /// Same, with a control (e.g. a segmented switch) pinned under the title.
    func tallyRootScreen<Trailing: View, Accessory: View>(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder accessory: () -> Accessory) -> some View {
        modifier(RootScreen(title: title, trailing: trailing(), accessory: accessory()))
    }
}

private struct TopFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .tallyCanvas, location: 0),
            .init(color: .tallyCanvas.opacity(0.92), location: 0.55),
            .init(color: .tallyCanvas.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

extension EnvironmentValues {
    @Entry var tallyScrollHeader: AnyView? = nil
}

/// Place at the top of a main tab's scroll content: renders that tab's title row, which scrolls away.
struct TallyScrollHeader: View {
    @Environment(\.tallyScrollHeader) private var header
    var body: some View { if let header { header } }
}

private struct RootScreen<Trailing: View, Accessory: View>: ViewModifier {
    let title: String
    let trailing: Trailing
    let accessory: Accessory

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
            }
            if Accessory.self != EmptyView.self { accessory }
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.tallyScrollHeader, AnyView(header))
            .hidingTopScrollEdge()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                // The top stays clear: only a faint fade behind the status bar.
                Color.clear.frame(height: 0)
                    .background {
                        LinearGradient(stops: [
                            .init(color: .tallyCanvas.opacity(0.85), location: 0),
                            .init(color: .tallyCanvas.opacity(0), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                        .padding(.bottom, -14).ignoresSafeArea(edges: .top).allowsHitTesting(false)
                    }
            }
    }
}

/// A small borderless header icon.
struct HeaderIcon: View {
    let systemImage: String
    let label: String
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: systemImage).font(.system(size: 18, weight: .medium)) }
            }
            .foregroundStyle(Color.tallyAccent)
            .frame(width: 38, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// A round glass button for header actions.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: systemImage).font(.system(size: 16, weight: .semibold)) }
            }
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .tallyGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Header menu variant of `GlassIconButton`.
struct GlassMenuButton<Content: View>: View {
    let systemImage: String
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .tallyGlass(in: Circle(), interactive: true)
        }
        .accessibilityLabel(label)
    }
}
