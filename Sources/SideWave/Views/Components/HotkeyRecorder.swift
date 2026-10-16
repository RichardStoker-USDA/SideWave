// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

// MARK: - Hotkey Recorder Button

struct HotkeyRecorderButton: View {
    let shortcut: HotkeyShortcut
    @Binding var isRecording: Bool
    let onRecord: (HotkeyShortcut) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(isRecording ? "Press a key\u{2026}" : shortcut.displayString)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(
                    isRecording
                        ? Color.accentColor.opacity(0.15)
                        : Color.cardBackground(for: colorScheme)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.cardBorder(for: colorScheme),
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .background(
            ShortcutCaptureView(isRecording: $isRecording, onCapture: { shortcut in
                onRecord(shortcut)
            })
        )
    }
}

// MARK: - NSEvent-based Shortcut Capture

struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (HotkeyShortcut) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutNSView()
        view.onCapture = onCapture
        view.isRecordingBinding = $isRecording
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ShortcutNSView else { return }
        if isRecording {
            view.startMonitoring()
        } else {
            view.stopMonitoring()
        }
    }
}

class ShortcutNSView: NSView {
    var onCapture: ((HotkeyShortcut) -> Void)?
    var isRecordingBinding: Binding<Bool>?
    private nonisolated(unsafe) var monitor: Any?

    func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown {
                // Escape cancels recording mode
                if event.keyCode == 53 {
                    DispatchQueue.main.async {
                        self.isRecordingBinding?.wrappedValue = false
                    }
                    return nil
                }

                let shortcut = HotkeyShortcut(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags.intersection([.command, .option, .control, .shift])
                )
                self.onCapture?(shortcut)
                DispatchQueue.main.async {
                    self.isRecordingBinding?.wrappedValue = false
                }
                return nil
            }

            if event.type == .flagsChanged {
                // Capture modifier-only keys on release
                let isModifier = HotkeyShortcut.isModifierKeyCode(event.keyCode)
                if isModifier {
                    // Check if modifier was released (flags no longer contain its mask)
                    let stillDown: Bool
                    switch event.keyCode {
                    case 58, 61: stillDown = event.modifierFlags.contains(.option)
                    case 55, 54: stillDown = event.modifierFlags.contains(.command)
                    case 59, 62: stillDown = event.modifierFlags.contains(.control)
                    case 56, 60: stillDown = event.modifierFlags.contains(.shift)
                    default: stillDown = false
                    }

                    if !stillDown {
                        let shortcut = HotkeyShortcut(keyCode: event.keyCode, modifierFlags: [])
                        self.onCapture?(shortcut)
                        DispatchQueue.main.async {
                            self.isRecordingBinding?.wrappedValue = false
                        }
                        return nil
                    }
                }
            }

            return event
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

