import Foundation
import IOKit
import CIOReport

/// Active-state weighted MHz, using Apple's IOReport counters and firmware DVFS tables.
/// The IOReport ABI and residency interpretation follow Stats (MIT; see THIRD_PARTY).
final class MacFrequency {
    private var channels: CFMutableDictionary?
    private var subscription: IOReportSubscriptionRef?
    private var previous: CFDictionary?
    private var efficiency: [Double] = []
    private var performance: [Double] = []
    var maximumMHz: Double? { performance.max() }

    init() {
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var name = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(service, &name)
                guard String(cString: name) == "pmgr" else { continue }
                for (key, isPerformance) in [("voltage-states1-sram", false), ("voltage-states5-sram", true)] {
                    guard let data = IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? Data else { continue }
                    let table: [Double] = stride(from: 0, to: data.count - 7, by: 8).map { offset in
                        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
                        return Double(raw) / 1_000_000
                    }
                    if isPerformance { performance = table } else { efficiency = table }
                }
            }
        }
        // Only accept matching channel/table counts at sampling time; never guess new SoC layouts.
        guard !efficiency.isEmpty, !performance.isEmpty,
              let copied = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(nil, 0, copied) else { return }
        channels = mutable
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, mutable, &subscribed, 0, nil)
        subscribed?.release()
    }

    deinit {
        if let subscription { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release() }
    }

    func sample(validInterval: Bool) -> (performance: Double?, efficiency: Double?) {
        guard let subscription, let channels,
              let current = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return (nil, nil) }
        defer { previous = current }
        guard validInterval, let previous,
              let delta = IOReportCreateSamplesDelta(previous, current, nil)?.takeRetainedValue(),
              let list = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return (nil, nil) }
        var p: [Double] = [], e: [Double] = []
        for item in list {
            let channel = item as CFDictionary
            guard let name = IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String? else { continue }
            let isPerformance = name.hasPrefix("PCPU")
            guard isPerformance || name.hasPrefix("ECPU") else { continue }
            let table = isPerformance ? performance : efficiency
            var active: [Double] = []
            for index in 0..<IOReportStateGetCount(channel) {
                let state = IOReportStateGetNameForIndex(channel, index)?.takeUnretainedValue() as String? ?? ""
                if ["IDLE", "DOWN", "OFF"].contains(state) { continue }
                active.append(Double(IOReportStateGetResidency(channel, index)))
            }
            guard active.count == table.count, active.allSatisfy({ $0 >= 0 }) else { continue }
            let duration = active.reduce(0, +)
            guard duration > 0 else { continue }
            let mhz = zip(active, table).reduce(0) { $0 + $1.0 * $1.1 } / duration
            if isPerformance { p.append(mhz) } else { e.append(mhz) }
        }
        return (p.isEmpty ? nil : p.reduce(0, +) / Double(p.count), e.isEmpty ? nil : e.reduce(0, +) / Double(e.count))
    }
}
