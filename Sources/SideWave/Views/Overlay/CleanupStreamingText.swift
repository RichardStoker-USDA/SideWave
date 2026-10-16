// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Cleanup Streaming Text

/// Splits streaming text into a stable prefix and a new tail. The stream must only append; if new
/// text diverges from what's on screen, it replaces everything instead of slicing a wrong tail.
/// Separate from the view so it can be tested.
enum StreamDeltaResolver {
    struct Result: Equatable {
        var stable: String
        var volatile: String
        /// True only on a clean append, where the fresh tail should animate in.
        var bumpGeneration: Bool
    }

    static func resolve(stable: String, volatile: String, lastLen: Int, reduceMotion: Bool, new: String) -> Result {
        if reduceMotion {
            return Result(stable: new, volatile: "", bumpGeneration: false)
        }
        if new.count < lastLen {
            // Shrink: final-collapse, cancel, or stream reset. Promote wholesale.
            return Result(stable: new, volatile: "", bumpGeneration: false)
        } else if new.count > lastLen {
            let prefix = stable + volatile
            if new.hasPrefix(prefix) {
                let tailStart = new.index(new.startIndex, offsetBy: lastLen)
                return Result(stable: prefix, volatile: String(new[tailStart...]), bumpGeneration: true)
            } else {
                // Ghost-text guard: the new value is NOT a strict append of what's
                // on screen, so slicing at lastLen would strand stale glyphs.
                // Replace wholesale instead.
                return Result(stable: new, volatile: "", bumpGeneration: false)
            }
        } else if stable + volatile != new {
            // Same length, different content: a same-length token correction.
            return Result(stable: new, volatile: "", bumpGeneration: false)
        }
        // No change.
        return Result(stable: stable, volatile: volatile, bumpGeneration: false)
    }
}

/// Shows streamed Refine output, fading in each new chunk while the text before it stays put, with
/// a caret while generating. No animation with Reduce Motion. One string slice and one counter
/// update per chunk.
struct CleanupStreamingText: View {
    let streamText: String
    let isGenerating: Bool
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    @State private var stableText: String = ""
    @State private var volatileText: String = ""
    @State private var volatileGeneration: Int = 0
    @State private var lastLen: Int = 0
    @State private var caretVisible: Bool = true
    @State private var caretTask: Task<Void, Never>? = nil

    private var showCaret: Bool {
        isGenerating && !reduceMotion
    }

    private var textShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.12)
    }

    var body: some View {
        let content = Text(stableText + volatileText).foregroundColor(colorScheme == .dark ? .white : .black)
        let caret = Text(showCaret ? "\u{258C}" : "")
            .foregroundColor(Color(white: colorScheme == .dark ? 0.65 : 0.42).opacity(caretVisible ? 1.0 : 0.25))
        Text("\(content)\(caret)")
        .font(.system(.body, design: .default, weight: .medium))
        .shadow(color: textShadowColor, radius: 2, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(nil)
        // Invisible overlay anchored at the leading edge: its view identity
        // changes each delta, which drives the transition. The actual text
        // above animates opacity naturally through SwiftUI text diffing.
        .overlay(alignment: .bottomLeading) {
            Text(volatileText)
                .font(.system(.body, design: .default, weight: .medium))
                .foregroundStyle(Color.clear)
                .id(volatileGeneration)
                .transition(
                    .opacity.combined(with: .offset(y: 2))
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: volatileGeneration)
        .onAppear {
            // Seed state from the current streamText. Covers the case where
            // the view appears mid-stream (e.g., cleanup kicked in before
            // the overlay mounted the cleanup branch).
            if !streamText.isEmpty && stableText.isEmpty && volatileText.isEmpty {
                stableText = streamText
                lastLen = streamText.count
            }
            startCaretPulseIfNeeded()
        }
        .onDisappear {
            caretTask?.cancel()
            caretTask = nil
        }
        .onChange(of: streamText) { _, new in
            applyDelta(new)
        }
        .onChange(of: isGenerating) { _, _ in
            startCaretPulseIfNeeded()
        }
        .onChange(of: reduceMotion) { _, _ in
            startCaretPulseIfNeeded()
        }
        .accessibilityLabel(streamText)
    }

    private func applyDelta(_ new: String) {
        // `StreamDeltaResolver` decides; this applies its result.
        let result = StreamDeltaResolver.resolve(
            stable: stableText,
            volatile: volatileText,
            lastLen: lastLen,
            reduceMotion: reduceMotion,
            new: new
        )
        stableText = result.stable
        volatileText = result.volatile
        if result.bumpGeneration { volatileGeneration &+= 1 }
        lastLen = new.count
    }

    private func startCaretPulseIfNeeded() {
        caretTask?.cancel()
        caretTask = nil
        guard showCaret else {
            caretVisible = true
            return
        }
        caretTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.25)) {
                    caretVisible.toggle()
                }
            }
        }
    }
}
