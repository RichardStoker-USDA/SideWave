// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import MCP
import Security
#if canImport(System)
import System
#endif

// MARK: - MCP Server Manager

/// Local MCP server for voice agents, over a Unix domain socket instead of HTTP so macOS doesn't
/// ask for network permission. MCP clients connect through the `sidewave-mcp` helper, which bridges
/// stdio to the socket.
@Observable
@MainActor
final class MCPServerManager {
    var isRunning = false
    var lastError: String?

    /// When true, speak calls are silently dropped. Set by hotkey interrupt
    /// to prevent in-flight speak calls from playing after the user starts talking.
    /// Automatically resets after recording stops.
    var speechSuppressed = false

    // The socket (Self.socketPath) is owner-only (0600), so only processes running as this user can
    // connect, the same boundary as the user's keychain.

    private var serverSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Running client handler tasks, so `stop()` can cancel them rather than relying on the socket
    /// closing.
    private var clientTasks: Set<Task<Void, Never>> = []

    /// Socket path in the user's private runtime folder, or /tmp. Every non-release build uses a
    /// separate dev path, so a debug build never binds or removes the release app's socket.
    static var isDevBuild: Bool {
        #if DEBUG
        return true
        #else
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sidewave.app"
        return bundleID.contains(".dev")
        #endif
    }

    static var socketPath: String {
        // XDG_RUNTIME_DIR is user-private on Linux. On macOS, use the per-user
        // temp directory which is already permissions-restricted to the current user.
        let userTmp = NSTemporaryDirectory() // e.g., /var/folders/xx/.../T/
        let name = isDevBuild ? "sidewave-mcp-dev.sock" : "sidewave-mcp.sock"
        return (userTmp as NSString).appendingPathComponent(name)
    }

    // Callbacks for speak tool -- Int32 is the connection fd for voice assignment
    var onSpeak: ((String, Int32) -> Void)?
    var onQueueSpeech: ((String, Int32) -> Void)?
    var onReplaceSpeech: ((String, Int32) -> Void)?

    // Callbacks for status, live transcript, and speech queue
    var getTranscriptState: (() -> (confirmed: String, volatile: String, isRecording: Bool))?
    var getTtsState: (() -> (initialized: Bool, speaking: Bool, voice: String))?
    var onStopSpeaking: (() -> Void)?
    var getPlaybackStatus: (() -> (playing: String, preBuffered: String, pending: [String]))?
    /// Called when a connection closes so TTS can release the voice assignment.
    var onConnectionClosed: ((Int32) -> Void)?

    // Draft response manager for speculative triggering v2.
    weak var draftManager: DraftResponseManager?

    /// The speech service, set by AppState. With it, the speak, queue, and replace tools report the
    /// real outcome (started, queued, dropped, still downloading, failed) instead of only
    /// acceptance. Also lets TTSService drop speech at playback time while the user is recording.
    weak var ttsService: TTSService? {
        didSet {
            ttsService?.isSuppressed = { [weak self] in self?.speechSuppressed ?? false }
        }
    }

    private let boundSocketPath: String
    private var lifecycleID = UUID()

    init(socketPath: String = MCPServerManager.socketPath) {
        boundSocketPath = socketPath
    }

    // MARK: - Legacy Credential Cleanup

