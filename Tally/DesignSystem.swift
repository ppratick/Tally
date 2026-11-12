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

    /// Main tabs, styled like Orbit: no system bar and no title row. Glass buttons float at the
    /// left and right with the screen name in a glass pill between them; content scrolls up under
    /// them and stays visible, with only a faint fade behind the status bar.
    func tallyRootScreen<Leading: View, Trailing: View>(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(RootScreen(title: title, leading: leading(), trailing: trailing(), accessory: EmptyView()))
    }

    /// Same header with a floating control (e.g. a segmented switch) under the buttons.
    func tallyRootScreen<Leading: View, Trailing: View, Accessory: View>(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing, @ViewBuilder accessory: () -> Accessory) -> some View {
        modifier(RootScreen(title: title, leading: leading(), trailing: trailing(), accessory: accessory()))
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

private struct RootScreen<Leading: View, Trailing: View, Accessory: View>: ViewModifier {
    let title: String
    let leading: Leading
    let trailing: Trailing
    let accessory: Accessory

    func body(content: Content) -> some View {
        content
            .hidingTopScrollEdge()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 10) {
                    ZStack {
                        Text(title.uppercased())
                            .font(.system(size: 14, weight: .bold)).tracking(1)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .tallyGlass(in: Capsule())
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 10) {
                            leading
                            Spacer(minLength: 0)
                            trailing
                        }
                    }
                    accessory
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                .background {
                    // A faint fade, not a band: content stays visible as it passes under the buttons.
                    LinearGradient(stops: [
                        .init(color: .tallyCanvas.opacity(0.85), location: 0),
                        .init(color: .tallyCanvas.opacity(0.35), location: 0.55),
                        .init(color: .tallyCanvas.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top).allowsHitTesting(false)
                }
            }
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
