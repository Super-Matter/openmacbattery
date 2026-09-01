import Foundation
import Combine
import SwiftUI
import OpenMacBatteryCore

enum TimeRange: String, CaseIterable, Identifiable {
    case h1 = "1h"
    case h6 = "6h"
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"

    var id: String { rawValue }
    var displayKey: String {
        switch self {
        case .h1: return "Last hour"
        case .h6: return "Last 6 hours"
        case .h24: return "Today"
        case .d7: return "This week"
        case .d30: return "This month"
        }
    }
    var previousPeriodKey: String {
        switch self {
        case .h1: return "the previous hour"
        case .h6: return "the previous 6 hours"
        case .h24: return "the previous 24 hours"
        case .d7: return "the previous week"
        case .d30: return "the previous month"
        }
    }
    /// SwiftUI Text içinde otomatik localize edilir.
    var displayName: LocalizedStringKey {
        return LocalizedStringKey(displayKey)
    }
    var seconds: Int64 {
        switch self {
        case .h1: return 3600
        case .h6: return 6 * 3600
        case .h24: return 86400
        case .d7: return 7 * 86400
        case .d30: return 30 * 86400
        }
    }
    var bucketSeconds: Int {
        switch self {
        case .h1: return 60
        case .h6: return 5 * 60
        case .h24: return 10 * 60
        case .d7: return 60 * 60
        case .d30: return 4 * 60 * 60
        }
    }
}

struct TimelineSample: Identifiable, Equatable {
    let date: Date
    let energyRaw: Int64
    let cpuNs: Int64
    var id: Date { date }
}

struct BatterySample: Identifiable, Equatable {
    let date: Date
    let percent: Double
    let onBattery: Bool
    var id: Date { date }
}

struct DBStats {
    var sampleCount: Int64 = 0
    var sizeBytes: Int64 = 0
    var oldest: Date? = nil
    var newest: Date? = nil
    var calibrationFactor: Double? = nil
}

struct SleepInterval: Identifiable, Equatable {
    let start: Date
    let end: Date
    var id: Date { start }
}

struct HeroSummary {
    var firstPercent: Int?
    var lastPercent: Int?
    var onBatterySeconds: Int64
    var onAcSeconds: Int64
    var sleepSeconds: Int64
    var topThree: [GroupedApp]
    var totalUserEnergy: Int64

    var deltaPercent: Int? {
        guard let f = firstPercent, let l = lastPercent else { return nil }
        return l - f
    }
}

struct AppNarrative {
    let activeMinutes: Int        // ~ enerji tüketen sample sayısı * bucket dakika
    let peakHourLocal: Int?       // 0..23
    let peakDay: Date?
}

/// Önceki periyodun aynı uzunluğa göre karşılaştırması.
struct PeriodCompare {
    let currentTotalEnergy: Int64
    let previousTotalEnergy: Int64
    let hasPrevious: Bool
    /// Yüzde değişim: pozitif = arttı, negatif = azaldı. nil = baseline çok küçük.
    var deltaPercent: Double? {
        guard hasPrevious, previousTotalEnergy > 1000 else { return nil }
        let cur = Double(currentTotalEnergy)
        let prev = Double(previousTotalEnergy)
        return (cur - prev) / prev * 100.0
    }
}

