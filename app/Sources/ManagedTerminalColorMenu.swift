// FocalPoint — shared terminal accent menu for live managed sessions.
// MIT License.

import SwiftUI

struct ManagedTerminalColorMenu: View {
    let onSelect: (String) -> Void

    private let colors: [(name: String, hex: String, color: Color)] = [
        ("Blue", "#60A5FA", Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255)),
        ("Purple", "#A78BFA", Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)),
        ("Green", "#34D399", Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)),
        ("Amber", "#FBBF24", Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)),
        ("Rose", "#FB7185", Color(red: 251 / 255, green: 113 / 255, blue: 133 / 255)),
        ("Cyan", "#22D3EE", Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255)),
    ]

    var body: some View {
        Menu("Terminal Color") {
            ForEach(colors, id: \.hex) { option in
                Button { onSelect(option.hex) } label: {
                    Label {
                        Text(option.name)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(option.color)
                    }
                }
            }
        }
    }
}
