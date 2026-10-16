// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import FluidAudio
import AVFAudio
import Foundation
import os
import Sparkle
import SwiftUI

@MainActor
extension AppState {
    // MARK: - Resolve Dictation Input

    /// Starts or stops the mic standby session to match `keepMicOnStandby`. Called from its didSet
    /// and retried by the keep-alive task when permission arrives after launch.
    func applyMicStandbyState() {
        if keepMicOnStandby {
            guard !isDictationBusy, !meetingService.isCaptureActive, !MicTestController.isCapturing,
                  !AudioSetupActivity.isActive else { return }
            if standbyMicSession == nil {
                standbyMicSession = StandbyMicSession()
            }
            // Warm the device the next dictation will use, resolved the same way as in
            // startRecording, and rebind when the selection changed.
            let targetUID = resolveDictationInputUID()
            if let session = standbyMicSession, session.isRunning,
               let bound = session.boundDeviceUID, let target = targetUID,
               bound != target {
                session.stop()
            }
            if let session = standbyMicSession, !session.isRunning {
                _ = session.start(deviceUID: targetUID)
            }
        } else {
            standbyMicSession?.stop()
            standbyMicSession = nil
        }
    }

    /// True when the persistent mic-standby session is actively running.
    /// Read by the dashboard / settings to drive the indicator UI.
    var isMicOnStandby: Bool {
        standbyMicSession?.isRunning ?? false
    }

    /// Idle priming must not compete with capture, diagnostics or a late HAL teardown.
    private func primeMicrophoneWhenIdle(standbyOn: Bool) async -> Bool {
        guard !isDictationBusy, !meetingService.isCaptureActive, !MicTestController.isCapturing,
              !Task.isCancelled, AudioSetupActivity.begin() else { return false }
        return await Task.detached(priority: .utility) {
            defer { AudioSetupActivity.end() }
            let coreAudioPrimed = standbyOn || AudioDeviceManager.primeDefaultInputIOProc()
            let enginePrimed = AudioDeviceManager.primeAVAudioEngineForDefaultInput()
            return coreAudioPrimed && enginePrimed
        }.value
    }

    /// CoreAudio keep-alive for the app's lifetime: reads input device properties on a timer, the
    /// way the Sound settings meter keeps devices in use, which avoids slow engine setup on the
    /// next press. No audio is captured.
    func startHalKeepAliveTimer() {
        halKeepAliveTask?.cancel()
        halKeepAliveTask = Task { [weak self] in
            // First sweep happens immediately so the very first hotkey press
            // after launch sees a warm HAL even if the app was just opened.
            Task.detached(priority: .utility) {
                AudioDeviceManager.warmAllInputDevicesHAL()
            }

            // With mic standby on, start its session now; it keeps the input device awake, so the
            // one-time IO prime below is skipped, avoiding a second mic indicator flash at launch.
            await MainActor.run { [weak self] in
                self?.applyMicStandbyState()
            }
            let standbyOn = await MainActor.run { [weak self] in
                self?.keepMicOnStandby ?? false
            }

            // Two-step prime so the first press isn't cold when standby is off; both wait for mic
            // permission and the loop retries. Standby keeps the device awake but doesn't warm this
            // process's audio engine caches, which cost 500 to 1500 ms on first use, so the engine
            // is primed either way. Only the IO prime is skipped when standby covers it.
            var hasPrimed = false
            if AVAudioApplication.shared.recordPermission == .granted {
                hasPrimed = await self?.primeMicrophoneWhenIdle(standbyOn: standbyOn) ?? false
                // Bind the kept dictation engine to the device the next press will use. The
                // throwaway prime warms shared caches; binding the real engine removes the slow
                // step from the first press.
                await MainActor.run { [weak self] in
                    guard let self, !self.meetingService.isCaptureActive else { return }
                    self.transcriptionService.prewarmEngineBinding(
                        deviceUID: self.resolveDictationInputUID()
                    )
                }
            }

            while !Task.isCancelled {
                // Check every 1.5 s while setup is settling (waiting on the IO prime, or on standby
                // to engage), then every 15 s. Property reads don't engage the device, so the
                // slower pace doesn't affect start latency, and it lets an idle menu bar app sleep.
                // If standby drops, the fast pace resumes.
                let settling: Bool
                if let s = self {
                    settling = s.keepMicOnStandby ? !s.isMicOnStandby : !hasPrimed
                } else {
                    return
                }
                let sleepInterval: UInt64 = settling ? 1_500_000_000 : 15_000_000_000
                do {
                    try await Task.sleep(nanoseconds: sleepInterval)
                } catch { return }
                guard let strongSelf = self else { return }
                Task.detached(priority: .utility) {
                    AudioDeviceManager.warmAllInputDevicesHAL()
                }

                // Retry the standby session if it should be on but isn't
                // yet (permission granted mid-launch). Cheap to call —
                // start() is a no-op when already running.
                let shouldBeOnStandby = strongSelf.keepMicOnStandby
                if shouldBeOnStandby {
                    strongSelf.applyMicStandbyState()
                }

                // Retry one-shot primes if standby is OFF and primes
                // haven't succeeded yet. Skip when standby is ON (the
                // persistent session covers it).
                if !hasPrimed,
                   AVAudioApplication.shared.recordPermission == .granted {
                    hasPrimed = await strongSelf.primeMicrophoneWhenIdle(standbyOn: shouldBeOnStandby)
                }

                // Keep the engine bound. Does nothing during a session or when an engine exists;
                // after sleep or a late permission grant it rebuilds the binding.
                if !strongSelf.meetingService.isCaptureActive,
                   AVAudioApplication.shared.recordPermission == .granted {
                    strongSelf.transcriptionService.prewarmEngineBinding(
                        deviceUID: strongSelf.resolveDictationInputUID()
                    )
                }
            }
        }
    }

    /// The device UID the dictation engine should bind to: the user's selection, or the current
    /// macOS default resolved to a UID. Resolving it up front keeps the input unit from probing
    /// devices during setup, which can touch Bluetooth and cause an audible glitch.
    func resolveDictationInputUID() -> String? {
        if let explicit = audioDeviceManager.selectedDeviceUID {
            return explicit
        }
        let defaultID = AudioDeviceManager.defaultInputDeviceID()
        guard defaultID != 0 else { return nil }
        return AudioDeviceManager.deviceUID(defaultID)
    }
}