/// Per-app anomali: bu periyodda enerji önceki periyodun X katından fazla mı.
struct AppAnomaly {
    let ratio: Double      // current / previous
    let label: String      // "3× usual"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var range: TimeRange = .h24 { didSet { refreshNow() } }
    @Published var onBattery: Bool = false { didSet { refreshNow() } }
    @Published var showSystem: Bool = false { didSet { refreshNow() } }
    @Published var apps: [GroupedApp] = []
    @Published var totalUserEnergy: Int64 = 0
    @Published var selectedAppId: String? = nil { didSet { reloadDetail() } }
    @Published var detailTimeline: [TimelineSample] = []
    @Published var batteryTimeline: [BatterySample] = []
    @Published var sleepPeriods: [SleepInterval] = []
    @Published var sparklines: [String: [Double]] = [:]
    @Published var hero = HeroSummary(firstPercent: nil, lastPercent: nil, onBatterySeconds: 0, onAcSeconds: 0, sleepSeconds: 0, topThree: [], totalUserEnergy: 0)
    @Published var narrative: AppNarrative? = nil
    @Published var compare = PeriodCompare(currentTotalEnergy: 0, previousTotalEnergy: 0, hasPrevious: false)
    @Published var anomalies: [String: AppAnomaly] = [:]
    @Published var liveWatts: LivePowerReading? = nil
    @Published var liveAppWatts: [String: Double] = [:]   // app id → estimated W
    @Published var displayPowerWatts: Double? = nil
    @Published var displayBrightnessPercent: Int? = nil
    @Published var batterySnapshot: BatterySnapshot? = nil
    @Published var avgWatts1h: Double? = nil              // son 1 saatlik ortalama gerçek W
    @Published var adjustedRemainingMin: Int? = nil
    @Published var stats = DBStats()
    @Published var lastRefresh: Date = Date()
    @Published var loading: Bool = false
    @Published var errorMessage: String? = nil

    // ponytail: history can lag 5 minutes; shorten if minute-level chart updates matter.
    private static let historyRefreshInterval: TimeInterval = 5 * 60
    private var refreshTimer: Timer?
    private var reloadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var lastHistoryRefresh = Date.distantPast

    private struct ReloadData {
        let apps: [GroupedApp]
        let batteryTimeline: [BatterySample]
        let sleepPeriods: [SleepInterval]
        let sparklines: [String: [Double]]
        let hero: HeroSummary
        let totalUserEnergy: Int64
        let compare: PeriodCompare
        let anomalies: [String: AppAnomaly]
        let stats: DBStats
        let avgWatts1h: Double?
        let adjustedRemainingMin: Int?
    }

