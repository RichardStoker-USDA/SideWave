// Draws the installer window background: a light surface, the braided
// SideWave wave, and an arrow from the app to Applications.
//
//   swift scripts/dmg/make-background.swift
//
// Writes scripts/dmg/background.tiff with 1x and 2x images for a 600 by 400
// point window. scripts/release.sh places the icons at y = 190.
import AppKit

let size = CGSize(width: 600, height: 400)
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    let surface = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.984, green: 0.984, blue: 0.992, alpha: 1),
        CGColor(red: 0.945, green: 0.949, blue: 0.965, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(surface, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])

    // Three strands with offset phases, like the dictation preview's wave.
    let spectrum = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.96, green: 0.36, blue: 0.40, alpha: 1),
        CGColor(red: 0.97, green: 0.64, blue: 0.27, alpha: 1),
        CGColor(red: 0.93, green: 0.83, blue: 0.26, alpha: 1),
        CGColor(red: 0.33, green: 0.78, blue: 0.48, alpha: 1),
        CGColor(red: 0.26, green: 0.56, blue: 0.96, alpha: 1),
        CGColor(red: 0.62, green: 0.38, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 0.2, 0.4, 0.6, 0.8, 1])!
    let strands: [(amplitude: CGFloat, phase: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (20, 0.0, 2.6, 0.80), (15, 1.9, 1.7, 0.55), (11, 3.6, 1.2, 0.40),
    ]
    for strand in strands {
        let path = CGMutablePath()
        for step in 0...600 {
            let x = CGFloat(step)
            // Taper toward both edges so the wave fades in and out.
            let envelope = sin(.pi * x / size.width)
            let y = 86 + sin(x / size.width * 2.6 * 2 * .pi + strand.phase) * strand.amplitude * envelope
            step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.saveGState()
        ctx.setAlpha(strand.alpha)
        ctx.addPath(path)
        ctx.setLineWidth(strand.width)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(spectrum, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
        ctx.restoreGState()
    }

    // Arrow between the two icons, centered on their row (y = 190 from the top).
    let arrowY = size.height - 190
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 252, y: arrowY))
    arrow.addLine(to: CGPoint(x: 346, y: arrowY))
    arrow.move(to: CGPoint(x: 336, y: arrowY + 8))
    arrow.addLine(to: CGPoint(x: 347, y: arrowY))
    arrow.addLine(to: CGPoint(x: 336, y: arrowY - 8))
    ctx.setStrokeColor(CGColor(red: 0.56, green: 0.58, blue: 0.63, alpha: 0.9))
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(arrow)
    ctx.strokePath()

    let caption = NSAttributedString(string: "Drag SideWave to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.42, green: 0.44, blue: 0.49, alpha: 1),
    ])
    let captionSize = caption.size()
    caption.draw(at: CGPoint(x: (size.width - captionSize.width) / 2, y: 30))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let tiff = image.tiffRepresentation(using: .lzw, factor: 0)!
try tiff.write(to: output.appendingPathComponent("background.tiff"))
print("Wrote", output.appendingPathComponent("background.tiff").path)
