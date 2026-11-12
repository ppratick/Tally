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

    /// Main tabs: no system bar. A compact title row with floating glass buttons sits above the content,
    /// which scrolls underneath it with a soft fade rather than a blur.
    func tallyRootScreen<Trailing: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(RootScreen(title: title, subtitle: subtitle, trailing: trailing(), accessory: EmptyView()))
    }

    /// Same header with a pinned control (e.g. a segmented switch) under the title row.
    func tallyRootScreen<Trailing: View, Accessory: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder accessory: () -> Accessory) -> some View {
        modifier(RootScreen(title: title, subtitle: subtitle, trailing: trailing(), accessory: accessory()))
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

private struct RootScreen<Trailing: View, Accessory: View>: ViewModifier {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let accessory: Accessory

    func body(content: Content) -> some View {
        content
            .hidingTopScrollEdge()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        if let subtitle {
                            Text(subtitle.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                        }
                        Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.5)
                    }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    trailing
                }
                accessory
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
                .background {
                    // Solid behind the title (content slides away under it), then a short fade. No blur.
                    VStack(spacing: 0) {
                        Color.tallyCanvas
                        LinearGradient(colors: [.tallyCanvas, .tallyCanvas.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 22)
                    }.padding(.bottom, -22).ignoresSafeArea(edges: .top).allowsHitTesting(false)
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
