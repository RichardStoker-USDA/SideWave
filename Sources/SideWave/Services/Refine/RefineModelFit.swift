// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Darwin
import Foundation

/// Whether this Mac has room for each Refine model, judged from its memory and from what is
/// usually free while the person works, not only from what is free this moment.
enum RefineModelFit {
    enum Verdict: Equatable, Sendable {
        /// Fits with room to spare.
        case comfortable
        /// Fits, with little room left; other apps can slow down while it refines.
        case tight
        /// Needs more memory than this Mac has free.
        case tooLarge
        /// Runs in macOS, outside SideWave's memory.
        case system
    }

    struct Memory: Equatable, Sendable {
        let total: UInt64
        /// Free now, counting memory SideWave's own refine model holds, since switching models
        /// releases it.
        let availableNow: UInt64
        /// Free at the tighter moments of recent days; nil until there are enough samples.
        let typicallyAvailable: UInt64?

        /// The figure verdicts use: the lower of now and usual.
        var planningAvailable: UInt64 {
            typicallyAvailable.map { min($0, availableNow) } ?? availableNow
        }
    }

    static let gigabyte: UInt64 = 1_000_000_000
    /// Room left beyond a model's own memory before it counts as comfortable.
    static let headroom: UInt64 = 2 * gigabyte
    /// Memory macOS needs for itself. A Mac whose total memory leaves less than this beside the
    /// model can't run it well however idle it is.
    static let systemReserve: UInt64 = 4 * gigabyte

    static func verdict(for backend: DictationFormatterService.Backend, memory: Memory) -> Verdict {
        guard let need = backend.workingBytes else { return .system }
        if memory.total < need + systemReserve { return .tooLarge }
        let free = memory.planningAvailable
        if free >= need + headroom { return .comfortable }
        if free >= need { return .tight }
        return .tooLarge
    }

    /// The model to suggest. Gemma runs on this Mac's GPU and refines more thoroughly than
    /// Apple Intelligence when it fits with room to spare. E4B is suggested on Pro, Max, and Ultra
    /// chips with 32 GB or more, whose memory bandwidth keeps it fast; otherwise E2B. 12B is slower
    /// to refine live and is never the suggestion. Without room for Gemma, Apple Intelligence.
    static func suggested(
        memory: Memory,
        chip: HardwareDetector.ChipFamily,
        appleIntelligenceAvailable: Bool
    ) -> DictationFormatterService.Backend {
        if chip.isProMaxUltra, memory.total >= 32 * 1_073_741_824,
           verdict(for: .gemma4E4B, memory: memory) == .comfortable {
            return .gemma4E4B
        }
        if verdict(for: .gemma4E2B, memory: memory) == .comfortable { return .gemma4E2B }
        if appleIntelligenceAvailable { return .appleIntelligence }
        return .gemma4E2B
    }

    /// One calm sentence for a choice that doesn't fit well, nil when it does.
    static func note(
        for backend: DictationFormatterService.Backend,
        memory: Memory,
        suggestion: DictationFormatterService.Backend
    ) -> String? {
        guard let need = backend.workingBytes else { return nil }
        let free = memory.planningAvailable
        let alternative = suggestion == backend ? nil : suggestion.displayName
        let tail = alternative.map { " \($0) fits." } ?? ""
        switch verdict(for: backend, memory: memory) {
        case .comfortable, .system:
            return nil
        case .tight:
            return "\(backend.displayName) uses about \(memoryText(need)) while refining, and this Mac usually has \(memoryText(free)) free, so other apps may slow down.\(tail)"
        case .tooLarge:
            if memory.total < need + systemReserve {
                return "\(backend.displayName) needs about \(memoryText(need)) while refining, more than this Mac's \(memoryText(memory.total)) can spare.\(tail)"
            }
            return "\(backend.displayName) needs about \(memoryText(need)) while refining, and this Mac usually has \(memoryText(free)) free.\(tail)"
        }
    }

    /// This Mac's memory now, with the usual free memory from the sample history.
    static func currentMemory(ownModelBytes: UInt64, history: SystemMemory.History = .init()) -> Memory {
        let total = SystemMemory.total
        let now = min(total, SystemMemory.available() + ownModelBytes)
        return Memory(total: total, availableNow: now, typicallyAvailable: history.typical())
    }

    /// Adds a free-memory sample, counting SideWave's own loaded model as free.
    static func recordSample(ownModelBytes: UInt64, history: SystemMemory.History = .init()) {
        history.record(min(SystemMemory.total, SystemMemory.available() + ownModelBytes))
    }

    /// A download size in decimal gigabytes, as Finder shows it: "3.6 GB", or "12 GB" from 10 up.
    static func gigabytes(_ bytes: UInt64) -> String {
        format(Double(bytes) / Double(gigabyte))
    }

    /// A memory size in binary gigabytes, as macOS and Activity Monitor show memory: "128 GB".
    static func memoryText(_ bytes: UInt64) -> String {
        format(Double(bytes) / 1_073_741_824)
    }

    private static func format(_ value: Double) -> String {
        if value >= 10 { return "\(Int(value.rounded())) GB" }
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths)) GB" : String(format: "%.1f GB", tenths)
    }
}

/// Free memory as macOS reports it, and a short history of it.
enum SystemMemory {
    static var total: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Memory available without pressure: the kernel's free percentage (what `memory_pressure`
    /// prints), which counts reclaimable caches. Falls back to free, inactive, speculative, and
    /// purgeable pages.
    static func available() -> UInt64 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, level > 0, level <= 100 {
            return total / 100 * UInt64(level)
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count) + UInt64(stats.purgeable_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    /// Samples of free memory over the last week, kept in user defaults. One sample per ten minutes
    /// at most, taken when a dictation starts and when Refine settings open.
    struct History {
        static let key = "refineMemorySamples"
        static let window: TimeInterval = 7 * 24 * 3600
        static let spacing: TimeInterval = 600
        static let minimumSamples = 6

        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        var samples: [(time: TimeInterval, bytes: UInt64)] {
            let raw = defaults.array(forKey: Self.key) as? [[Double]] ?? []
            return raw.compactMap { $0.count == 2 && $0[1] >= 0 ? ($0[0], UInt64($0[1])) : nil }
        }

        func record(_ bytes: UInt64, at time: TimeInterval = Date().timeIntervalSince1970) {
            var kept = samples.filter { time - $0.time < Self.window && $0.time <= time }
            if let last = kept.last, time - last.time < Self.spacing { return }
            kept.append((time, bytes))
            defaults.set(kept.map { [$0.time, Double($0.bytes)] }, forKey: Self.key)
        }

        /// Free memory at the tighter moments: the 10th percentile, once there are enough samples.
        func typical(now time: TimeInterval = Date().timeIntervalSince1970) -> UInt64? {
            let recent = samples.filter { time - $0.time < Self.window }.map(\.bytes).sorted()
            guard recent.count >= Self.minimumSamples else { return nil }
            return recent[Int((Double(recent.count - 1) * 0.1).rounded())]
        }
    }
}
