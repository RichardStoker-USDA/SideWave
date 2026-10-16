// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Scrollback Container

/// Constants for ScrollbackContainer. Static stored properties aren't
/// allowed inside generic types, so they live on a dedicated enum.
private enum ScrollbackConstants {
    /// View ID of the bottom anchor (1pt transparent spacer at end of
    /// content). ScrollViewReader scrolls to it on content change + idle
    /// snap-back.
    static let bottomAnchorID: String = "scrollback-bottom"
    /// Seconds without scrolling before returning to the live edge: 2.5 s normally, 8 s when
    /// expanded, since the expanded view is for reading earlier text.
    static let idleSnapDelay: TimeInterval = 2.5
    static let expandedIdleSnapDelay: TimeInterval = 8.0
}

/// Lets the user scroll back through earlier segments during dictation, then returns to the live
/// edge after a short idle. `.defaultScrollAnchor(.bottom)` keeps it on the latest text otherwise,
/// and the scroll bar stays hidden.
///
/// `.onScrollGeometryChange` detects scrolling away from the bottom; after `idleSnapDelay` seconds
/// without scrolling it returns, instantly with Reduce Motion. The caller's fade mask makes older
/// text fade at the top edge.
struct ScrollbackContainer<Content: View>: View {
    let height: CGFloat
    let resetTrigger: AnyHashable
    let reduceMotion: Bool
    /// When true, the idle snap-back uses the longer expanded delay so
    /// users intentionally browsing scrollback have time to read.
    var expanded: Bool = false
    var growsFromTop = false
    @ViewBuilder let content: () -> Content

    /// True after the user scrolled away from the bottom; new text doesn't pull them back. Cleared
    /// when they return to the bottom or the idle timer fires.
    @State private var userScrolledAway: Bool = false
    /// Coalesced task that snaps back to bottom after idle. Reset on every
    /// scroll event so consecutive wheel ticks don't trigger early snaps.
    @State private var idleSnapTask: Task<Void, Never>? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Bottom anchor. Invisible 1pt spacer used by
                    // ScrollViewReader to scroll-to-live-edge.
                    Color.clear
                        .frame(height: 1)
                        .id(ScrollbackConstants.bottomAnchorID)
                }
                // Content at least as tall as the scroll view, so short transcripts sit at the
                // bottom instead of jumping down as text arrives.
                .frame(minHeight: height, alignment: growsFromTop ? .top : .bottom)
            }
            .scrollIndicators(growsFromTop ? .automatic : .never)
            .defaultScrollAnchor(.bottom)
            .frame(height: height)
            // More than 4 pt above the bottom counts as scrolled away; smaller drift from text
            // growth doesn't.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let maxOffsetY = max(0, geometry.contentSize.height - geometry.containerSize.height)
                return geometry.contentOffset.y < maxOffsetY - 4
            } action: { _, scrolledAway in
                if scrolledAway && !userScrolledAway {
                    userScrolledAway = true
                    rescheduleIdleSnap(proxy: proxy)
                } else if !scrolledAway && userScrolledAway {
                    // User scrolled back to bottom on their own. Clear
                    // the flag and cancel the snap timer.
                    userScrolledAway = false
                    idleSnapTask?.cancel()
                    idleSnapTask = nil
                } else if scrolledAway {
                    // Already away; user wheel-tick is a fresh activity
                    // signal. Push the snap timer back.
                    rescheduleIdleSnap(proxy: proxy)
                }
            }
            // On transcript changes, return to the live edge unless the user scrolled away. The
            // scroll is instant: partials arrive every 160 ms, and animated scrolls would overlap.
            // The explicit scroll matters after large changes such as a boundary merge shortening
            // the text; the idle return is animated separately.
            .onChange(of: resetTrigger) {
                guard !userScrolledAway else { return }
                proxy.scrollTo(ScrollbackConstants.bottomAnchorID, anchor: .bottom)
            }
            .onDisappear {
                idleSnapTask?.cancel()
                idleSnapTask = nil
            }
        }
    }

    /// Cancel any pending snap-back task and schedule a fresh one. Called
    /// on every detected scroll-away event so the user has a fresh idle
    /// budget after each wheel tick.
    private func rescheduleIdleSnap(proxy: ScrollViewProxy) {
        idleSnapTask?.cancel()
        idleSnapTask = Task { @MainActor in
            let delay = expanded
                ? ScrollbackConstants.expandedIdleSnapDelay
                : ScrollbackConstants.idleSnapDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            // After idle, snap back to live edge. Smooth animation so the
            // transition reads as deliberate ("you're caught up") rather
            // than a yank.
            if reduceMotion {
                proxy.scrollTo(ScrollbackConstants.bottomAnchorID, anchor: .bottom)
            } else {
                withAnimation(Animate.appleSmooth) {
                    proxy.scrollTo(ScrollbackConstants.bottomAnchorID, anchor: .bottom)
                }
            }
            userScrolledAway = false
            idleSnapTask = nil
        }
    }
}

// MARK: - Expand Toggle Button

/// Small corner button that enlarges or restores the overlay: faint at rest, clearer on hover. The
/// parent animates the size change, and the icon rotates between states.
struct ExpandToggleButton: View {
    @Binding var isExpanded: Bool
    let reduceMotion: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(Animate.appleSnappy) {
                    isExpanded.toggle()
                }
            }
        } label: {
            Image(systemName: isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(isHovered ? 0.95 : 0.50))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isExpanded ? "Restore Size" : "Expand Overlay")
        .accessibilityLabel(isExpanded ? "Restore overlay size" : "Expand overlay")
    }
}
