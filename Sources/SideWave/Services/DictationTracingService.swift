// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os
#if DEBUG
import Metal
#endif

/// Centralised real-time tracing engine for SideWave dictation, hardware, and rendering pipelines.
/// The event tracking and diagnostics buffer are active ONLY in Debug builds to maintain absolute privacy in production.
public final class DictationTracingService: @unchecked Sendable {
    public static let shared = DictationTracingService()
    
    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.sidewave.dev", category: "engine-trace")
    
    /// Trace event structures
    public struct TraceEvent: Identifiable, Codable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let category: TraceCategory
        public let severity: TraceSeverity
        public let message: String
        public let threadName: String
        public let durationMs: Double?
        
        public var formattedTime: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }
        
        public init(category: TraceCategory, severity: TraceSeverity, message: String, threadName: String, durationMs: Double?) {
            self.id = UUID()
            self.timestamp = Date()
            self.category = category
            self.severity = severity
            self.message = message
            self.threadName = threadName
            self.durationMs = durationMs
        }
    }
    
    public enum TraceCategory: String, Codable, CaseIterable, Sendable {
        case modelLoad = "Model Loading"
        case audioQueue = "Audio Queue"
        case engineState = "Dictation Engine"
        case computeDevice = "Compute Hardware"
        case textRendering = "Text Rendering"
        case pasteCascade = "Paste Cascade"
        case refinement = "Refine Pipeline"
    }
    
    public enum TraceSeverity: String, Codable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }
    
    #if DEBUG
    private var events: [TraceEvent] = []
    private let maxEvents = 300
    #endif
    
    private init() {
        #if DEBUG
        let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "Unknown"
        log(.computeDevice, .info, "Tracing backend initialized. CPU Cores: \(ProcessInfo.processInfo.activeProcessorCount), System Memory: \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)), Metal GPU: \(gpuName)")
        #endif
    }
    
    /// Core logging method - inlines to a safe no-op on RELEASE builds
    public func log(_ category: TraceCategory, _ severity: TraceSeverity, _ message: @autoclosure () -> String, durationMs: Double? = nil) {
        #if DEBUG
        let messageEvaluated = message()
        let threadName = Thread.isMainThread ? "MainActor" : (Thread.current.name ?? "WorkerThread")
        let event = TraceEvent(
            category: category,
            severity: severity,
            message: messageEvaluated,
            threadName: threadName,
            durationMs: durationMs
        )
        
        lock.lock()
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst()
        }
        lock.unlock()
        
        // Output to OS Console as well
        let durationStr = durationMs != nil ? " (\(String(format: "%.2f", durationMs!))ms)" : ""
        let logMsg = "[\(category.rawValue)] [\(severity.rawValue)] \(messageEvaluated)\(durationStr) [Thread: \(threadName)]"
        
        switch severity {
        case .debug:
            osLogger.debug("\(logMsg, privacy: .public)")
        case .info:
            osLogger.info("\(logMsg, privacy: .public)")
        case .warning:
            osLogger.warning("\(logMsg, privacy: .public)")
        case .error:
            osLogger.error("\(logMsg, privacy: .public)")
        }
        
        NotificationCenter.default.post(name: .didReceiveDictationTrace, object: event)
        #endif
    }
    
    /// Retrieve all tracked events (Empty on RELEASE)
    public func getEvents() -> [TraceEvent] {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        return events
        #else
        return []
        #endif
    }
    
    /// Clear ring buffer (No-op on RELEASE)
    public func clear() {
        #if DEBUG
        lock.lock()
        events.removeAll()
        lock.unlock()
        log(.engineState, .info, "Trace buffer cleared by developer request")
        #endif
    }
    
    /// Export logs to a local JSON dump and return its URL (Nil on RELEASE)
    public func exportTraceDump() -> URL? {
        #if DEBUG
        lock.lock()
        let eventsToExport = events
        lock.unlock()
        
        struct DiagnosticDump: Encodable {
            let exportTime = Date()
            let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let cpuCores = ProcessInfo.processInfo.activeProcessorCount
            let memory = ProcessInfo.processInfo.physicalMemory
            let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Unknown"
            let events: [TraceEvent]
        }
        
        let dump = DiagnosticDump(events: eventsToExport)
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dump)
            
            let fm = FileManager.default
            let dir = AppPaths.applicationSupportDirectory()
                .appendingPathComponent("Diagnostics", isDirectory: true)
            
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                let fileURL = dir.appendingPathComponent("sidewave_trace_\(Int(Date().timeIntervalSince1970)).json")
                fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                try data.write(to: fileURL)
                log(.engineState, .info, "Successfully exported diagnostics trace dump to: \(fileURL.lastPathComponent)")
                return fileURL
            } catch {
                log(.engineState, .error, "Failed to write diagnostic trace dump: \(error.localizedDescription)")
            }
        } catch {
            log(.engineState, .error, "Failed to write diagnostic trace dump: \(error.localizedDescription)")
        }
        #endif
        return nil
    }
}

extension Notification.Name {
    public static let didReceiveDictationTrace = Notification.Name("com.sidewave.app.didReceiveDictationTrace")
}
