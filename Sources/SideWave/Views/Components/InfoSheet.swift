// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Short explanation shown from an info button. Every explanation in the
/// app uses this one layout so they read the same way.
struct InfoTopic: Identifiable, Hashable {
    struct Point: Hashable {
        let icon: String
        let title: String
        let body: String
    }

    let title: String
    let icon: String
    let points: [Point]
    var id: String { title }
}

struct InfoSheet: View {
    let topic: InfoTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label {
                Text(topic.title).font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: topic.icon).foregroundStyle(Color.accentColor)
            }
            .font(.title3)

            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(topic.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: Spacing.md) {
                        Image(systemName: point.icon)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(point.title).font(.callout.weight(.semibold))
                            Text(point.body)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
        .buttonBorderShape(.capsule)
    }
}
