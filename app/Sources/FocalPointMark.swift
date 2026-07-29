// Shared vector brand mark loaded from the bundled SVG.
// MIT License.

import SwiftUI
import AppKit

struct FocalPointMark: View {
    var color: Color = .primary

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .aspectRatio(128.0 / 64.0, contentMode: .fit)
            .foregroundStyle(color)
            .accessibilityLabel("FocalPoint")
    }

    private static let image: NSImage = {
        guard let url = Bundle.main.url(
            forResource: "focalpoint-mark",
            withExtension: "svg",
            subdirectory: "Assets"
        ), let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "scope", accessibilityDescription: "FocalPoint")!
        }
        image.isTemplate = true
        return image
    }()
}
