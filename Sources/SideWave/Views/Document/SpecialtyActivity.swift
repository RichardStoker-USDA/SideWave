// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

enum SpecialtyActivity: Equatable {
    case ready, preparing, listening, listeningForInstruction, finishing, formatting, editing

    init(session: DictationSessionPhase, command: Bool, editing: Bool, generating: Bool) {
        if editing { self = .editing }
        else if session == .preparing { self = .preparing }
        else if session == .finishing { self = generating ? .formatting : .finishing }
        else if session == .listening { self = command ? .listeningForInstruction : .listening }
        else { self = .ready }
    }

    var isWorking: Bool {
        switch self {
        case .preparing, .finishing, .formatting, .editing: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .ready: "Ready"
        case .preparing: "Preparing microphone"
        case .listening: "Listening"
        case .listeningForInstruction: "Listening for an instruction"
        case .finishing: "Finishing dictation"
        case .formatting: "Formatting document"
        case .editing: "Applying your changes"
        }
    }
}

struct SpecialtyProcessingFeedback: View {
    let activity: SpecialtyActivity
    let template: String
    let backend: String
    var startedAt: Date? = nil

    private var detail: String {
        switch activity {
        case .preparing: "Speak when the microphone is ready."
        case .finishing: "The microphone has stopped. Finishing the last words."
        case .formatting: "Arranging your words as \(template.lowercased())."
        case .editing: "Your previous document is kept until the edit is complete."
        default: ""
        }
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(activity.title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                        .font(.caption.monospacedDigit()).adaptiveTertiary()
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.title)
        .accessibilityValue("\(template), \(backend). Processing is still in progress.")
    }
}
