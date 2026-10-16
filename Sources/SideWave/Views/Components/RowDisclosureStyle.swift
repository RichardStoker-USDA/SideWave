// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Disclosure groups that open from anywhere on their header row, not only
/// from the triangle. Apply it to each DisclosureGroup, never to a window or
/// a sidebar: sidebar List sections are disclosure groups too, and this
/// style would flatten each section into one row.
struct RowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowDisclosure(configuration: configuration)
    }
}

extension DisclosureGroupStyle where Self == RowDisclosureStyle {
    static var row: RowDisclosureStyle { RowDisclosureStyle() }
}

private struct RowDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovered && isEnabled ? .primary : .secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Hides these options" : "Shows these options")

            if configuration.isExpanded {
                // Content lines up with the label text, as in Finder.
                configuration.content
                    .padding(.leading, 12 + Spacing.xs)
                    .transition(.opacity)
            }
        }
    }
}
