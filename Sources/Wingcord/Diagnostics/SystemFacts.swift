import AppKit
import Darwin
import Foundation
import WingcordCore

/// What a bug report says about the Mac and the app (docs/BUG-REPORTING.md
/// D21): the things that make "it works on mine" explicable.
///
/// **No name, no serial number, no account.** The model identifier
/// (`Mac17,2`) and the chip say which hardware without saying whose; the
/// settings are listed by name only, never by value.
nonisolated struct SystemFacts: Codable, Sendable, Equatable {
    struct Display: Codable, Sendable, Equatable {
        /// The size in points, as the window sees it.
        var points: String
        var scale: Double
        var refreshRate: Int
    }

    var appVersion: String
    var appBuild: String
    var bundleIdentifier: String
    var macOS: String
    var model: String
    var chip: String
    var memory: String
    var processorCount: Int
    var displays: [Display]
    var runningFor: String
    var footprint: String
    var thermalState: String
    var lowPowerMode: Bool
    var appearance: String
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var language: String
    var detailedLogging: Bool
    /// The app's settings the reader has changed — names only.
    var changedSettings: [String]

    /// Read now. Main actor: the screens and the appearance are AppKit's.
    @MainActor
    static func gather() -> SystemFacts {
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        let workspace = NSWorkspace.shared
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return SystemFacts(
            appVersion: bundle.displayVersion,
            appBuild: bundle.buildVersion,
            bundleIdentifier: bundle.bundleIdentifier ?? "none",
            macOS: process.operatingSystemVersionString,
            model: machineModel(),
            chip: chip(),
            memory: LogMessage.describe(bytes: Int64(process.physicalMemory)),
            processorCount: process.activeProcessorCount,
            displays: NSScreen.screens.map { screen in
                Display(
                    points: "\(Int(screen.frame.width))×\(Int(screen.frame.height))",
                    scale: screen.backingScaleFactor,
                    refreshRate: screen.maximumFramesPerSecond
                )
            },
            runningFor: LogMessage.describe(.seconds(Int(process.systemUptime - launchUptime))),
            footprint: LogMessage.describe(bytes: Int64(PerformanceMonitor.physicalFootprint())),
            thermalState: describe(process.thermalState),
            lowPowerMode: process.isLowPowerModeEnabled,
            appearance: isDark ? "dark" : "light",
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            language: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "?",
            detailedLogging: Log.isDetailed,
            changedSettings: changedSettings()
        )
    }

    /// The facts as a person reads them, one per line.
    var summary: String {
        var lines = [
            "Wingcord \(appVersion) (\(appBuild)), \(bundleIdentifier)",
            "macOS \(macOS)",
            "\(model), \(chip), \(memory), \(processorCount) cores",
        ]
        for (index, display) in displays.enumerated() {
            lines.append("Display \(index + 1): \(display.points) pt @\(display.scale)x, \(display.refreshRate) Hz")
        }
        lines.append("Running for \(runningFor), using \(footprint)")
        lines.append("Thermal \(thermalState), Low Power Mode \(lowPowerMode ? "on" : "off")")
        lines.append("Appearance \(appearance), language \(language)")
        var access: [String] = []
        if reduceMotion { access.append("Reduce Motion") }
        if reduceTransparency { access.append("Reduce Transparency") }
        if increaseContrast { access.append("Increase Contrast") }
        lines.append("Accessibility: " + (access.isEmpty ? "defaults" : access.joined(separator: ", ")))
        lines.append("Detailed logging \(detailedLogging ? "on" : "off")")
        lines.append("Changed settings: " + (changedSettings.isEmpty ? "none" : changedSettings.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    /// The system's uptime when this process started — what "running for" is
    /// measured from.
    private static let launchUptime = ProcessInfo.processInfo.systemUptime

    /// `Mac17,2`: the model identifier, which names the hardware and nobody.
    static func machineModel() -> String {
        sysctlString("hw.model") ?? "unknown Mac"
    }

    /// `Apple M5`.
    static func chip() -> String {
        sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// The names of the app's settings that have been written — which, for a
    /// store that writes only on change (`AppSettings`), are the ones moved
    /// from their defaults.
    ///
    /// **Names only, and not every name**: the system's own keys (window
    /// frames, panels) say nothing about the app, and a key with an id in it
    /// is one per channel or person — counted, not listed, because the list
    /// would be a map of somebody's servers.
    static func changedSettings(in defaults: UserDefaults = .standard) -> [String] {
        guard let identifier = Bundle.main.bundleIdentifier,
              let domain = defaults.persistentDomain(forName: identifier)
        else { return [] }
        return changedSettings(keys: domain.keys)
    }

    static func changedSettings(keys: some Sequence<String>) -> [String] {
        var names: [String] = []
        var perItem = 0
        for key in keys {
            if isSystemKey(key) { continue }
            if key.contains(where: \.isNumber), key.split(whereSeparator: { !$0.isNumber }).contains(where: { $0.count >= 15 }) {
                perItem += 1
                continue
            }
            names.append(key)
        }
        names.sort()
        if perItem > 0 { names.append("\(perItem) per-channel or per-person keys") }
        return names
    }

    private static func isSystemKey(_ key: String) -> Bool {
        let prefixes = ["NS", "Apple", "com.apple.", "WebKit", "AK", "MSApp", "SU", "_"]
        return prefixes.contains { key.hasPrefix($0) }
    }
}
