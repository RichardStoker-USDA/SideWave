// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Dedicated dashboard for the Meeting tab. Shows different content based on state:
/// - Idle: start button + recent transcripts
/// - Recording: live stats with duration, audio level, speaker detection status
/// - Processing: progress indicator with stage description
/// - Complete: transcript ready with view/delete actions
struct MeetingDashboardView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var showSetup = false
    @State private var activeSheet: MeetingSheet?
    @AppStorage("historyRetentionDays") private var retentionDays: Int = 7
    /// Refresh disk usage once a second, independently of the audio meter.
    @State private var recordingDiskUsage: String = "--"
    @State private var recoverableMeetings: [OrphanedMeeting] = []
    /// Cancel during a live recording destroys everything captured so far;
    /// a single mis-click must not do that silently.
    @State private var showCancelConfirmation = false
    @State private var meetingToDelete: MeetingTranscript?

    private enum MeetingSheet: Identifiable {
        case results(MeetingTranscript)
        case formatter(MeetingTranscript)

        var id: String {
            switch self {
            case .results(let t): return "results-\(t.id)"
            case .formatter(let t): return "formatter-\(t.id)"
            }
        }
    }

    var body: some View {
        Group {
            switch appState.meetingService.state {
            case .idle:
                idleView
            case .recording(let duration):
                recordingView(duration: duration)
            case .processing(let stage):
                processingView(stage: stage)
            case .complete:
                completeView
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonBorderShape(.capsule)
        .safeAreaInset(edge: .top) {
            if let error = MeetingHistoryStore.shared.persistenceError {
                HStack(spacing: 12) {
                    Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Show Storage") { NSWorkspace.shared.open(MeetingHistoryStore.shared.storageDirectory) }
                    Button("Retry Save") { MeetingHistoryStore.shared.retrySaving() }
                }
                .padding(12)
                .background(.regularMaterial)
            }
        }
        .sheet(isPresented: $showSetup) {
            MeetingSetupSheet(appState: appState) { expectedSpeakers in
                appState.meetingService.expectedSpeakers = expectedSpeakers
                Task {
                    // Re-check at start time: dictation may have begun while
                    // the setup sheet was open.
                    if appState.isDictationBusy {
                        appState.showToast("Finish the dictation first", icon: "waveform.badge.exclamationmark")
                        return
                    }
                    do {
                        try await appState.meetingService.startRecording(
                            deviceUID: appState.audioDeviceManager.selectedDeviceUID
                        )
                        // Agent TTS through the speakers would play straight
                        // into the meeting mic.
                        appState.meetingCaptureBegan()
                    } catch {
                        // Surface the failure instead of dropping the user back
                        // on the idle view with no feedback. The service already
                        // tore down the half-installed tap, so a retry is clean.
                        appState.meetingService.state = .error(error.localizedDescription)
                        appState.showToast("Couldn't start meeting recording", icon: "waveform.badge.exclamationmark")
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .results(let transcript):
                // A row reopened from Recent isn't the live service transcript:
                // its audio + word cache were released in a prior session, so
                // rediarize can't run and "Delete Audio" would be a no-op. Bind
                // the sheet to the live transcript only when the ids match.
                let liveTranscript = appState.meetingService.transcript
                let isLive = liveTranscript?.id == transcript.id
                let displayedTranscript = isLive ? (liveTranscript ?? transcript) : transcript
                let canRedo = isLive && appState.meetingService.canRediarize
                MeetingResultsView(
                    transcript: displayedTranscript,
                    isLiveMeeting: isLive,
                    onDismiss: { activeSheet = nil },
                    onPurgeAudio: {
                        if isLive {
                            appState.meetingService.reset(discardAudio: true)
                        } else {
                            MeetingHistoryStore.shared.deleteMeeting(id: transcript.id)
                        }
                        activeSheet = nil
                    },
                    onRediarize: canRedo ? { (expected: Int?) in
                        Task {
                            await appState.meetingService.rediarize(expected: expected)
                            if let updated = appState.meetingService.transcript {
                                activeSheet = .results(updated)
                            }
                        }
                    } : nil,
                    isRediarizing: {
                        if isLive, case .processing = appState.meetingService.state { return true }
                        return false
                    }(),
                    // Live renames go through the service so Format-with-AI
                    // sees current names; history rows write store-only.
                    onRenameSpeaker: isLive ? { id, name in
                        appState.meetingService.updateSpeakerName(id: id, name: name)
                    } : nil
                )
                .frame(width: 640, height: displayedTranscript.hasSpeech ? 560 : 360)
            case .formatter(let transcript):
                MeetingFormatView(appState: appState, transcript: transcript)
                    .frame(width: 640, height: 560)
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: Binding(
            get: { meetingToDelete != nil },
            set: { if !$0 { meetingToDelete = nil } }
        ), titleVisibility: .visible, presenting: meetingToDelete) { meeting in
            Button("Delete Meeting", role: .destructive) {
                MeetingHistoryStore.shared.deleteMeeting(id: meeting.id)
                meetingToDelete = nil
            }
            Button("Cancel", role: .cancel) { meetingToDelete = nil }
        } message: { _ in
            Text("The saved transcript and its generated notes will be deleted. This cannot be undone.")
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                meetingHeader
                if appState.meetingService.meetingModelsState.isReady {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(appState.meetingService.isStartingRecording ? "Preparing microphone" : "Ready to record")
                                    .font(.title3.weight(.semibold))
                                Text(appState.meetingService.isStartingRecording
                                     ? "Wait for Recording before speaking."
                                     : "Capture the conversation, then review speakers and create notes.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Spacing.lg)
                            if appState.meetingService.isStartingRecording {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("Preparing microphone")
                            } else {
                                Button("New Meeting", systemImage: "record.circle") { showSetup = true }
                                    .prominentActionButton()
                                    .disabled(appState.isDictationBusy)
                            }
                        }
                        Divider()
                        Label(meetingMicrophoneName, systemImage: "mic")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("Up to 8 speakers. Audio stays on this Mac and is saved as you record.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if appState.isDictationBusy {
                            Text("Finish dictation before starting a meeting.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
                } else {
                    meetingModelsCard
                }

                if !recoverableMeetings.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Unfinished recordings").font(.callout.weight(.semibold))
                        ForEach(recoverableMeetings) { recording in
                            HStack {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(recording.startedAt, style: .date).font(.callout)
                                    Text("\(formatDuration(recording.recordedDuration)) saved on this Mac")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Recover") { appState.pendingMeetingRecovery = [recording] }
                                    .actionButton()
                            }
                        }
                    }
                }

                // Recent meetings
                let unfinishedIDs = Set(recoverableMeetings.map(\.id))
                let recentMeetings = MeetingHistoryStore.shared.meetings.filter {
                    $0.hasSpeech || !unfinishedIDs.contains($0.id)
                }
                if !recentMeetings.isEmpty {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Recent meetings")
                            .font(.callout.weight(.semibold))

                        ForEach(recentMeetings) { meeting in
                            recentMeetingRow(meeting)
                        }
                    }
                    .padding(Spacing.md)
                    .settingsCardStyle()

                    // Retention info
                    if retentionDays > 0 {
                        Text("Completed transcripts auto-delete after \(retentionDays) days. Change in Settings > Privacy.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .softScrollEdge()
        .task(id: appState.pendingMeetingRecovery.map(\.id)) {
            guard !AppPaths.isTestHost else { return }
            recoverableMeetings = MeetingSessionStore.scanForOrphans()
            // Prepare the meeting models on first meeting-tab
            // visit. Idempotent. No-op if already ready or already
            // downloading. Subsequent visits skip immediately.
            appState.meetingService.prepareMeetingModels()
            // Warm the live-transcript ASR when its model is already cached
            // (16GB+ Macs). Cached-only by design: never a silent download.
            await appState.meetingService.prepareLiveTranscriptModel()
        }
    }

    // MARK: - Meeting Models Preparation Card

    /// Preparation progress is replaced by the recording controls when ready.
    @ViewBuilder
    private var meetingModelsCard: some View {
        switch appState.meetingService.meetingModelsState {
        case .notPrepared:
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Preparing meeting models\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(meetingModelsSizeCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let detail = appState.meetingService.modelPrepDetail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardStyle()

        case .downloading(let progress):
            // Compiling (and cache listing) carry no byte feedback, so show an
            // indeterminate bar and drop the percent — a fraction sitting still
            // reads as frozen.
            let indeterminate = appState.meetingService.modelPrepIndeterminate
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: indeterminate ? "gearshape" : "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(indeterminate ? "Preparing meeting models" : "Downloading meeting models")
                            .font(.callout.weight(.semibold))
                        // Live per-model detail ("N of T files", "Compiling…")
                        // beats a static blurb; falls back to the honest total.
                        Text(appState.meetingService.modelPrepDetail ?? meetingModelsSizeCopy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !indeterminate {
                        Text("\(Int(progress * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if indeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            .padding(Spacing.md)
            .settingsCardStyle()

        case .ready:
            EmptyView()

        case .error(let message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Couldn't download meeting models")
                            .font(.callout.weight(.semibold))
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Button("Retry Download") {
                    appState.meetingService.prepareMeetingModels()
                }
                .actionButton()
            }
            .padding(Spacing.md)
            .settingsCardStyle()
        }
    }

    private var meetingModelsSizeCopy: String {
        HardwareDetector.physicalMemoryGB() >= 16
            ? "Speaker models: ~380 MB. Live transcript: ~600 MB. The speech model is shared with dictation. Only missing files are downloaded."
            : "Speaker models: ~380 MB. The speech model is shared with dictation. Only missing files are downloaded."
    }

    // MARK: - Recording View (live stats)

    private var meetingMicrophoneName: String {
        appState.audioDeviceManager.selectedDevice?.name
            ?? appState.audioDeviceManager.resolvedDefaultDevice.map { "System: \($0.name)" }
            ?? "System default"
    }

    private var meetingHeader: some View {
        HStack {
            Text("Meetings").font(.system(size: 22, weight: .semibold))
            Spacer()
            Button("Meeting Help", systemImage: "questionmark.circle") {
                appState.requestedHelpSection = .meetingTranscription
                openWindow(id: "help")
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
            .help("Meeting Help")
            Button("Meeting Settings", systemImage: "gearshape") {
                appState.requestedSettingsTab = .settingsMeetings
                openWindow(id: "settings")
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
            .help("Meeting Settings")
        }
    }

    private func recordingView(duration: TimeInterval) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                meetingHeader
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    HStack {
                        Label("Recording", systemImage: "record.circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.recordingRed)
                        Spacer()
                        Text(formatDuration(duration))
                            .font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    AudioWaveVisualizer(audioLevel: appState.meetingService.audioLevel,
                        colorMode: "rainbow", sensitivity: 1.0, liquidGlass: false)
                        .frame(height: 32).accessibilityHidden(true)
                    Label(meetingMicrophoneName, systemImage: "mic")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Label("Saving audio on this Mac", systemImage: "internaldrive")
                        Spacer()
                        Text(recordingDiskUsage).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: Spacing.sm) {
                        Button("Stop & Keep") {
                            appState.meetingService.stopRecording()
                            appState.meetingCaptureEnded()
                            appState.meetingService.keepForLater()
                        }
                        .actionButton()
                        .help("Keep the recording to transcribe or resume later")
                        Menu {
                            Button("Discard Recording", role: .destructive) { showCancelConfirmation = true }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Recording options")
                        Spacer(minLength: Spacing.sm)
                        Button("Stop & Transcribe", systemImage: "stop.fill") {
                            appState.meetingService.stopRecording()
                            appState.meetingCaptureEnded()
                            appState.meetingService.processRecording()
                        }
                        .prominentActionButton()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))

                if appState.meetingService.liveTranscriptAvailable {
                    if appState.meetingService.liveSegments.isEmpty {
                        Text("Listening. A draft transcript appears here as speech is recognized.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        liveTranscriptCard
                    }
                } else {
                    Text("Your transcript will be prepared from the saved audio when you stop.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .padding(24)
        }
        .softScrollEdge()
        .confirmationDialog("Discard this recording?", isPresented: $showCancelConfirmation,
                            titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                appState.meetingService.reset(discardAudio: true)
                appState.meetingCaptureEnded()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The \(formatDuration(duration)) recorded so far will be deleted. Stop & Keep preserves it for later.")
        }
        .task {
            recordingDiskUsage = diskUsage
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                recordingDiskUsage = diskUsage
            }
        }
    }

    // MARK: - Live Transcript Card

    /// Rolling tail of the finalized live segments during recording. Capped
    /// at the last 6 so the recording view stays calm; the results view is
    /// where the full transcript lives.
    private var liveTranscriptCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Live transcript")
                .font(.callout.weight(.semibold))

            ForEach(appState.meetingService.liveSegments.suffix(6)) { segment in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(appState.meetingService.speakerNames[segment.speakerId] ?? segment.speakerLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 76, alignment: .leading)
                    Text(segment.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardStyle()
    }

    // MARK: - Processing View

    private func processingView(stage: MeetingState.ProcessingStage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                meetingHeader
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text(stage.description).font(.title3.weight(.semibold))
                    Text(stageDescription(stage)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress = appState.meetingService.processingProgress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let detail = appState.meetingService.modelPrepDetail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("The recording stays on this Mac until the transcript is saved. You can keep it and finish later.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Stop Processing & Keep Audio") { appState.meetingService.keepForLater() }
                        .actionButton()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
            }
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - Complete View

    private var completeView: some View {
        let isPartial = appState.meetingService.transcript?.isPartial == true
        let hasSpeech = appState.meetingService.transcript?.hasSpeech == true
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                meetingHeader
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Label(!hasSpeech ? "No speech detected" : (isPartial ? "Partial Transcript Recovered" : "Transcript Ready"),
                          systemImage: !hasSpeech ? "waveform" : (isPartial ? "doc.badge.ellipsis" : "checkmark.circle"))
                        .font(.title3.weight(.semibold))
                    if hasSpeech, let transcript = appState.meetingService.transcript {
                        Text(transcript.segmentSpeakerSummary)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let warning = appState.meetingService.postRecordingWarning {
                        Text(warning).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !hasSpeech {
                        Text("No words were recognized. Check the microphone before recording again. Saved audio can be processed again from Recovery Options.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack(spacing: Spacing.sm) {
                        Button("New Meeting") {
                            appState.meetingService.reset()
                            showSetup = true
                        }
                        .actionButton()
                        Button("Done") { appState.meetingService.reset() }
                            .actionButton()
                        Spacer(minLength: Spacing.sm)
                        if hasSpeech {
                            Button("Format with AI") {
                                if let t = appState.meetingService.transcript {
                                    activeSheet = .formatter(t)
                                }
                            }
                            .actionButton()
                        } else {
                            Button("Microphone Settings") {
                                appState.requestedSettingsTab = .settingsAudio
                                openWindow(id: "settings")
                            }
                            .actionButton()
                        }
                        Button(hasSpeech ? "View Transcript" : "Recovery Options") {
                            if let t = appState.meetingService.transcript {
                                activeSheet = .results(t)
                            }
                        }
                        .prominentActionButton()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .softScrollEdge()
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        let hasRecoverableAudio = appState.meetingService.audioFileURL != nil
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                meetingHeader
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Label(hasRecoverableAudio ? "Transcription didn't finish" : "Couldn't start the meeting",
                          systemImage: "exclamationmark.circle")
                        .font(.title3.weight(.semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let transcript = appState.meetingService.transcript {
                        Button("View Saved Transcript") { activeSheet = .results(transcript) }
                            .actionButton()
                    }

                    if hasRecoverableAudio {
                        Text("Saved audio is kept on this Mac. You can try again now or finish later.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        HStack(spacing: Spacing.sm) {
                            Button("Keep for Later") { appState.meetingService.keepForLater() }
                                .actionButton()
                            Menu {
                                Button("Discard Recording", role: .destructive) { showCancelConfirmation = true }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Recording options")
                            Spacer(minLength: Spacing.sm)
                            Button("Try Again") {
                                if appState.meetingService.canRediarize {
                                    Task { await appState.meetingService.rediarize(expected: nil) }
                                } else {
                                    appState.meetingService.processRecording()
                                }
                            }
                            .prominentActionButton()
                        }
                    } else {
                        Button("Dismiss") { appState.meetingService.reset() }
                            .actionButton()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
            }
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .padding(24)
        }
        .confirmationDialog("Discard this recording?", isPresented: $showCancelConfirmation,
                            titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { appState.meetingService.reset(discardAudio: true) }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The saved audio will be deleted. This cannot be undone.")
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func stageDescription(_ stage: MeetingState.ProcessingStage) -> String {
        switch stage {
        case .preparingModels: return "Downloading and loading speaker identification models. This may take a moment on first use."
        case .diarizing:
            return "Analyzing the audio to identify individual speakers and when they spoke."
        case .transcribing: return "Converting audio to text using the Parakeet speech recognition model."
        case .merging: return "Combining speaker identification with transcribed text."
        }
    }

    private var diskUsage: String {
        guard let url = appState.meetingService.audioFileURL else { return "--" }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return size.byteCountText
    }

    // MARK: - Recent Meeting Row

    private func recentMeetingRow(_ meeting: MeetingTranscript) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: meeting.hasSpeech ? "person.3" : "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(meeting.formattedDate)
                    .font(.callout.weight(.medium))
                Text(meeting.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // View transcript
            Button {
                activeSheet = .results(meeting)
            } label: {
                Image(systemName: "doc.text")
                    .font(.callout).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(meeting.hasSpeech ? "View transcript" : "Meeting details")
            .accessibilityLabel(meeting.hasSpeech ? "View transcript" : "Meeting details")

            // Format with AI
            Button {
                activeSheet = .formatter(meeting)
            } label: {
                Image(systemName: "text.badge.checkmark")
                    .font(.callout).frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!meeting.hasSpeech)
            .help(meeting.hasSpeech ? "Format with AI" : "No speech is available to format")
            .accessibilityLabel("Format with AI")

            // Delete
            Button(role: .destructive) {
                meetingToDelete = meeting
            } label: {
                Image(systemName: "trash")
                    .font(.callout).frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete meeting")
            .accessibilityLabel("Delete meeting")
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            activeSheet = .results(meeting)
        }
    }
}