    /// Removes the MCP bearer-token credential (keychain service `com.sidewave.mcp-auth-token`) and
    /// `mcpAuth*` defaults left by builds that used HTTP. The token was never checked and the socket
    /// replaced it. Runs once.
    static func purgeLegacyAuthCredential() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "legacyMCPAuthCredentialPurged") else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sidewave.mcp-auth-token",
            kSecAttrAccount as String: "mcp-bearer-token",
            kSecUseDataProtectionKeychain as String: true,
        ]
        // errSecItemNotFound is the expected result for users who never
        // stored one; treat it (and success) as done.
        SecItemDelete(query as CFDictionary)

        defaults.removeObject(forKey: "mcpAuthEnabled")
        defaults.removeObject(forKey: "mcpAuthToken")
        defaults.set(true, forKey: "legacyMCPAuthCredentialPurged")
    }

    // MARK: - Server Lifecycle

    private static func removeStaleSocket(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        _ = fcntl(probe, F_SETFL, O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(destination).copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result < 0, errno == ECONNREFUSED else { return false }
        return unlink(path) == 0
    }

    func start() async {
        guard !isRunning else { return }
        lastError = nil

        guard Self.removeStaleSocket(at: boundSocketPath) else {
            lastError = "Another SideWave instance is using the voice-agent connection."
            return
        }
        lifecycleID = UUID()
        let generation = lifecycleID

        // Create raw POSIX Unix domain socket
        serverSocketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocketFD >= 0 else {
            lastError = "Failed to create socket"
            return
        }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = boundSocketPath.utf8CString
        guard pathBytes.count <= 104 else {
            lastError = "Socket path is too long (max 103 characters)"
            close(serverSocketFD); serverSocketFD = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
            }
        }

        // Restrict the umask so bind() creates the socket owner-only from the start. Otherwise it
        // could be briefly connectable by others between bind() and the chmod() below. Restored
        // right after.
        let savedUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(savedUmask)
        guard bindResult == 0 else {
            lastError = "Failed to bind: \(String(cString: strerror(errno)))"
            close(serverSocketFD); serverSocketFD = -1
            return
        }
        // Other users cannot connect; processes under this account can.
        chmod(boundSocketPath, 0o600)
        guard listen(serverSocketFD, 5) == 0 else {
            lastError = "Failed to listen: \(String(cString: strerror(errno)))"
            unlink(boundSocketPath)
            close(serverSocketFD); serverSocketFD = -1
            return
        }

        isRunning = true
        print("[MCPServer] Listening on private Unix socket")

        // Set socket to non-blocking so accept() never parks a thread
        let flags = fcntl(serverSocketFD, F_GETFL)
        _ = fcntl(serverSocketFD, F_SETFL, flags | O_NONBLOCK)

        // Use GCD DispatchSource for read-readiness instead of a blocking accept loop.
        // This avoids parking a Swift Concurrency cooperative pool thread, which can
        // starve other async work (transcription, TTS, relay) under load.
        let fd = serverSocketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            // Accept every pending connection: DispatchSource combines read events, so one event
            // can stand for several clients.
            while true {
                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(fd, sockPtr, &clientLen)
                    }
                }
                guard clientFD >= 0 else { break }  // EAGAIN = no more pending

                var noSignal: Int32 = 1
                guard setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    close(clientFD)
                    continue
                }

                print("[MCPServer] Client connected (fd: \(clientFD))")

                // The event arrives on a global queue; this task hops to the main actor, where
                // MCPServerManager runs.
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.lifecycleID == generation else {
                        close(clientFD)
                        return
                    }
                    let t: Task<Void, Never> = Task { [weak self] in
                        guard let self else {
                            close(clientFD)
                            return
                        }
                        await self.handleClient(fd: clientFD)
                    }
                    self.clientTasks.insert(t)
                    _ = await t.value
                    self.clientTasks.remove(t)
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        guard isRunning || serverSocketFD >= 0 else { return }
        lifecycleID = UUID()
        isRunning = false
        if let source = acceptSource {
            source.cancel()
        } else if serverSocketFD >= 0 {
            close(serverSocketFD)
        }
        acceptSource = nil
        serverSocketFD = -1
        unlink(boundSocketPath)
        // Cancel any live per-client handlers. Without this, stop()
        // returned while handlers still held FDs open against the now-
        // unlinked socket path.
        for task in clientTasks { task.cancel() }
        clientTasks.removeAll()
        print("[MCPServer] Stopped")
    }

    // MARK: - Connection Handling

    /// Handle a client connection using StdioTransport with the socket's file descriptor.
    /// Runs in a detached task so it never blocks MainActor.
    private nonisolated func handleClient(fd: Int32) async {
        Self.debugLog("handleClient start fd=\(fd)")

        let server = MCP.Server(
            name: "SideWave",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        Self.debugLog("registering tool handlers")
        await registerToolHandlers(on: server, connectionID: fd)
        Self.debugLog("tool handlers registered")

        // StdioTransport on the socket for input and output, speaking the same newline-delimited
        // JSON-RPC as the sidewave-mcp helper.
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fd),
            output: FileDescriptor(rawValue: fd)
        )

        Self.debugLog("starting server.start(transport:)")
        do {
            try await server.start(transport: transport)
            // server.start() returns at once and runs its loop in a task; waitUntilCompleted()
            // waits for the client to disconnect before the socket is closed.
            try Task.checkCancellation()
            await withTaskCancellationHandler {
                await server.waitUntilCompleted()
            } onCancel: {
                shutdown(fd, SHUT_RDWR)
                Task { await server.stop() }
            }
            Self.debugLog("server message loop completed")
        } catch {
            Self.debugLog("server.start threw: \(error)")
            if !Task.isCancelled {
                print("[MCPServer] Client disconnected: \(error.localizedDescription)")
            }
        }

        await server.stop()
        // Notify that this connection is closing so TTS can release the voice
        await MainActor.run { [weak self] in
            self?.onConnectionClosed?(fd)
        }

        close(fd)
        Self.debugLog("Connection closed fd=\(fd)")
    }

    /// Debug log written to a file; disabled in release builds.
    private nonisolated static func debugLog(_ msg: String) {
        #if DEBUG
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidewave-mcp-debug.log")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
        #endif
    }

    // MARK: - Tool Registration

    private func registerToolHandlers(on server: MCP.Server, connectionID: Int32) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "speak",
                    description: "Speak aloud to the user through SideWave TTS. Safe to call multiple times -- if audio is already playing, new text queues after the current sentence finishes naturally. If the user is recording (pressed hotkey), this call is dropped and returns status 'suppressed' so you don't talk over them; re-send after they finish. ALWAYS call this BEFORE writing long terminal output. Write conversationally: short sentences, no numbered lists or bullet points, use transitions like 'so', 'also', 'one more thing'. Proper punctuation matters for TTS rhythm. Keep under 200 words per call.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("Conversational text to speak. Write for the ear: short sentences, contractions, natural pacing. Use periods and commas for rhythm. Ellipses add a pause.")
                            ]),
                        ]),
                        "required": .array([.string("text")])
                    ])
                ),
                Tool(
                    name: "check_status",
                    description: "Check SideWave state: TTS readiness or first-run download progress, whether audio is playing, and the active voice. TTS loads lazily on your first speak call, so an early check may report status 'uninitialized' -- that is normal, just call speak. On a fresh machine the first speak downloads the voice model; poll this to watch download_progress until status is 'ready'.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),
                Tool(
                    name: "get_live_transcript",
                    description: "Get the current live transcript while the user is dictating. Returns confirmed text, volatile (in-progress) text, and recording status. Poll this during active dictation to pre-compute your response before the user finishes speaking.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),
                Tool(
                    name: "submit_draft_response",
                    description: "Submit a draft response while the user dictates. SideWave queues it for speech after dictation only if the final transcript still matches. Synthesis and playback take time; get_playback_status reports actual playback. Only one draft can be pending; a new one replaces it. Drafts expire after 30 seconds and are discarded when the transcript changes.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("The pre-computed response text to speak via TTS.")
                            ]),
                            "transcript_snapshot": .object([
                                "type": .string("string"),
                                "description": .string("The confirmed transcript text your response is based on.")
                            ]),
                        ]),
                        "required": .array([.string("text"), .string("transcript_snapshot")])
                    ])
                ),
                Tool(
                    name: "get_draft_status",
                    description: "Check the outcome of a previously submitted draft response. Returns: pending, used, discarded, expired, or cancelled.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "draft_id": .object([
                                "type": .string("string"),
                                "description": .string("The draft ID returned by submit_draft_response.")
                            ]),
                        ]),
                        "required": .array([.string("draft_id")])
                    ])
                ),
                Tool(
                    name: "queue_speech",
                    description: "Append text to the speech queue without interrupting current playback. SideWave splits text into sentences and plays them sequentially, pre-synthesising the next one so transitions don't pop.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("Text to queue. Auto-split into sentences.")
                            ]),
                        ]),
                        "required": .array([.string("text")])
                    ])
                ),
                Tool(
                    name: "replace_speech",
                    description: "Replace all unplayed queued sentences with new text. The currently-playing sentence finishes naturally, then the new text plays.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("New text to replace pending queue.")
                            ]),
                        ]),
                        "required": .array([.string("text")])
                    ])
                ),
                Tool(
                    name: "stop_speaking",
                    description: "Immediately stop all speech and clear the queue.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),
                Tool(
                    name: "get_playback_status",
                    description: "Get detailed speech playback status: which sentence is playing, what's pre-buffered, and which sentences are still editable.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),
            ])
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params -> CallTool.Result in
            guard let self else {
                return CallTool.Result(content: [.text(text: "Server deallocated")], isError: true)
            }
            switch params.name {
            case "speak":
                let text = Self.sanitize(params.arguments?["text"]?.stringValue ?? "")
                let (json, isErr) = await self.speakOrQueuePayload(text: text, connectionID: connectionID, replace: false)
                return CallTool.Result(content: [.text(text: json)], isError: isErr)

            case "check_status":
                let json = await self.checkStatusJSON(connectionID: connectionID)
                return CallTool.Result(content: [.text(text: json)])

            case "get_live_transcript":
                // Tool calls arrive only after the MCP handshake on an accepted connection, and the
                // socket is limited to the current user.
                let (confirmed, volatile, recording) = await MainActor.run {
                    let t = self.getTranscriptState?() ?? (confirmed: "", volatile: "", isRecording: false)
                    return (t.confirmed, t.volatile, t.isRecording)
                }
                let json = Self.jsonString(from: [
                    "confirmed": confirmed,
                    "volatile": volatile,
                    "is_recording": recording
                ])
                return CallTool.Result(content: [.text(text: json)])

            case "submit_draft_response":
                let rawText = params.arguments?["text"]?.stringValue ?? ""
                let snapshot = params.arguments?["transcript_snapshot"]?.stringValue ?? ""
                guard !rawText.isEmpty else {
                    let errJSON = Self.jsonString(from: ["error": "text is required"])
                    return CallTool.Result(content: [.text(text: errJSON)], isError: true)
                }
                guard !snapshot.isEmpty else {
                    let errJSON = Self.jsonString(from: ["error": "transcript_snapshot is required"])
                    return CallTool.Result(content: [.text(text: errJSON)], isError: true)
                }
                let cleaned = rawText.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .controlCharacters)
                let text = String(cleaned.prefix(10_000))
                let draftID = await MainActor.run {
                    self.draftManager?.submit(text: text, transcriptSnapshot: snapshot) ?? ""
                }
                if draftID.isEmpty {
                    let errJSON = Self.jsonString(from: ["error": "draft manager not available"])
                    return CallTool.Result(content: [.text(text: errJSON)], isError: true)
                }
                let okJSON = Self.jsonString(from: [
                    "draft_id": draftID,
                    "status": "pending"
                ])
                return CallTool.Result(content: [.text(text: okJSON)])

            case "get_draft_status":
                let draftID = params.arguments?["draft_id"]?.stringValue ?? ""
                guard !draftID.isEmpty else {
                    let errJSON = Self.jsonString(from: ["error": "draft_id is required"])
                    return CallTool.Result(content: [.text(text: errJSON)], isError: true)
                }
                let outcome = await MainActor.run {
                    self.draftManager?.outcomeFor(draftID: draftID)
                }
                let outcomeStr = outcome?.rawValue ?? "unknown"
                let json = Self.jsonString(from: [
                    "draft_id": draftID,
                    "outcome": outcomeStr
                ])
                return CallTool.Result(content: [.text(text: json)])

            case "queue_speech":
                let text = Self.sanitize(params.arguments?["text"]?.stringValue ?? "")
                let (json, isErr) = await self.speakOrQueuePayload(text: text, connectionID: connectionID, replace: false)
                return CallTool.Result(content: [.text(text: json)], isError: isErr)

            case "replace_speech":
                let text = Self.sanitize(params.arguments?["text"]?.stringValue ?? "")
                let (json, isErr) = await self.speakOrQueuePayload(text: text, connectionID: connectionID, replace: true)
                return CallTool.Result(content: [.text(text: json)], isError: isErr)

            case "stop_speaking":
                await MainActor.run { self.onStopSpeaking?() }
                let json = Self.jsonString(from: [
                    "stopped": true
                ])
                return CallTool.Result(content: [.text(text: json)])

            case "get_playback_status":
                let json = await self.playbackStatusJSON()
                return CallTool.Result(content: [.text(text: json)])

            default:
                return CallTool.Result(content: [.text(text: "Unknown tool: \(params.name)")], isError: true)
            }
        }
    }

    // MARK: - Speech Tool Helpers

    /// Flatten newlines, strip control characters, and cap length -- the shared
    /// cleanup for every text argument.
    private nonisolated static func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .controlCharacters)
        return String(cleaned.prefix(10_000))
    }

    /// Drive the speech pipeline for speak/queue_speech/replace_speech and
    /// return an honest (jsonPayload, isError) pair. Runs on the MainActor so
    /// it can read the live TTS state; returns only Sendable values.
    @MainActor
    private func speakOrQueuePayload(text: String, connectionID: Int32, replace: Bool) -> (String, Bool) {
        guard !text.isEmpty else {
            return (Self.jsonString(from: [
                "status": "empty", "spoken": false, "reason": "No text provided."
            ]), false)
        }

        // Held while the user is dictating. Not a failure -- the text is
        // intentionally dropped so the agent doesn't talk over the user.
        if speechSuppressed {
            return (Self.jsonString(from: [
                "status": "suppressed", "spoken": false,
                "reason": "User is recording; this call was dropped. Re-send after they finish."
            ]), false)
        }

        guard let tts = ttsService else {
            // Without the speech service, use the fire-and-forget closures: report acceptance, not
            // playback, and point to check_status.
            if replace {
                onReplaceSpeech?(text, connectionID)
            } else {
                let speaking = getTtsState?().speaking ?? false
                if speaking { onQueueSpeech?(text, connectionID) } else { onSpeak?(text, connectionID) }
            }
            return (Self.jsonString(from: [
                "status": "accepted", "spoken": false,
                "note": "Handed to the voice pipeline. Call check_status to confirm it is ready and playing."
            ]), false)
        }

        let outcome = replace
            ? tts.replacePending(with: text, connectionID: connectionID)
            : tts.queueSpeech(text, connectionID: connectionID)
        return Self.payload(for: outcome, phase: tts.modelPhase, text: text)
    }

    /// Map a SpeechOutcome to (jsonPayload, isError). Dropped or failed speech
    /// is always an error so an agent never reads success for silence.
    private nonisolated static func payload(for outcome: SpeechOutcome, phase: TTSModelPhase, text: String) -> (String, Bool) {
        let preview = String(text.prefix(80))
        switch outcome {
        case .started:
            return (jsonString(from: ["status": "preparing_speech", "spoken": false, "queued": true, "text": preview]), false)
        case .queued:
            return (jsonString(from: ["status": "queued", "spoken": false, "queued": true, "text": preview]), false)
        case .queuedPendingModel:
            var note = "Voice model is initializing; speech plays once it is ready. Poll check_status."
            if case .downloading(let fraction) = phase {
                note = "Voice model is downloading (\(Int(fraction * 100))%); speech plays once it finishes. Poll check_status."
            }
            return (jsonString(from: [
                "status": "pending_model", "spoken": false, "queued": true, "note": note
            ]), false)
        case .droppedQueueFull(let accepted, let dropped):
            if accepted == 0 {
                return (jsonString(from: [
                    "status": "dropped", "spoken": false, "queued": false, "dropped": dropped,
                    "reason": "Speech queue is full (50 sentences); nothing was queued. Retry after playback drains."
                ]), true)
            }
            return (jsonString(from: [
                "status": "partial", "spoken": false, "queued": true,
                "accepted": accepted, "dropped": dropped,
                "reason": "Queue filled: \(accepted) sentence(s) queued, \(dropped) dropped. Re-send only the dropped portion after playback drains."
            ]), true)
        case .empty:
            return (jsonString(from: ["status": "empty", "spoken": false, "reason": "No speakable text."]), false)
        case .notSpoken(let reason):
            return (jsonString(from: ["status": "unavailable", "spoken": false, "reason": reason]), true)
        }
    }

    /// get_playback_status payload, including dropped_count: sentences that failed to play since
    /// the last check. Reading it resets the count.
    @MainActor
    private func playbackStatusJSON() -> String {
        let status = getPlaybackStatus?() ?? (playing: "", preBuffered: "", pending: [])
        let dropped = ttsService?.consumeDroppedCount() ?? 0
        var payload: [String: Any] = [
            "currently_playing": status.playing,
            "pre_buffered": status.preBuffered,
            "pending_editable": status.pending,
            "pending_count": status.pending.count,
            "dropped_count": dropped
        ]
        if let reason = ttsService?.lastPlaybackError { payload["reason"] = reason }
        return Self.jsonString(from: payload)
    }

    /// Build the check_status payload from the real TTS state machine. Reports
    /// the calling connection's assigned voice (not the user's selectedVoice),
    /// peeked without minting an assignment.
    @MainActor
    private func checkStatusJSON(connectionID: Int32) -> String {
        let running = isRunning
        var payload: [String: Any] = [:]

        if let tts = ttsService {
            let phase = tts.modelPhase
            let speaking = tts.isSpeaking
            let status: String
            if !running {
                status = "unavailable"
            } else if let reason = tts.lastPlaybackError {
                status = "unavailable"
                payload["reason"] = reason
            } else {
                switch phase {
                case .failed(let reason):
                    status = "unavailable"
                    payload["reason"] = reason
                case .downloading(let fraction):
                    status = "downloading"
                    payload["download_progress"] = (fraction * 100).rounded() / 100
                case .initializing:
                    status = "initializing"
                case .ready:
                    status = speaking ? "speaking" : (tts.isPreparingSpeech ? "preparing_speech" : "ready")
                case .uninitialized:
                    if tts.initializationInFlight {
                        status = "initializing"
                    } else {
                        status = "uninitialized"
                        payload["note"] = "TTS will initialize on the first speak call."
                    }
                }
            }
            payload["status"] = status
            payload["tts_initialized"] = tts.isInitialized
            payload["is_speaking"] = speaking
            payload["voice"] = tts.peekVoice(for: connectionID)
            return Self.jsonString(from: payload)
        }

        // Only the summary closure is available: report "uninitialized" when nothing has loaded
        // instead of claiming initialization is in progress.
        let tts = getTtsState?() ?? (initialized: false, speaking: false, voice: "unknown")
        let status: String
        if !running {
            status = "unavailable"
        } else if tts.speaking {
            status = "speaking"
        } else if tts.initialized {
            status = "ready"
        } else {
            status = "uninitialized"
            payload["note"] = "TTS will initialize on the first speak call."
        }
        payload["status"] = status
        payload["tts_initialized"] = tts.initialized
        payload["is_speaking"] = tts.speaking
        payload["voice"] = tts.voice
        return Self.jsonString(from: payload)
    }

    /// Convert a dictionary to a JSON string. Safe against injection.
    private nonisolated static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }


}

extension Tool.Content {
    static func text(text: String) -> Tool.Content {
        return .text(text: text, annotations: nil, _meta: nil)
    }
}