    init() {
        // Timer closure'larında "weak self"i Task'a girmeden önce strong'a alıyoruz.
        // Swift 6 strict-concurrency, mutable captured self'in concurrent context'te
        // doğrudan kullanılmasına izin vermez; unwrap'leyince Task immutable constant kapatır.
        refreshLiveWatts()
        startRefreshTimer()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if Date().timeIntervalSince(self.lastHistoryRefresh) >= Self.historyRefreshInterval {
                    self.refreshNow()
                } else {
                    self.refreshLiveWatts()
                }
            }
        }
    }

    func setLiveMonitoring(_ enabled: Bool) {
        if enabled {
            guard refreshTimer == nil else { return }
            refreshLiveWatts()
            startRefreshTimer()
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    /// Read only the live system and power-source values.
    func refreshLiveWatts() {
        let reading = PowerSourceReader.liveWatts()
        let display = PowerSourceReader.displayPowerEstimate()
        let brightness = display?.brightness.map { Int(($0 * 100).rounded()) }
        let snapshot = PowerSourceReader.batterySnapshot()
        if liveWatts?.watts != reading?.watts
            || liveWatts?.isCharging != reading?.isCharging
            || liveWatts?.amperage_mA != reading?.amperage_mA
            || liveWatts?.voltage_mV != reading?.voltage_mV {
            liveWatts = reading
        }
        if displayPowerWatts != display?.watts { displayPowerWatts = display?.watts }
        if displayBrightnessPercent != brightness { displayBrightnessPercent = brightness }
        if !sameBatterySnapshot(batterySnapshot, snapshot) { batterySnapshot = snapshot }
        let allocationTotal = apps.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
        if let r = reading, r.watts > 0.1, allocationTotal > 0 {
            var dist: [String: Double] = [:]
            for app in apps {
                let frac = Double(max(app.energyRaw, 0)) / Double(allocationTotal)
                dist[app.id] = frac * r.watts
            }
            if liveAppWatts != dist { liveAppWatts = dist }
        } else if !liveAppWatts.isEmpty {
            liveAppWatts = [:]
        }
    }

    private func sameBatterySnapshot(_ lhs: BatterySnapshot?, _ rhs: BatterySnapshot?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.percent == rhs.percent
            && lhs.isCharging == rhs.isCharging
            && lhs.externalConnected == rhs.externalConnected
            && lhs.designCapacity_mAh == rhs.designCapacity_mAh
            && lhs.maxCapacity_mAh == rhs.maxCapacity_mAh
            && lhs.currentCapacity_mAh == rhs.currentCapacity_mAh
            && lhs.voltage_mV == rhs.voltage_mV
            && lhs.amperage_mA == rhs.amperage_mA
            && lhs.temperatureC == rhs.temperatureC
            && lhs.macOsTimeRemainingMin == rhs.macOsTimeRemainingMin
            && lhs.cycleCount == rhs.cycleCount
            && lhs.serial == rhs.serial
            && lhs.chargeLimitPercent == rhs.chargeLimitPercent
            && lhs.adapterWatts == rhs.adapterWatts
            && lhs.adapterVoltage_mV == rhs.adapterVoltage_mV
            && lhs.adapterCurrent_mA == rhs.adapterCurrent_mA
            && lhs.adapterIsWireless == rhs.adapterIsWireless
            && lhs.lowPowerModeEnabled == rhs.lowPowerModeEnabled
    }

    func refreshNow() {
        refreshLiveWatts()
        lastHistoryRefresh = Date()
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        loading = true

        let seconds = range.seconds
        let bucketSeconds = range.bucketSeconds
        let onBattery = onBattery
        let showSystem = showSystem
        let snapshot = batterySnapshot
        reloadTask = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .utility) {
                    try Self.loadReloadData(
                        seconds: seconds,
                        bucketSeconds: bucketSeconds,
                        onBattery: onBattery,
                        showSystem: showSystem,
                        snapshot: snapshot
                    )
                }.value
                guard !Task.isCancelled else { return }
                guard let self, self.reloadGeneration == generation else { return }
                self.apply(data, generation: generation)
            } catch {
                guard !Task.isCancelled, let self, self.reloadGeneration == generation else { return }
                self.loading = false
                self.errorMessage = String(format: NSLocalizedString("Could not read data: %@", comment: ""), "\(error)")
            }
        }
    }

    private nonisolated static func loadReloadData(
        seconds: Int64,
        bucketSeconds: Int,
        onBattery: Bool,
        showSystem: Bool,
        snapshot: BatterySnapshot?
    ) throws -> ReloadData {
        let db = try Database(path: Database.defaultPath())
        let reporter = Reporter(db: db)
        let r = DateRange.since(seconds)

        let rawRows = try reporter.allApps(range: r, onlyBattery: onBattery)
        let grouped = AppGrouping.group(rawRows)
        let visible = showSystem ? grouped : grouped.filter { !$0.isSystem }

        let bat = try reporter.batteryTimeline(range: r, bucketSeconds: bucketSeconds)
            .map { BatterySample(date: Date(timeIntervalSince1970: TimeInterval($0.bucket)),
                                 percent: $0.percent, onBattery: $0.onBattery) }
        let sleep = try reporter.sleepPeriods(range: r).map {
            SleepInterval(start: Date(timeIntervalSince1970: TimeInterval($0.start)),
                          end: Date(timeIntervalSince1970: TimeInterval($0.end)))
        }
        let bs = try reporter.batterySummary(range: r)
        var avgWatts1h: Double?
        var adjustedRemainingMin: Int?
        if let snapshot, snapshot.fullWh > 0 {
            let observed = try? reporter.averageBatteryWatts(rangeSec: 3600, fullWh: snapshot.fullWh)
            avgWatts1h = observed?.watts
            if !snapshot.isCharging, snapshot.percent > 0, let observed, observed.watts > 0 {
                let remainingWh = snapshot.fullWh * Double(snapshot.percent) / 100.0
                let observedMin = remainingWh / observed.watts * 60.0
                if let systemMin = snapshot.macOsTimeRemainingMin, systemMin > 0 {
                    let bounded = min(max(observedMin, Double(systemMin) * 0.5), Double(systemMin) * 2.0)
                    adjustedRemainingMin = Int((Double(systemMin) * 0.75 + bounded * 0.25).rounded())
                } else {
                    adjustedRemainingMin = Int(observedMin.rounded())
                }
            }
        }

        let sparkBuckets = 32
        let sparkBucketSec = max(60, Int(seconds) / sparkBuckets)
        let rawSpark = try reporter.sparklineBuckets(range: r, bucketSeconds: sparkBucketSec, onlyBattery: onBattery)
        var sparkOut: [String: [Double]] = [:]
        let firstBucket = (r.from / Int64(sparkBucketSec)) * Int64(sparkBucketSec)
        let lastBucket = (r.to / Int64(sparkBucketSec)) * Int64(sparkBucketSec)
        let bucketCount = Int((lastBucket - firstBucket) / Int64(sparkBucketSec)) + 1
        for app in visible {
            var series = [Double](repeating: 0, count: max(1, min(bucketCount, sparkBuckets * 2)))
            for key in app.memberKeys {
                guard let points = rawSpark[key] else { continue }
                for (bucket, energy) in points {
                    let index = Int((bucket - firstBucket) / Int64(sparkBucketSec))
                    if index >= 0 && index < series.count {
                        series[index] += Double(max(0, energy))
                    }
                }
            }
            sparkOut[app.id] = series
        }

        let prevRange = DateRange(from: r.from - seconds, to: r.from)
        let prevByKey = (try? reporter.energyByGroupKey(range: prevRange, onlyBattery: onBattery)) ?? [:]
        let oldestSec = (try? reporter.stats().oldest) ?? nil
        let hasPrevious: Bool = {
            guard let oldestSec else { return false }
            return oldestSec <= prevRange.from + seconds / 2
        }()
        let prevTotal = visible.reduce(Int64(0)) { total, app in
            total + app.memberKeys.reduce(Int64(0)) { $0 + max(prevByKey[$1] ?? 0, 0) }
        }
        let curTotal = visible.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
        let compare = PeriodCompare(
            currentTotalEnergy: curTotal,
            previousTotalEnergy: prevTotal,
            hasPrevious: hasPrevious
        )

        var anomalies: [String: AppAnomaly] = [:]
        if hasPrevious {
            for app in visible {
                let prevEnergy = app.memberKeys.reduce(Int64(0)) { $0 + max(prevByKey[$1] ?? 0, 0) }
                guard prevEnergy > 10000, app.energyRaw > prevEnergy * 2 else { continue }
                let ratio = Double(app.energyRaw) / Double(prevEnergy)
                anomalies[app.id] = AppAnomaly(
                    ratio: ratio,
                    label: ratio >= 10
                        ? NSLocalizedString("10×+ usual", comment: "")
                        : String(format: NSLocalizedString("%.0f× usual", comment: ""), ratio)
                )
            }
        }

        let st = try reporter.stats()
        let totalUserEnergy = visible.filter { !$0.isSystem }
            .reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
        let hero = HeroSummary(
            firstPercent: bs.firstPercent,
            lastPercent: bs.lastPercent,
            onBatterySeconds: bs.onBatterySeconds,
            onAcSeconds: bs.onAcSeconds,
            sleepSeconds: bs.sleepSeconds,
            topThree: Array(visible.prefix(3)),
            totalUserEnergy: totalUserEnergy
        )
        let stats = DBStats(
            sampleCount: st.sampleCount,
            sizeBytes: st.dbBytes,
            oldest: st.oldest.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            newest: st.newest.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            calibrationFactor: st.calibrationFactor
        )
        return ReloadData(
            apps: visible,
            batteryTimeline: bat,
            sleepPeriods: sleep,
            sparklines: sparkOut,
            hero: hero,
            totalUserEnergy: totalUserEnergy,
            compare: compare,
            anomalies: anomalies,
            stats: stats,
            avgWatts1h: avgWatts1h,
            adjustedRemainingMin: adjustedRemainingMin
        )
    }

    private func apply(_ data: ReloadData, generation: Int) {
        guard generation == reloadGeneration else { return }
        loading = false
        apps = data.apps
        totalUserEnergy = data.totalUserEnergy
        batteryTimeline = data.batteryTimeline
        sleepPeriods = data.sleepPeriods
        sparklines = data.sparklines
        hero = data.hero
        compare = data.compare
        anomalies = data.anomalies
        stats = data.stats
        avgWatts1h = data.avgWatts1h
        adjustedRemainingMin = data.adjustedRemainingMin
        refreshLiveWatts()
        lastRefresh = Date()
        errorMessage = nil

        if let selectedAppId, !apps.contains(where: { $0.id == selectedAppId }) {
            self.selectedAppId = apps.first?.id
        } else if selectedAppId == nil {
            selectedAppId = apps.first?.id
        } else {
            reloadDetail()
        }
    }

    private func reloadDetail() {
        detailTask?.cancel()
        guard let id = selectedAppId,
              let app = apps.first(where: { $0.id == id }) else {
            detailTimeline = []
            narrative = nil
            return
        }

        let seconds = range.seconds
        let bucketSeconds = range.bucketSeconds
        let onBattery = onBattery
        detailTask = Task { [weak self] in
            do {
                let points = try await Task.detached(priority: .utility) {
                    let db = try Database(path: Database.defaultPath())
                    let reporter = Reporter(db: db)
                    let range = DateRange.since(seconds)
                    return try reporter.appTimelineMulti(
                        groupKeys: app.memberKeys,
                        range: range,
                        bucketSeconds: bucketSeconds,
                        onlyBattery: onBattery
                    ).map {
                        TimelineSample(
                            date: Date(timeIntervalSince1970: TimeInterval($0.bucket)),
                            energyRaw: $0.energyRaw,
                            cpuNs: $0.cpuNs
                        )
                    }
                }.value
                guard !Task.isCancelled, let self,
                      self.selectedAppId == id,
                      self.range.seconds == seconds,
                      self.onBattery == onBattery else { return }
                if self.detailTimeline != points {
                    self.detailTimeline = points
                    self.narrative = self.computeNarrative(samples: points, bucketSec: bucketSeconds)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.errorMessage = String(format: NSLocalizedString("Could not read details: %@", comment: ""), "\(error)")
            }
        }
    }

    private func computeNarrative(samples: [TimelineSample], bucketSec: Int) -> AppNarrative? {
        guard !samples.isEmpty else { return nil }
        // Aktif bucket: enerji veya cpu>0 olanlar
        let activeBuckets = samples.filter { $0.energyRaw > 0 || $0.cpuNs > 0 }
        let activeMinutes = (activeBuckets.count * bucketSec) / 60

        // En yüksek enerjili bucket (peak)
        let peakSample = samples.max(by: { $0.energyRaw < $1.energyRaw })
        var peakHour: Int? = nil
        var peakDay: Date? = nil
        if let peakSample, peakSample.energyRaw > 0 {
            peakHour = Calendar.current.component(.hour, from: peakSample.date)
            peakDay = Calendar.current.startOfDay(for: peakSample.date)
        }
        return AppNarrative(activeMinutes: activeMinutes, peakHourLocal: peakHour, peakDay: peakDay)
    }

    /// Yüzde — atomik, app içine gömülü; race-free.
    func sharePercent(of app: GroupedApp) -> Double {
        return app.sharePercent
    }
}
