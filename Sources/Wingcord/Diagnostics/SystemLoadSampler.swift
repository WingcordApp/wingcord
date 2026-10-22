import Darwin
import Foundation
import IOKit

// MARK: - What the machine is spending
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20): the overlay's Performance widget.
// Four public readings and nothing that needs a permission:
//
//   * processor — the whole machine from `host_processor_info`'s tick
//     counters, and one process (the game, Wingcord) from `proc_pidinfo`'s
//     task times. **Those are mach ticks, not nanoseconds**: measured on this
//     machine, a second of one busy thread reads 23,856,599, which is a second
//     only through the 125/3 timebase;
//   * graphics — `IOAccelerator`'s "Device Utilization %", which every GPU
//     driver on the Mac publishes in its PerformanceStatistics;
//   * memory — Activity Monitor's "Memory Used": app memory (internal pages
//     less purgeable) + wired + compressed;
//   * heat — `ProcessInfo.thermalState`.
//
// A game's own frame rate is not readable from outside it, so it is not
// here.

nonisolated struct SystemLoad: Equatable, Sendable {
    /// The whole machine's processor use, 0…1 across every core.
    var cpu: Double
    /// The game's own share of one core per core used — 1.5 is one and a half
    /// cores — or nil without a game.
    var gameCPU: Double?
    /// Wingcord's own, the same way.
    var appCPU: Double
    /// The GPU's busy fraction, 0…1, when the driver says.
    var gpu: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var thermal: ProcessInfo.ThermalState
}

/// Takes one reading a call; the processor figures are the change since the
/// previous call, so the first call primes them and reads nothing.
nonisolated final class SystemLoadSampler: @unchecked Sendable {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastTimes: [pid_t: UInt64] = [:]
    private var lastSample: UInt64?
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func sample(game: pid_t?) -> SystemLoad? {
        let now = mach_absolute_time()
        let ticks = Self.machineTicks()
        let own = getpid()
        var times: [pid_t: UInt64] = [:]
        times[own] = Self.taskTime(own)
        if let game, game > 0 { times[game] = Self.taskTime(game) }

        defer {
            lastTicks = ticks
            lastTimes = times
            lastSample = now
        }
        guard let lastSample, let ticks, let lastTicks, now > lastSample else { return nil }
        let elapsed = Double(now - lastSample)

        func share(_ pid: pid_t) -> Double? {
            guard let current = times[pid], let previous = lastTimes[pid], current >= previous else { return nil }
            // Both are mach ticks, so the timebase cancels.
            return Double(current - previous) / elapsed
        }
        let busy = Double(ticks.busy &- lastTicks.busy)
        let total = Double(ticks.total &- lastTicks.total)
        return SystemLoad(
            cpu: total > 0 ? min(max(busy / total, 0), 1) : 0,
            gameCPU: game.flatMap(share),
            appCPU: share(own) ?? 0,
            gpu: Self.gpuUtilisation(),
            memoryUsed: Self.memoryUsed(),
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            thermal: ProcessInfo.processInfo.thermalState
        )
    }

    // MARK: Readings

    /// Every core's busy and total ticks, summed.
    private static func machineTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0 ..< Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    /// A process's user + system time, in mach ticks.
    private static func taskTime(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_total_user + info.pti_total_system
    }

    private static func gpuUtilisation() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            {
                best = max(best ?? 0, percent / 100)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(pageSize)
    }
}
