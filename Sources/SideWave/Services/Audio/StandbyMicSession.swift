// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import AudioToolbox
import AVFAudio
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// MARK: - Persistent mic-standby session

/// Keeps an `AVCaptureSession` running on the default input so the mic stays powered. macOS powers it
/// down a few seconds after the last capture ends, and the next engine start then waits 1 to 3 s for
/// the hardware. The Sound settings input meter avoids this the same way. The mic indicator stays on
/// while it runs; every buffer is discarded, nothing is recorded or saved. Controlled by
/// `keepMicOnStandby`, off by default.
final class StandbyMicSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    // session + boundDeviceUID are read on the MainActor (start/stop/isRunning)
    // and mutated from the background config queue, so both are lock-guarded.
    private let lock = NSLock()
    private var _session: AVCaptureSession?
    private var _boundDeviceUID: String?
    private let queue = DispatchQueue(
        label: "com.sidewave.standby-mic",
        qos: .background
    )

    /// True if the persistent capture session is currently running.
    var isRunning: Bool {
        lock.lock(); let s = _session; lock.unlock()
        return s?.isRunning ?? false
    }

    /// UID of the device this session actually bound (nil = system default
    /// at bind time). Lets the owner detect that the user's device selection
    /// has drifted from what standby is warming and rebind.
    var boundDeviceUID: String? {
        lock.lock(); defer { lock.unlock() }; return _boundDeviceUID
    }

    @discardableResult
    func start(deviceUID: String?) -> Bool {
        lock.lock(); let alreadyClaimed = _session != nil; lock.unlock()
        guard !alreadyClaimed else { return true }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return false
        }

        let optionalDevice: AVCaptureDevice?
        if let uid = deviceUID, let customDevice = AVCaptureDevice(uniqueID: uid) {
            optionalDevice = customDevice
        } else {
            optionalDevice = AVCaptureDevice.default(for: .audio)
        }

        guard let device = optionalDevice else {
            return false
        }

        let newSession = AVCaptureSession()
        // Claim the slot synchronously so a re-entrant start() is a no-op and
        // the owner's isRunning / boundDeviceUID reads stay coherent.
        lock.lock()
        _boundDeviceUID = device.uniqueID
        _session = newSession
        lock.unlock()

        // Device input creation, configuration, and start all wait on the device, so run them off
        // the main thread. If configuration fails, free the slot so a later start() can try again.
        queue.async { [weak self, weak newSession] in
            guard let self, let newSession else { return }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                newSession.beginConfiguration()
                guard newSession.canAddInput(input) else {
                    newSession.commitConfiguration()
                    self.clearSessionIfCurrent(newSession)
                    return
                }
                newSession.addInput(input)

                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard newSession.canAddOutput(output) else {
                    newSession.commitConfiguration()
                    self.clearSessionIfCurrent(newSession)
                    return
                }
                newSession.addOutput(output)
                newSession.commitConfiguration()
            } catch {
                self.clearSessionIfCurrent(newSession)
                return
            }
            newSession.startRunning()
        }
        return true
    }

    /// Release the session slot if `s` is still current (a config failure on
    /// the background queue), so standby isn't wedged holding a non-running
    /// session that blocks the next start().
    private func clearSessionIfCurrent(_ s: AVCaptureSession) {
        lock.lock()
        if _session === s {
            _session = nil
            _boundDeviceUID = nil
        }
        lock.unlock()
    }

    /// Stops the persistent session. No-op if not running.
    func stop() {
        lock.lock(); let s = _session; _session = nil; lock.unlock()
        guard let s else { return }
        // Stop on the same queue as the start, so they can't race.
        queue.async {
            s.stopRunning()
        }
    }

    /// Every buffer is discarded; the session only keeps the hardware awake.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Intentionally empty. Sample buffers are immediately discarded.
    }
}

extension Notification.Name {
    /// The set of input-device UIDs changed (dock plug/unplug, USB
    /// re-enumeration). Posted by AudioDeviceManager.performRefresh.
    public static let sideWaveAudioDeviceSetChanged = Notification.Name("com.sidewave.app.audioDeviceSetChanged")
}
