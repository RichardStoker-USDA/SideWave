// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Detects the Mac's chip, memory, and Apple Intelligence availability on first launch and picks
/// defaults that suit the hardware.
///
/// Tiers:
/// - **low**: 8 GB, no Apple Intelligence, or Intel. Refine skipped.
/// - **mid**: 16 GB with Apple Intelligence. Standard settings.
/// - **high**: 24 GB or more, or Pro, Max, or Ultra with 16 GB. Faster refine cadence.
///
/// Tier defaults go in the registration domain, re-registered each launch, so anything the user set
/// wins. Detection itself is cached after the first launch.
enum HardwareDetector {
    enum Tier: String, Codable, Sendable {
        case low
        case mid
        case high
    }

    private static let detectedAtKey = "hardwareTierDetectedAt"
    static let tierKey = "hardwareTier"

    @discardableResult
    static func detectIfNeeded(afmAvailable: Bool, defaults: UserDefaults = .standard) -> Tier {
        let tier: Tier
        if let stored = defaults.string(forKey: tierKey),
           let cached = Tier(rawValue: stored),
           defaults.object(forKey: detectedAtKey) != nil
        {
            // Detection is cached after first launch; the chip and RAM
            // don't change under a running install.
            tier = cached
        } else {
            tier = currentTier(afmAvailable: afmAvailable)
            defaults.set(tier.rawValue, forKey: tierKey)
            defaults.set(Date().timeIntervalSince1970, forKey: detectedAtKey)
        }
        // Register the tier defaults every launch; the registration domain isn't saved. This runs
        // from TranscriptionService.init right after its base defaults are registered, so for those
        // keys the tier values win, while a value the user set still beats both. It must be
        // register(), not set(): set() would look like a user choice.
        defaults.register(defaults: tierAdjustedRegistrationOverrides(for: tier))

        // Existing preferences are user choices; registration only supplies absent values.
        return tier
    }

    static func currentTier(afmAvailable: Bool) -> Tier {
        let ramGB = physicalMemoryGB()
        let family = chipFamily()
        // Low tier: Intel, or a low-memory Mac without Apple Intelligence. Intel Macs can't run
        // Apple Intelligence or fast Gemma, so they skip Refine regardless of memory.
        if case .intel = family { return .low }
        if !afmAvailable && ramGB < 16 { return .low }
        if ramGB >= 24 { return .high }
        if ramGB >= 16, family.isProMaxUltra { return .high }
        if ramGB >= 16 { return .mid }
        return .low
    }

    /// Registration overrides for a tier. Registered rather than set, so the user's choices win and
    /// missing keys use the tier value instead of the base default.
    static func tierAdjustedRegistrationOverrides(for tier: Tier) -> [String: Any] {
        switch tier {
        case .low:
            // Intel / 8 GB / no-AI Macs can't lean on the refine pipeline, so
            // default it off. The user can still turn Refine on (its control
            // lives on the Dictation tab).
            return ["skipRefine": true]
        case .mid, .high:
            // Macs with 16 GB or more handle the faster 3 s pause cadence, so continuous speech
            // gets refined well before the 14.8 s limit. The 8 s fixed-interval timer covers speech
            // that never pauses.
            return [
                "refineCadence": "faster",
                "refineFixedIntervalEnabled": true,
            ]
        }
    }

    static func physicalMemoryGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    enum ChipFamily {
        case intel
        case appleSiliconBase
        case appleSiliconPro
        case appleSiliconMax
        case appleSiliconUltra
        case unknown

        var isProMaxUltra: Bool {
            switch self {
            case .appleSiliconPro, .appleSiliconMax, .appleSiliconUltra: return true
            default: return false
            }
        }
    }

    static func chipFamily() -> ChipFamily {
        let brand = chipBrand.lowercased()
        if brand.contains("intel") { return .intel }
        if brand.contains("ultra") { return .appleSiliconUltra }
        if brand.contains("max")   { return .appleSiliconMax }
        if brand.contains("pro")   { return .appleSiliconPro }
        if brand.contains("apple") { return .appleSiliconBase }
        return .unknown
    }

    static var chipBrand: String { sysctlString("machdep.cpu.brand_string") ?? "" }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
