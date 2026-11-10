import Perception
import SwiftUI

// iOS 18 support. Liquid Glass (`glassEffect`, the glass button styles and the
// tab bar accessory) needs iOS 26; earlier systems get the closest stock look:
// a material background, bordered buttons and a mini player bar above the tab bar.

/// The glass variants the app uses, independent of the iOS 26 `Glass` type.
enum GlassStyle {
    case regular
    case interactive
    case tinted(Color)
    case tintedInteractive(Color)
    /// No glass (a button that is not selected).
    case none

    @available(iOS 26.0, macCatalyst 26.0, *)
    var glass: Glass {
        switch self {
        case .regular: .regular
        case .interactive: .regular.interactive()
        case .tinted(let color): .regular.tint(color)
        case .tintedInteractive(let color): .regular.tint(color).interactive()
        case .none: .identity
        }
    }
}

extension View {
    /// `glassEffect` on iOS 26, an ultra-thin material (tinted when asked) before.
    @ViewBuilder
    func glass(_ style: GlassStyle = .regular, in shape: some Shape) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            glassEffect(style.glass, in: shape)
        } else {
            switch style {
            case .none: self
            case .tinted(let color), .tintedInteractive(let color):
                background { shape.fill(.ultraThinMaterial).overlay(shape.fill(color)) }
            case .regular, .interactive:
                background(.ultraThinMaterial, in: shape)
            }
        }
    }

    /// The glass button styles on iOS 26, bordered ones before.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Before iOS 26 there is no tab bar accessory: each tab shows the mini player
/// as a material bar pinned above the tab bar instead.
struct LegacyMiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            if #available(iOS 26.0, macCatalyst 26.0, *) {
                content
            } else {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    WithPerceptionTracking {
                        MiniPlayer()
                            .frame(height: 56)
                            .background(.regularMaterial, in: .rect(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
                }
            }
        }
    }
}

// iOS 16 support: stand-ins for iOS 17 views and modifiers.

/// `ContentUnavailableView` on iOS 17+, the same layout drawn by hand before.
struct EmptyState<LabelContent: View, Description: View, Actions: View>: View {
    private let label: LabelContent
    private let description: Description
    private let actions: Actions

    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description = { EmptyView() },
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            ContentUnavailableView { label } description: { description } actions: { actions }
        } else {
            VStack(spacing: 10) {
                label
                    .font(.title2.weight(.bold))
                    .labelStyle(EmptyStateLabelStyle())
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions.padding(.top, 6)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EmptyStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon.font(.system(size: 44)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

extension EmptyState where LabelContent == Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init { Label(title, systemImage: systemImage) } description: { description }
    }

    /// 「No results for "…"」 like `ContentUnavailableView.search(text:)`.
    static func search(text: String) -> Self {
        Self("没有“\(text)”的结果", systemImage: "magnifyingglass", description: Text("检查拼写或尝试新的搜索。"))
    }
}

extension View {
    /// Symbol replace transition (iOS 17+); a plain change before.
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(iOS 17.0, macCatalyst 17.0, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// The animated "now playing" bars (iOS 17+); static before.
    @ViewBuilder
    func playingSymbolEffect(isActive: Bool) -> some View {
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive)
        } else {
            self
        }
    }

    /// Page-aligned horizontal shelves (iOS 17+); free scrolling before.
    @ViewBuilder
    func shelfScrollTargets() -> some View {
        if #available(iOS 17.0, macCatalyst 17.0, *) { scrollTargetLayout() } else { self }
    }

    @ViewBuilder
    func shelfScrollBehavior() -> some View {
        if #available(iOS 17.0, macCatalyst 17.0, *) { scrollTargetBehavior(.viewAligned) } else { self }
    }
}

extension View {
    /// The zoom from the mini player into the full player (iOS 18+).
    @ViewBuilder
    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, macCatalyst 18.0, *) {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }

    /// `onChange` with only the new value, on every iOS version.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

extension Binding {
    /// Reads the value now, inside the view's perception tracking. On iOS 16
    /// SwiftUI reads a binding later (presenting a sheet, drawing a toggle),
    /// outside `WithPerceptionTracking`, so a model change would not refresh
    /// the view; reading it here does. Harmless on iOS 17+.
    var tracked: Binding<Value> {
        let value = wrappedValue
        let binding = self
        return Binding(get: { value }, set: { binding.wrappedValue = $0 })
    }
}
