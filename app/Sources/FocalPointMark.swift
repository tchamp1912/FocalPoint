// Shared vector brand mark loaded from the bundled SVG.
// MIT License.

import SwiftUI
import AppKit

struct FocalPointMark: View {
    var color: Color = .primary
    var assetName: String = "focalpoint-mark"

    var body: some View {
        Image(nsImage: Self.image(named: assetName))
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .foregroundStyle(color)
            .accessibilityLabel("FocalPoint")
    }

    private static func image(named name: String) -> NSImage {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Assets"
        ), let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "scope", accessibilityDescription: "FocalPoint")!
        }
        image.isTemplate = true
        return image
    }
}
