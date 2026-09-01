import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show DB stats"
    )
    func run() throws {
        let db = try openDatabase()
        let s = try Reporter(db: db).stats()
        print("DB:        \(db.path)")
        print("Size:      \(String(format: "%.2f MB", Double(s.dbBytes) / 1_048_576.0))")
        print("Samples:   \(s.sampleCount)")
        if let o = s.oldest, let n = s.newest {
            let f = ISO8601DateFormatter()
            print("Oldest:    \(f.string(from: Date(timeIntervalSince1970: TimeInterval(o))))")
            print("Newest:    \(f.string(from: Date(timeIntervalSince1970: TimeInterval(n))))")
            let span = Double(n - o) / 3600.0
            print("Span:      \(String(format: "%.1f hours", span))")
        }
        if let f = s.calibrationFactor {
            print("Energy: native process counter (\(f) J/nJ)")
        } else {
            print("Energy: unavailable — no native process energy samples yet")
        }
    }
}

struct PruneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Apply retention policy and incremental_vacuum"
    )

    @Option(name: .long, help: "Keep raw samples for this many days") var rawDays: Int = Database.rawRetentionDays
    @Option(name: .long, help: "Keep hourly aggregates for this many days") var hourlyDays: Int = Database.hourlyRetentionDays

    func run() throws {
        guard rawDays >= 0, hourlyDays >= 0,
              rawDays <= Int(Int64.max / 86400),
              hourlyDays <= Int(Int64.max / 86400) else {
            throw ValidationError("retention days must be valid non-negative values")
        }
        let db = try openDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        let rawCutoff = now - Int64(rawDays) * 86400
        let hourlyCutoff = now - Int64(hourlyDays) * 86400

        let s1 = try db.prepare("DELETE FROM samples WHERE timestamp < ?;")
        defer { s1.finalize() }
        try s1.bind(1, rawCutoff)
        try s1.execute()
        let s2 = try db.prepare("DELETE FROM hourly_aggregates WHERE hour_epoch < ?;")
        defer { s2.finalize() }
        try s2.bind(1, hourlyCutoff)
        try s2.execute()
        try db.exec("PRAGMA incremental_vacuum;")
        print("Pruned. Raw cutoff: \(rawDays)d, hourly cutoff: \(hourlyDays)d.")
    }
}
