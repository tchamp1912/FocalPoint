import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else { exit(2) }
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let layerNames = ["01-background 2.svg", "02-lens 4.svg", "03-rays 2.svg", "04-focus 2.svg"]
let layers = layerNames.compactMap { NSImage(contentsOf: source.appendingPathComponent("Assets/\($0)")) }
guard layers.count == layerNames.count else { exit(3) }

try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(Int, String, Bool)] = [
    (16, "16x16", false), (32, "16x16", true),
    (32, "32x32", false), (64, "32x32", true),
    (128, "128x128", false), (256, "128x128", true),
    (256, "256x256", false), (512, "256x256", true),
    (512, "512x512", false), (1024, "512x512", true)
]

for (pixels, logicalName, retina) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    for layer in layers {
        layer.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                   operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    let suffix = retina ? "@2x" : ""
    try rep.representation(using: .png, properties: [:])!.write(
        to: output.appendingPathComponent("icon_\(logicalName)\(suffix).png"))
}
