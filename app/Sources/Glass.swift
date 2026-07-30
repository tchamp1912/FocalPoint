// FocalPoint menu-bar app — Liquid Glass surfaces.
//
// Apple's Liquid Glass (`glassEffect(_:in:)`, `GlassEffectContainer`,
// `.buttonStyle(.glass)`) is macOS 26 API and only exists in the macOS 26
// SDK, so it can't merely be `if #available`-guarded — the symbols aren't in
// an older SDK at all and the file wouldn't compile. Two gates are therefore
// stacked:
//
//   • `#if FOCALPOINT_LIQUID_GLASS` — compile-time. build.sh defines it only
//     when the active SDK is 26 or newer, so an older toolchain never even
//     parses the native calls.
//   • `if #available(macOS 26.0, *)` — runtime. The deployment target stays
//     macOS 14, so a binary built on the new SDK still runs on 14/15 and
//     falls back there.
//
// The pre-26 path is deliberately *the app's existing appearance*, not a
// hand-rolled imitation of glass. Faking Liquid Glass out of blurs and white
// gradients reads as washed-out haze rather than glass, so below macOS 26 the
// UI simply keeps the plain, legible materials it has always used.
// MIT License.

import SwiftUI
import AppKit

/// Which surface is being rendered. Each case pairs the Liquid Glass
/// treatment with the exact legacy background that surface uses today, so
/// nothing changes visually until the OS/SDK can do the real thing.
enum GlassRole {
    /// The menu-bar dropdown panel.
    case menuPanel
    /// The desktop widget: a borderless, non-opaque window, so it needs
    /// `.behindWindow` blending and honours the Translucency setting.
    case floatingPanel(opacity: Double)
    /// A grouped section inside the settings window.
    case card
    /// Settings section card — more opaque than `.card` for legibility.
    case settingsCard
    /// A small inline pill (key-combo readout and similar).
    case chip
    /// The settings window's sidebar column background.
    case sidebarPane(opacity: Double)
    /// The settings window's detail column background.
    case detailPane(opacity: Double)
}

// MARK: - Surface

private struct LiquidGlassSurface: ViewModifier {
    let role: GlassRole
    let radius: CGFloat
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if FOCALPOINT_LIQUID_GLASS
        if #available(macOS 26.0, *) {
            native(content)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    #if FOCALPOINT_LIQUID_GLASS
    @available(macOS 26.0, *)
    @ViewBuilder
    private func native(_ content: Content) -> some View {
        let glass: Glass = tint.map { Glass.clear.tint($0) } ?? .clear
        switch role {
        case .floatingPanel(let opacity), .sidebarPane(let opacity), .detailPane(let opacity):
            // Drawn as a background layer rather than applied to `content`
            // directly, so the Translucency setting can fade the glass
            // without also fading the text and icons on top of it.
            content.background {
                shape.fill(.clear)
                    .glassEffect(glass, in: shape)
                    .opacity(opacity)
            }
        case .menuPanel, .card, .chip:
            content.glassEffect(glass, in: shape)
        case .settingsCard:
            content.background {
                shape.fill(.background.opacity(0.88))
            }
        }
    }
    #endif

    /// macOS 14/15: exactly what these surfaces looked like before.
    @ViewBuilder
    private func legacy(_ content: Content) -> some View {
        switch role {
        case .menuPanel:
            content.background(VisualEffectView(material: .menu, blendingMode: .withinWindow))
        case .floatingPanel(let opacity):
            content
                .background(
                    // `.popover` is a light, neutral material (unlike
                    // `.hudWindow`, which is deliberately dense/dark so
                    // on-screen HUDs stay legible over anything — it barely
                    // lightens no matter how low the opacity goes) — this is
                    // what gets the macOS "Clear" widget look instead of a
                    // dark HUD chip.
                    VisualEffectView(material: .popover, blendingMode: .behindWindow)
                        .opacity(opacity)
                        .clipShape(shape)
                )
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        case .card:
            content.background(shape.fill(.primary.opacity(0.10)))
        case .settingsCard:
            content.background {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            }
            .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 1))
        case .chip:
            content.background(shape.fill(.primary.opacity(0.08)))
        case .sidebarPane(let opacity):
            content.background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow).opacity(opacity))
        case .detailPane(let opacity):
            content.background(VisualEffectView(material: .underPageBackground, blendingMode: .behindWindow).opacity(opacity))
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26+, the surface's established material below it.
    func liquidGlass(_ role: GlassRole, radius: CGFloat, tint: Color? = nil) -> some View {
        modifier(LiquidGlassSurface(role: role, radius: radius, tint: tint))
    }

    /// Glass button styling on macOS 26+, borderless below it.
    @ViewBuilder
    func liquidGlassButton() -> some View {
        #if FOCALPOINT_LIQUID_GLASS
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderless)
        }
        #else
        buttonStyle(.borderless)
        #endif
    }
}

// MARK: - Container

/// Wraps sibling glass surfaces so macOS 26 can blend and morph them as one
/// material instead of compositing each independently. A plain pass-through
/// everywhere else, so it's safe to leave in the view tree.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        #if FOCALPOINT_LIQUID_GLASS
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
