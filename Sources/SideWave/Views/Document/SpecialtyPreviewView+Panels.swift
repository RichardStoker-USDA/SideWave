// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

extension SpecialtyPreviewView {
    // MARK: - Ask bar

    var askBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Change this document").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                TextField(askPlaceholder, text: Bindable(appState).agenticEditInstruction, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain).font(.body)
                    .focused($isInstructionFocused)
                    .disabled(activity.isWorking || docEmpty || isEngineRunning)
                    .accessibilityLabel("Instruction for changing the document")
                    .onSubmit { submitAsk() }
                if !isEditing {
                    micButton
                    Button("Apply", action: submitAsk)
                        .buttonStyle(.borderedProminent)
                        .disabled(instructionEmpty || docEmpty || activity.isWorking || isEngineRunning || !isEditModelReady)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(askBorderColor, lineWidth: 1))
        }
    }

    private var askPlaceholder: String {
        if docEmpty { return "Dictate or type a document first" }
        if isVoiceAsking { return "Listening\u{2026} say how to change the page" }
        return "Ask for a change, such as \"make this a list\""
    }

    private var askBorderColor: Color {
        if isVoiceAsking { return Color.recordingRed.opacity(0.85) }
        if isInstructionFocused { return Color.accentColor.opacity(0.85) }
        return Color.primary.opacity(0.1)
    }

    /// Spoken instruction: click and speak; the recording goes to the Ask field as a command and
    /// applies when you stop. Available only when the document has content.
    private var micButton: some View {
        Button(action: toggleVoiceAsk) {
            Label(isVoiceAsking ? "Finish" : "Speak change", systemImage: isVoiceAsking ? "stop.fill" : "mic")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .disabled(docEmpty || isVoiceDictating || activity.isWorking || (!isVoiceAsking && !isEditModelReady))
        .help(isVoiceAsking ? "Stop and apply the spoken instruction" : "Speak an instruction to change the document")
        .accessibilityLabel(isVoiceAsking ? "Apply spoken instruction" : "Speak a change to the document")
    }

    private var editingHelpButton: some View {
        HelpLink { showEditingHelp.toggle() }
        .help("How this editor works")
        .popover(isPresented: $showEditingHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Label("Start a document", systemImage: "mic.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text("Press \(hotkeyDisplay) to start a new document. Finish dictation to format it. Your previous document is kept in Recents.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                Label("Change the document", systemImage: "text.bubble")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text("Type an instruction here and press Return, or choose Speak change and say it. For example \"remove step 2\" or \"make this a bulleted list.\" Undo steps back through applied edits.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                Label("Add more content", systemImage: "text.append")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text("Choose Add dictation to continue this document, or Edit text to type into it. Closing the window saves your work; the next shortcut starts a new document.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(.callout, design: .rounded))
            .frame(width: 340, alignment: .leading)
            .padding(Spacing.lg)
        }
    }

    // MARK: - Footer

    var footer: some View {
        HStack(spacing: Spacing.md) {
            Text("\(wordCount) words").monospacedDigit().fixedSize()
            Button {
                appState.requestedSettingsTab = .settingsRefine
                openWindow(id: "settings")
            } label: {
                Text(appState.dictationFormatter.activeBackend.displayName)
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless).help("Choose the local editing model")
            Spacer(minLength: 0)
            if !undoStack.isEmpty {
                Button("Undo", systemImage: "arrow.uturn.backward", action: undoLastEdit)
                    .buttonStyle(.borderless).disabled(activity.isWorking || isEngineRunning)
                    .keyboardShortcut("z", modifiers: [.command, .option])
            }
            Button {
                showActivity.toggle()
            } label: {
                Label(appState.specialtyQueuedSegments.isEmpty ? "Activity" : "\(appState.specialtyQueuedSegments.count) additions",
                      systemImage: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Review edits and pending dictation")
            .popover(isPresented: $showActivity, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Document activity").font(.headline)
                    activityRail
                }
                .frame(width: 320, alignment: .leading)
                .padding(20)
                .buttonBorderShape(.capsule)
            }
            editingHelpButton
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var wordCount: Int {
        appState.specialtyEditedText.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Activity rail

    // The side panel appears only with something to show: applied edits, queued additions, live
    // insights, or an edit in progress. During plain recording the document keeps the full width.
    private var railHasContent: Bool {
        !appliedAsks.isEmpty
            || !appState.specialtyQueuedSegments.isEmpty
            || appState.transcriptionService.specialtyLiveStatus != nil
            || isEditing
    }

    private var activityRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !appliedAsks.isEmpty {
                    appliedAsksSection
                }
                if let paused = appState.pendingSessionText {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Paused dictation").font(.headline)
                        Text(paused).font(.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Copy Words") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(paused, forType: .string)
                        }
                            .buttonStyle(.bordered)
                    }
                }
                if !appState.specialtyQueuedSegments.isEmpty {
                    pendingAdditionsSection
                }
                insightsSection
                if !railHasContent && appState.pendingSessionText == nil {
                    Text("Applied edits and pending dictation appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, Spacing.xs)
            .padding(.bottom, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { activityContentHeight = $0 }
        }
        .frame(height: min(340, max(64, activityContentHeight)))
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private var railStatus: some View {
        if isEditing || isEngineRunning {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(isEditing
                     ? "Assistant is reshaping the page\u{2026}"
                     : (isVoiceAsking ? "Listening for your instruction\u{2026}" : "Listening\u{2026}"))
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private var appliedAsksSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Image(systemName: "text.badge.checkmark")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Applied Edits")
                    .font(.system(.headline, design: .rounded))
                Spacer()
                if !undoStack.isEmpty {
                    Button {
                        undoLastEdit()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Undo the most recent edit")
                    .accessibilityLabel("Undo the most recent edit")
                }
            }

            VStack(spacing: Spacing.sm) {
                ForEach(Array(appliedAsks.enumerated()), id: \.element.id) { index, ask in
                    railCard {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Image(systemName: index == 0 ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(index == 0 ? Color.accentColor : .secondary)
                                .padding(.top, 1)
                                .accessibilityHidden(true)
                            Text(ask.instruction)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var pendingAdditionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Pending Additions")
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Text("\(appState.specialtyQueuedSegments.count)")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxxs)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }

            VStack(spacing: Spacing.sm) {
                ForEach(appState.specialtyQueuedSegments) { item in
                    railCard {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(item.text)
                                .font(.system(.body, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .foregroundStyle(.primary.opacity(0.85))

                            HStack {
                                Button("Append") { appState.appendSpecialtyAddition(id: item.id) }
                                .prominentActionButton()
                                .controlSize(.small)
                                .disabled(activity.isWorking || isEngineRunning)
                                .help("Add this to the end of the document")

                                Button("Dismiss") {
                                    guard !activity.isWorking, !isEngineRunning else { return }
                                    appState.specialtyQueuedSegments.removeAll { $0.id == item.id }
                                }
                                .actionButton()
                                .controlSize(.small)
                                .disabled(activity.isWorking || isEngineRunning)
                                .help("Discard this segment")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        // Live model insights, useful while dictating (understanding / planned
        // action / questions). Only shown when the model actually produced them.
        if let status = appState.transcriptionService.specialtyLiveStatus {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.secondary)
                        .font(.headline)
                        .accessibilityHidden(true)
                    Text("Live AI Insights")
                        .font(.system(.headline, design: .rounded))
                }

                insightBlock(label: "UNDERSTANDING", icon: "lightbulb.fill", text: status.understanding)

                if !status.plannedAction.isEmpty {
                    insightBlock(label: "PLANNED ACTION", icon: "list.bullet.indent", text: status.plannedAction)
                }

                if !status.questions.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Label("QUESTIONS / DISCOVERIES", systemImage: "text.bubble")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        ForEach(status.questions, id: \.self) { question in
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                                    .accessibilityHidden(true)
                                Text(question)
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                            .padding(Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    }
                }
            }
        }
    }

    private func insightBlock(label: String, icon: String, text: String) -> some View {
        railCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(label, systemImage: icon)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Subtle inner card that floats on the glass slab (no heavy material box).
    @ViewBuilder
    private func railCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    // MARK: - Behavior

    /// Start page-filling dictation from the UI. Same entry point the dashboard
    /// record button uses; on an empty page AppState routes this to the document.
    func startVoiceDictation() {
        guard !isEngineRunning, !activity.isWorking else { return }
        if appState.pendingSessionText != nil { appState.resumePendingSession() }
        else {
            appState.nextDictationTarget = .document
            appState.handleStartRecording()
        }
    }

    /// Speak one edit instruction without changing the global shortcut's new-document action.
    private func toggleVoiceAsk() {
        guard !docEmpty, appState.pendingSessionText == nil else { return }
        Task { @MainActor in
            if isEngineRunning {
                await appState.handleStopRecording()
            } else if !appState.isProcessingAgenticEdit {
                appState.nextDictationTarget = .askBar
                appState.handleStartRecording()
            }
        }
    }

    /// Send the typed instruction to the assistant.
    private func submitAsk() {
        guard !instructionEmpty, !docEmpty, !activity.isWorking, !isEngineRunning, isEditModelReady,
              appState.pendingSessionText == nil else { return }
        Task { await appState.applyAgenticEdit() }
    }

    /// Mirror a spoken edit command into the instruction field. Byte-for-byte
    /// the same behavior the two text observers had before.
    func mirrorCommandDictation() {
        if appState.isCommandDictation {
            let combined = (appState.transcriptionService.confirmedText + " " + appState.transcriptionService.volatileText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appState.agenticEditInstruction = combined
        }
    }

    /// Snapshot for undo + capture the instruction when an edit starts; on land,
    /// commit the snapshot, log the applied ask, and flash. Skips no-ops /
    /// cancels / failures (they restore the original text).
    func handleEditProcessingChange(old: Bool, new: Bool) {
        if new {
            pendingUndoSnapshot = appState.agenticEditOriginalText
            let instruction = appState.agenticEditInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingAskInstruction = instruction.isEmpty ? nil : instruction
        } else if let snapshot = pendingUndoSnapshot {
            let instruction = pendingAskInstruction
            pendingUndoSnapshot = nil
            pendingAskInstruction = nil
            if appState.specialtyEditedText != snapshot {
                undoStack.append(snapshot)
                if undoStack.count > Self.historyCap {
                    undoStack.removeFirst(undoStack.count - Self.historyCap)
                }
                appliedAsks.insert(AppliedAsk(instruction: instruction ?? "Edited the page"), at: 0)
                if appliedAsks.count > Self.historyCap {
                    appliedAsks.removeLast(appliedAsks.count - Self.historyCap)
                }
                editLandedToken &+= 1
            }
        }
    }

    private func undoLastEdit() {
        guard !activity.isWorking, let previous = undoStack.popLast() else { return }
        if !appliedAsks.isEmpty { appliedAsks.removeFirst() }
        // A user-initiated write, same path the Pending-Additions "Append"
        // buttons use — no programmatic-write flag, so `specialtyIsEdited`
        // latches exactly as a manual edit would.
        appState.specialtyEditedText = previous
    }

    func copyToClipboard() {
        guard !activity.isWorking, !docEmpty else { return }
        TypingService.writeSensitiveString(appState.specialtyEditedText, to: .general)

        withAnimation(reduceMotion ? nil : Animate.quick) {
            copySuccess = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(reduceMotion ? nil : Animate.quick) {
                copySuccess = false
            }
        }
    }
}
