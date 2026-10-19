// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit

/// The menu bar glyph: two interweaving wave strands that converge to points
/// at both ends; a monochrome echo of the SideWave ribbon in the app icon.
/// Drawn in code as a template image so it stays vector-crisp at any backing
/// scale and picks up the menu bar's light/dark/tinted appearance for free.
///
/// Deliberately NOT the stock `waveform` bars every dictation utility uses.
/// The front strand carries the silhouette; the back strand runs mirrored at
/// reduced opacity, so the two cross at the wave nodes and read as a braid.
enum MenuBarIcon {
    /// Cached template image, 20x16pt. NSImage's drawing-handler variant
    /// re-renders per backing scale, so the strokes stay sharp on any display.
    static let image: NSImage = {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SideWave"
        return image
    }()

    private static func draw(in rect: NSRect) {
        let inset = rect.insetBy(dx: 0.8, dy: 1.2)

        let back = strandPath(in: inset, mirrored: true)
        back.lineWidth = 1.4
        NSColor.black.withAlphaComponent(0.48).setStroke()
        back.stroke()

        let front = strandPath(in: inset, mirrored: false)
        front.lineWidth = 1.7
        NSColor.black.setStroke()
        front.stroke()
    }

    /// One wave strand. The envelope pinches to zero at both ends (the
    /// ribbon converges to points), full amplitude mid-glyph. 1.75 periods
    /// puts the strand crossings at pleasing thirds.
    private static func strandPath(in rect: NSRect, mirrored: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let samples = 120
        let midY = rect.midY
        let maxAmp = rect.height * 0.42
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let envelope = pow(sin(.pi * t), 0.62)
            var y = envelope * sin(2 * .pi * 1.75 * t)
            if mirrored { y = -y }
            let point = NSPoint(
                x: rect.minX + rect.width * CGFloat(t),
                y: midY + maxAmp * CGFloat(y)
            )
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}
