// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Meeting Transcription

struct HelpMeetingTranscriptionContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What a Diarized Meeting Looks Like")
                    .font(.headline)
                Text("SideWave figures out who spoke when, then labels the transcript by speaker. Nemotron 3 supports up to eight speaker slots. Similar voices, overlap, distance, and room noise can still affect assignment; review speaker labels before sharing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Spacing.xs) {
                    timelineTrack(label: "Speaker 1", isActive: true, activeSegments: [(0, 15), (45, 60), (90, 105)], color: .blue)
                    timelineTrack(label: "Speaker 2", isActive: true, activeSegments: [(20, 35), (65, 80), (110, 120)], color: .green)
                    timelineTrack(label: "Speaker 3", isActive: true, activeSegments: [(40, 50), (85, 95)], color: .purple)
                    timelineTrack(label: "Speaker 4", isActive: true, activeSegments: [(5, 10), (70, 75), (100, 115)], color: .pink)
                }
                .padding(Spacing.sm)
                .background(Color.primary.opacity(0.02))
                .continuousCorner(CornerRadius.md)
                .overlay(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("The resulting transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        transcriptRow(speaker: "Speaker 1", time: "0:00", text: "Hi, let's examine the wheat genetics data in SCINet.", color: .blue)
                        transcriptRow(speaker: "Speaker 2", time: "0:20", text: "I finished running the ANOVA test this morning.", color: .green)
                        transcriptRow(speaker: "Speaker 3", time: "0:40", text: "Excellent, the results look very promising.", color: .purple)
                        transcriptRow(speaker: "Speaker 4", time: "1:00", text: "Should we document these in the USDA-ARS base?", color: .pink)
                    }
                    .padding(Spacing.sm)
                    .background(.ultraThinMaterial)
                    .continuousCorner(CornerRadius.sm)
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How It Works")
                    .font(.headline)

                Text("Audio is written to disk as you record, and speaker identification runs alongside the recording. On supported Macs with the live model prepared, a draft transcript also builds during the meeting. When you stop, SideWave processes all saved audio with the final speaker model and speech recognizer. Progress stays visible until the complete transcript is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The Pipeline")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    pipelineStep("1.", "Record", "Audio is queued to local storage as it arrives. Interrupted recordings can be recovered from the audio that reached disk.")
                    pipelineStep("2.", "Identify speakers", "Nemotron 3 tracks up to eight speakers. The final pass reads all recorded parts and uses the more accurate speaker preset.")
                    pipelineStep("3.", "Transcribe", "The Parakeet TDT model converts speech to text, then text normalization converts spoken numbers and dates to written form.")
                    pipelineStep("4.", "Merge", "Each word is matched to the speaker whose turn overlaps it most, producing the final speaker-labeled transcript.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("If Something Interrupts the Meeting")
                    .font(.headline)

                Text("SideWave writes audio during recording and offers interrupted meetings at the next launch. Continue Recording adds more audio; Transcribe processes saved audio; Keep for Later leaves it on this Mac; Discard Recording deletes it. Audio still in memory, disk errors, or damaged storage can leave gaps. A recovered partial transcript is labeled and its recording is kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Quitting during a recording asks first, and Stop & Keep preserves the meeting for next launch the same way. Closing the window doesn't stop the recording: the SideWave menu bar menu shows the recording time and Stop and Transcribe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Recording Scenarios")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("Single conference mic, 4+ people around a table", "Best case when the mic is centered and the room is quiet. Ask everyone to lean in when they speak.")
                    tipRow("Audio interface or external mixer", "SideWave records one selected input. Route the participants into that input and check its channel with Test Microphone. It does not independently record several microphone devices.")
                    tipRow("Laptop mic with remote callers on speakerphone", "Hard case. Remote voices often merge because the speakerphone re-emits them. Ask remotes to join by their own mic if possible.")
                    tipRow("Noisy room or loud HVAC", "Diarization struggles. Recording still works but speaker labels may drift. Move to a quiet room if you can, or re-run speaker detection after recording.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Speakers and Names")
                    .font(.headline)

                Text("Detection is automatic, with up to eight speaker slots. You can rename speakers and rerun detection from the saved audio. A requested speaker count cannot force reliable identities.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("After transcription, click any speaker's name on the transcript to rename it (Speaker 1 becomes Alice). Names flow into every AI-generated format, so minutes and action items attribute statements to real people. If the voice split looks wrong, Identify Speakers re-splits the transcript without re-recording. Names carry over when the re-run lands on the same speaker slots, so give attributions a quick check afterward.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Getting Started")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("Enable the feature", "In Settings > Meetings, turn on Show Meetings in the main window. Meetings does not require Experimental Features.")
                    tipRow("Start a meeting", "A Meeting tab appears in the toolbar when the feature is enabled. Switch to it and click New Meeting. Prepare the meeting models in the tab before recording. The setup sheet lets you choose and test the microphone. The two speaker models total about 380 MB; speech and optional live transcription have separate downloads. If preparation fails, retry it before recording.")
                    tipRow("Stop and transcribe", "Click Stop & Transcribe when the meeting ends, or Stop & Keep to process it later from Unfinished recordings. The final pass reads the saved audio and speaker information. Progress stays visible; longer meetings take longer even when a live draft is available.")
                    tipRow("Format the result", "Format with AI turns the transcript into Meeting Minutes, a Full Report, a Summary, Action Items, Key Decisions, or a Custom format you describe yourself. Apple Intelligence formats on any Mac that has it enabled; Gemma handles the longest meetings on 16 GB or more.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Privacy and Audio")
                    .font(.headline)

                Text("Speaker identification, transcription, and meeting formatting run locally. You can copy or export the resulting transcript, including a formatted Markdown (.md) file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Audio is deleted when you dismiss a complete, saved transcript. Interrupted meetings, partial transcripts, and failed saves keep their audio for recovery. Unfinished audio is kept until you process or discard it, regardless of history retention. Keep for Later asks again at the next launch. Delete Audio & Close or Discard Recording removes it. A partial transcript is labeled because some speech may be missing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pipelineStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(number)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tipRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timelineTrack(label: String, isActive: Bool, activeSegments: [(Int, Int)], color: Color) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 110, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.04))
                        .frame(height: 12)

                    if isActive {
                        ForEach(0..<activeSegments.count, id: \.self) { index in
                            let seg = activeSegments[index]
                            let left = CGFloat(seg.0) / 120.0 * geo.size.width
                            let width = CGFloat(seg.1 - seg.0) / 120.0 * geo.size.width
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color)
                                .frame(width: width, height: 12)
                                .padding(.leading, left)
                        }
                    }
                }
            }
            .frame(height: 12)
        }
    }

    private func transcriptRow(speaker: String, time: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text("[\(time)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(speaker)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 70, alignment: .leading)

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
    }
}

