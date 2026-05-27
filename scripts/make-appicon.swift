import AppKit

// Rasterise icon-master.svg into the macOS AppIcon.appiconset PNGs.
// Usage: swift scripts/make-appicon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("apps/ProtelesApp_macOS/icon-master.svg")
let out = root.appendingPathComponent("apps/ProtelesApp_macOS/Sources/Assets.xcassets/AppIcon.appiconset")

guard let master = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write(Data("could not load \(svg.path)\n".utf8)); exit(1)
}

func render(_ px: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let url = out.appendingPathComponent("icon_\(px).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote icon_\(px).png")
}

for px in [16, 32, 64, 128, 256, 512, 1024] { render(px) }
