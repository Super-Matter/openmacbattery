#if canImport(XCTest)
import XCTest
@testable import OpenMacBatteryCore

final class SmokeTests: XCTestCase {
    func testListAllPids() {
        let pids = ProcessInfoReader.listAllPids()
        XCTAssertGreaterThan(pids.count, 10, "should find some processes")
        XCTAssertTrue(pids.contains(getpid()), "self pid should be in list")
    }

    func testSelfRusage() {
        guard let r = ProcessInfoReader.rusage(pid: getpid()) else {
            XCTFail("self rusage must succeed"); return
        }
        XCTAssertGreaterThan(r.userTimeNs + r.systemTimeNs, 0)
        XCTAssertTrue(r.rusageVersion == 4 || r.rusageVersion == 6)
        if r.rusageVersion == 6 { XCTAssertNotNil(r.energyNanojoules) }
    }

    func testDatabaseRoundtrip() throws {
        let tmp = NSTemporaryDirectory() + "battracker_test_\(getpid()).db"
        try? FileManager.default.removeItem(atPath: tmp)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let db = try Database(path: tmp)
        try db.setMeta(key: "energy_unit_factor", value: "1.42e-9")
        XCTAssertEqual(db.meta(key: "energy_unit_factor"), "1.42e-9")

        let sampler = Sampler(db: db)
        try sampler.sampleOnce()  // baseline
        // küçük bir CPU yükü
        var x = 0; for i in 0..<200_000 { x &+= i }
        _ = x
        Thread.sleep(forTimeInterval: 0.5)
        try sampler.sampleOnce()  // delta

        let r = try Reporter(db: db).stats()
        XCTAssertGreaterThan(r.sampleCount, 0)
    }

    func testMigrationCanRetryAfterSchemaVersionReset() throws {
        let tmp = NSTemporaryDirectory() + "openmacbattery_migration_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            let db = try Database(path: tmp)
            try db.setMeta(key: "schema_version", value: "1")
        }
        let db = try Database(path: tmp)
        XCTAssertEqual(db.meta(key: "schema_version"), "2")
        XCTAssertEqual(db.meta(key: "energy_metric"), "ri_energy_nj")
    }

    func testPowerSourceReadsWithoutCrashing() {
        _ = PowerSourceReader.current()
        _ = PowerSourceReader.batterySnapshot()
    }

    func testBatterySummaryUsesSeconds() throws {
        let tmp = NSTemporaryDirectory() + "openmacbattery_duration_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let db = try Database(path: tmp)
        try db.exec("""
        INSERT INTO samples(timestamp, pid, proc_start_sec, cpu_user_ns, cpu_system_ns,
                            energy_nj, is_on_battery, battery_percent, rusage_version)
        VALUES (1000, 1, 1, 0, 0, 100, 1, 80, 6),
               (1060, 1, 1, 0, 0, 100, 1, 79, 6);
        """)

        let summary = try Reporter(db: db).batterySummary(range: DateRange(from: 1000, to: 1060))
        XCTAssertEqual(summary.onBatterySeconds, 120)
        XCTAssertEqual(summary.onAcSeconds, 0)
    }

    func testDetailTimelineRespectsBatteryFilter() throws {
        let tmp = NSTemporaryDirectory() + "openmacbattery_filter_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let db = try Database(path: tmp)
        try db.exec("""
        INSERT INTO samples(timestamp, pid, proc_start_sec, cpu_user_ns, cpu_system_ns,
                            energy_nj, is_on_battery, battery_percent, rusage_version)
        VALUES (1000, 1, 1, 0, 0, 100, 1, 80, 6),
               (1060, 1, 1, 0, 0, 200, 1, 79, 6),
               (1120, 1, 1, 0, 0, 400, 0, 79, 6);
        """)
        let reporter = Reporter(db: db)
        let range = DateRange(from: 1000, to: 1120)
        let battery = try reporter.appTimelineMulti(groupKeys: ["unknown"], range: range, onlyBattery: true)
        let all = try reporter.appTimelineMulti(groupKeys: ["unknown"], range: range)
        XCTAssertEqual(battery.reduce(Int64(0)) { $0 + $1.energyRaw }, 300)
        XCTAssertEqual(all.reduce(Int64(0)) { $0 + $1.energyRaw }, 700)
    }

    func testAggregatorDeduplicatesProcessObservations() throws {
        let tmp = NSTemporaryDirectory() + "openmacbattery_aggregate_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let db = try Database(path: tmp)
        try db.exec("""
        INSERT INTO samples(timestamp, pid, proc_start_sec, cpu_user_ns, cpu_system_ns,
                            energy_nj, is_on_battery, battery_percent, rusage_version)
        VALUES (1000, 1, 1, 0, 0, 100, 1, 80, 6),
               (1000, 2, 2, 0, 0, 100, 1, 80, 6),
               (1060, 1, 1, 0, 0, 100, 1, 79, 6);
        """)

        try Aggregator(db: db).rollUp(sinceEpochSec: 900)
        let stmt = try db.prepare("SELECT sample_count, on_battery_seconds FROM hourly_aggregates WHERE hour_epoch = 0 AND bundle_id = 'unknown';")
        defer { stmt.finalize() }
        XCTAssertTrue(stmt.step())
        XCTAssertEqual(stmt.int64(0), 3)
        XCTAssertEqual(stmt.int64(1), 120)
    }

    func testDisplayPowerEstimate() {
        XCTAssertEqual(DisplayPowerEstimate.estimatedWatts(brightness: 0.5, displayCount: 1), 2.3, accuracy: 0.001)
        XCTAssertEqual(DisplayPowerEstimate.estimatedWatts(brightness: 1, displayCount: 2), 8.0, accuracy: 0.001)
    }

    func testEnergyFormatter() {
        XCTAssertTrue(EnergyFormatter.format(rawEnergy: 1000, factor: nil).contains("score"))
        XCTAssertTrue(EnergyFormatter.format(rawEnergy: 1_000_000_000, factor: 1.0).contains("kJ") ||
                      EnergyFormatter.format(rawEnergy: 1_000_000_000, factor: 1.0).contains("J"))
    }

    func testCalibratorParsesAppleSiliconPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>elapsed_ns</key><integer>2000000000</integer>
          <key>processor</key><dict>
            <key>clusters</key><array><dict>
              <key>combined_power</key><real>1500</real>
            </dict></array>
          </dict>
        </dict></plist>
        """
        let samples = try Calibrator.parsePlistStream(data: Data(xml.utf8) + Data([0]))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(Calibrator.packageEnergy(in: samples[0]) ?? 0, 3.0, accuracy: 0.001)
    }
}
#endif
