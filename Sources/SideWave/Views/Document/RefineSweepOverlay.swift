// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Refine sweep overlay

/// A left-to-right accent sweep that plays each time `token` changes, matching the dictation
/// overlay's refine sweep, so an edit visibly lands. With Reduce Motion it's an instant highlight.
struct RefineSweepOverlay: View {
    let token: Int
    let reduceMotion: Bool

    @State private var phase: CGFloat = 0
    @State private var sweeping = false
    @State private var tintOn = false

    var body: some View {
        GeometryReader { geo in
            let bandWidth = geo.size.width * 0.45
            ZStack {
                Color.accentColor.opacity(tintOn ? 0.10 : 0)
                if sweeping && !reduceMotion {
                    LinearGradient(
                        colors: [.clear, Color.accentColor.opacity(0.32), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: -bandWidth + phase * (geo.size.width + bandWidth))
                }
            }
            .allowsHitTesting(false)
            .onChange(of: token) { _, newValue in
                guard newValue > 0 else { return }
                if reduceMotion {
                    tintOn = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tintOn = false }
                    return
                }
                phase = 0
                sweeping = true
                withAnimation(.easeOut(duration: 0.2)) { tintOn = true }
                withAnimation(.easeInOut(duration: Animate.refinedSweepTotalMs)) {
                    phase = 1
                } completion: {
                    sweeping = false
                    withAnimation(.easeInOut(duration: 0.4)) { tintOn = false }
                }
            }
        }
    }
}
