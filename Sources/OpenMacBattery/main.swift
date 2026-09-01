import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct OpenMacBatteryCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openmacbattery",
        abstract: "macOS per-app battery & energy tracker",
        subcommands: [
            DaemonCommand.self,
            SampleCommand.self,
            TopCommand.self,
            AppCommand.self,
            TimelineCommand.self,
            ExportCommand.self,
            StatsCommand.self,
            PruneCommand.self,
            CalibrateCommand.self
        ]
    )
}

// MARK: - Helpers

enum DurationParser {
    /// "24h", "7d", "30m", "5m" → saniye
    static func parse(_ s: String) throws -> Int64 {
        guard let last = s.last else { throw ValidationError("empty duration") }
        let unit = last
        let numStr = String(s.dropLast())
        guard let num = Int64(numStr), num > 0 else {
            throw ValidationError("duration must be a positive integer: \(s)")
        }
        let multiplier: Int64
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default: throw ValidationError("unknown duration unit: \(unit)")
        }
        let (seconds, overflow) = num.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw ValidationError("duration is too large: \(s)") }
        return seconds
    }
}

func openDatabase() throws -> Database {
    return try Database(path: Database.defaultPath())
}

OpenMacBatteryCLI.main()
