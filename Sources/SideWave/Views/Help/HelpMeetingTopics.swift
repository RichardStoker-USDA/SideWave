// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Meeting Transcription

struct HelpMeetingTranscriptionContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Speaker labels")
                    .font(.headline)
                Text("SideWave works out who spoke when and labels the transcript by speaker, up to eight speakers. Similar voices, crosstalk, distance, and room noise can mix up labels, so check them before you share.")
                    .font(.callout)
                    .adaptiveSecondary()
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
                        .adaptiveSecondary()

                    VStack(alignment: .leading, spacing: 4) {
                        transcriptRow(speaker: "Speaker 1", time: "0:00", text: "Let's go through the wheat trial data first.", color: .blue)
                        transcriptRow(speaker: "Speaker 2", time: "0:20", text: "I finished running the ANOVA test this morning.", color: .green)
                        transcriptRow(speaker: "Speaker 3", time: "0:40", text: "The north plots came out ahead again.", color: .purple)
                        transcriptRow(speaker: "Speaker 4", time: "1:00", text: "Should we add these to the shared notes?", color: .pink)
                    }
                    .padding(Spacing.sm)
                    .background(.ultraThinMaterial)
                    .continuousCorner(CornerRadius.sm)
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How it works")
                    .font(.headline)

                Text("Audio is saved to disk as you record, and speaker identification runs during the recording. On Macs with 16 GB of memory or more, a live transcript can build too. When you stop, SideWave runs the final speaker and speech passes over all the saved audio and shows progress until the transcript is ready.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The steps")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    pipelineStep("1.", "Record", "Audio goes to disk as it arrives, so an interrupted recording can be recovered.")
                    pipelineStep("2.", "Identify speakers", "Nemotron 3 tracks up to eight speakers; the final pass uses its more accurate setting.")
                    pipelineStep("3.", "Transcribe", "Parakeet TDT writes the text, and spoken numbers and dates become digits.")
                    pipelineStep("4.", "Merge", "Each word goes to the speaker whose turn overlaps it most.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("If a meeting is interrupted")
                    .font(.headline)

                Text("At the next launch, SideWave offers the interrupted meeting: Continue Recording adds to it, Transcribe processes the saved audio, Keep for Later leaves it for another time, and Discard Recording deletes it. Audio that hadn't reached disk is lost, and a partial transcript is labeled as partial.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("Quitting during a recording asks first; Stop & Keep saves the meeting for later. Closing the window doesn't stop the recording, and the menu bar menu shows the time and Stop and Transcribe.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Rooms and microphones")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("One conference mic, several people at a table", "Works best with the mic in the middle of a quiet room.")
                    tipRow("Audio interface or mixer", "SideWave records one input. Route everyone into it and check the channel with Test Microphone.")
                    tipRow("Laptop mic with remote callers on speaker", "Remote voices often merge into one speaker, because they all come from the same loudspeaker.")
                    tipRow("Noisy room", "Speaker labels can drift. Identify Speakers can run again on the saved audio afterward.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Speakers and names")
                    .font(.headline)

                                Text("Click a speaker's name in the transcript to rename it, and meeting notes use the new names. If the split looks wrong, Identify Speakers runs again on the saved audio. Names carry over when a speaker keeps the same slot, so check them afterward.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Getting started")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("Turn it on", "In Settings > Meetings, turn on Show Meetings in the main window.")
                    tipRow("Start a meeting", "Open the Meeting tab and prepare its models; the speaker models are about 380 MB, and the optional live transcript about 600 MB. Then click New Meeting, choose and test the microphone, and start.")
                    tipRow("Stop and transcribe", "Click Stop & Transcribe when the meeting ends, or Stop & Keep to process it later from Unfinished recordings. Longer meetings take longer to process.")
                    tipRow("Write notes", "Format with AI turns the transcript into Meeting Minutes, a Full Report, a Summary, Action Items, Key Decisions, or a Custom format you describe. Gemma handles the longest meetings on Macs with 16 GB or more.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Privacy and audio")
                    .font(.headline)

                Text("Speaker identification, transcription, and meeting notes run on your Mac. Copy the transcript or save it as a Markdown (.md) file.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("Audio is deleted once a complete transcript is saved and closed. Interrupted meetings, partial transcripts, and failed saves keep their audio until you process or discard it, whatever your History setting. Delete Audio & Close or Discard Recording removes it.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pipelineStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(number)
                .font(.callout.weight(.medium))
                .adaptiveSecondary()
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .adaptiveSecondary()
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
                .adaptiveSecondary()
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
                .adaptiveSecondary()
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
                
                Text("A voice activity detector marks speech and pauses as you talk. With Refine on, the refine cadence decides whether a pause ends a segment: Standard waits for the 14.8-second limit, Faster ends a segment after about 3 seconds of silence, and Aggressive after about 2. Macs with 16 GB of memory or more start on Faster. Without Refine, a pause of about 3 seconds ends a segment.")
                    .font(.callout)
                    .adaptiveSecondary()
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
                        Text("Faster: a 3-second pause ends the segment.")
                            .font(.caption.weight(.medium))
                            .adaptiveSecondary()
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Why pauses matter")
                    .font(.headline)

                Text("A finished segment goes to Parakeet and then Refine, so ending segments at pauses gets shorter thoughts refined sooner, at the cost of more processing. Document templates end segments at 5-second pauses. Change the cadence in Settings > Refine > Expert, in Advanced view.")
                    .font(.callout)
                    .adaptiveSecondary()
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