// MARK: - Voice Activity Detection

struct HelpVADContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How pauses are found")
                    .font(.headline)
                
                Text("SideWave's local voice activity detector marks speech and pauses in the live audio. With live Refine on, the refine cadence decides whether a pause ends a segment: Standard waits for the 14.8-second ceiling, Faster ends it after about 3 seconds of silence, and Aggressive after about 2. Macs with 16 GB of memory or more start on Faster. Without live Refine, pauses of about 3 seconds end segments. The timeline below shows a segment closing on a 3-second pause:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Static technical boundary timeline
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: 2) {
                        timelineSegment(label: "Speech (0s - 4s)\n[Voice Detected]", color: Color.accentColor)
                        timelineSegment(label: "Pause (4s - 7s)\n[Silence]", color: .secondary.opacity(0.15))
                        timelineSegment(label: "[Segment Split]\n[3s Silence]", color: Color.accentColor, isSplitMarker: true)
                        timelineSegment(label: "Speech (7s+)\n[Voice Resumed]", color: Color.accentColor.opacity(0.85))
                    }
                    .frame(height: 52)
                    .padding(4)
                    .background(Color.primary.opacity(0.04))
                    .continuousCorner(CornerRadius.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    
                    HStack {
                        Spacer()
                        Text("On the Faster cadence, a segment splits after about 3 seconds of silence. Standard skips pause splits and waits for the 14.8-second ceiling.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Why Silence Detection Matters")
                    .font(.headline)

                Text("SideWave runs Voice Activity Detection (VAD) locally on your Mac's CPU so it doesn't compete with the speech models on the Neural Engine. VAD watches the audio for speech and marks where you pause. Under the Standard cadence those pauses don't split the segment; each one runs to the 14.8-second ceiling before it goes to the Parakeet TDT transcriber and then Refine (Gemma 4 or Apple Intelligence). Faster and Aggressive close a segment after about 3 or 2 seconds of silence, so shorter thoughts get refined sooner. Document templates use a 5-second pause. Change the cadence in Settings > Refine > Expert, shown in Advanced view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func timelineSegment(label: String, color: Color, isSplitMarker: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 8, weight: .bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(isSplitMarker ? .white : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color)
            .continuousCorner(4)
    }
}
