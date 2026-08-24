// FocalPoint menu-bar app — the semantic settings-card system.
//
// One canonical card for the settings/editor panes, plus the small set of
// density variants those surfaces actually need. The canonical regular card
// is 16pt inner padding under `GlassRole.settingsCard` at a 12pt continuous
// radius (`Metrics.rowRadius * 1.5`); pages are inset 20pt with a 22pt
// vertical card rhythm. Everything else is a *named* deviation from that
// pattern, so a dense list or an inline diagnostic reads as a deliberate
// variant at the call site instead of an ad hoc padding/radius pair.
// MIT License.

import SwiftUI

extension Metrics {
    /// Canonical settings-card chrome: inner padding under
    /// `GlassRole.settingsCard` at a continuous 12pt radius.
    static let settingsCardPadding: CGFloat = 16
    static let settingsCardRadius: CGFloat = rowRadius * 1.5
    /// Settings/editor page layout: page inset and vertical card rhythm.
    static let settingsPageInset: CGFloat = 20
    static let settingsCardRhythm: CGFloat = 22
    /// Keeps explanatory copy and row controls readable when the unified
    /// window is stretched across a large display.
    static let settingsContentMaxWidth: CGFloat = 1040
}

/// The card densities the settings/editor panes use. All variants share the
/// `GlassRole.settingsCard` material; only padding and radius change.
enum SettingsCardVariant {
    /// Standard grouped card — the default for settings and editor sections.
    case regular
    /// Dense row lists (e.g. Hotkeys): tighter padding so rows, not chrome,
    /// carry the rhythm; the card radius stays canonical.
    case list
    /// Inline diagnostics and error callouts: the most compact treatment,
    /// at the row radius, so it nests inside a page without reading as a
    /// peer of the content cards.
    case alert

    var padding: CGFloat {
        switch self {
        case .regular: return Metrics.settingsCardPadding
        case .list: return 12
        case .alert: return 10
        }
    }

    var radius: CGFloat {
        switch self {
        case .regular, .list: return Metrics.settingsCardRadius
        case .alert: return Metrics.rowRadius
        }
    }
}

private struct SettingsCardStyle: ViewModifier {
    let variant: SettingsCardVariant

    func body(content: Content) -> some View {
        content
            .padding(variant.padding)
            .liquidGlass(.settingsCard, radius: variant.radius)
    }
}

/// The one nested-fill treatment inside a card (text editors, sub-groups):
/// a faint primary wash at a radius that sits cleanly inside the parent
/// card's 12pt corner. Replaces per-call-site ad hoc fills.
private struct SettingsInset: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius - 2, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct SettingsPageLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Metrics.settingsContentMaxWidth, alignment: .topLeading)
            .padding(Metrics.settingsPageInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One title hierarchy for every Settings detail page. Optional actions stay
/// aligned to the title rather than becoming a detached control above a card.
struct SettingsPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String?
    let tint: Color
    let actions: Actions

    init(title: String, subtitle: String? = nil, symbol: String? = nil,
         tint: Color = .accentColor, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil,
         tint: Color = .accentColor) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
            EmptyView()
        }
    }
}

/// Consistent title and supporting-copy treatment inside regular cards.
struct SettingsCardHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// A settings-pane card in the given density (default: the canonical
    /// regular card).
    func settingsCard(_ variant: SettingsCardVariant = .regular) -> some View {
        modifier(SettingsCardStyle(variant: variant))
    }

    /// The named inset fill for nested input/grouping surfaces inside a
    /// settings card. Apply after the content's own padding.
    func settingsInset() -> some View {
        modifier(SettingsInset())
    }

    /// Standard width, outer inset, and leading alignment for Settings pages.
    func settingsPageLayout() -> some View {
        modifier(SettingsPageLayout())
    }
}
