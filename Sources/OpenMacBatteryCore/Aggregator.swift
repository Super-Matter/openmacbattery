import Foundation

/// Saatlik roll-up'ı `samples` → `hourly_aggregates` tablosuna idempotent şekilde yazar.
public final class Aggregator {
    private let db: Database
    public init(db: Database) { self.db = db }

    /// `since`'den (epoch sec) önceki saatler için aggregate üret.
    /// Default: raw-retention süresi içindeki tüm tamamlanmış saatler.
    /// Idempotent — INSERT OR REPLACE.
    public func rollUp(sinceEpochSec: Int64? = nil) throws {
        // Şu anki saatten önceki saatleri işle (devam eden saati bekle).
        let now = Int64(Date().timeIntervalSince1970)
        let currentHour = (now / 3600) * 3600
        let defaultSince = Int64(db.meta(key: "aggregated_through") ?? "")
            ?? (now - Int64(Database.rawRetentionDays) * 86400)
        let since = sinceEpochSec ?? defaultSince

        let sql = """
        WITH energy AS (
            SELECT
                (timestamp / 3600) * 3600 AS hour_epoch,
                COALESCE(bundle_id, exec_path, 'unknown') AS bkey,
                MAX(COALESCE(display_name, bundle_id, 'unknown')) AS dname,
                COALESCE(SUM(energy_nj), 0) AS total_energy,
                COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0) AS total_cpu,
                COALESCE(SUM(pkg_idle_wakeups + interrupt_wakeups), 0) AS total_wakeups,
                COUNT(*) AS sample_count,
                AVG(battery_percent) AS avg_battery
            FROM samples
            WHERE timestamp >= ? AND timestamp < ?
              AND energy_nj IS NOT NULL
            GROUP BY hour_epoch, bkey
        ), observations AS (
            SELECT
                timestamp,
                COALESCE(bundle_id, exec_path, 'unknown') AS bkey,
                MAX(is_on_battery) AS is_on_battery,
                LEAD(timestamp) OVER (
                    PARTITION BY COALESCE(bundle_id, exec_path, 'unknown')
                    ORDER BY timestamp
                ) AS next_timestamp
            FROM samples
            WHERE timestamp >= ? AND timestamp < ?
              AND energy_nj IS NOT NULL
            GROUP BY timestamp, bkey
        ), duration AS (
            SELECT
                (timestamp / 3600) * 3600 AS hour_epoch,
                bkey,
                SUM(CASE WHEN is_on_battery = 1 THEN
                    CASE
                        WHEN next_timestamp IS NULL THEN 60
                        WHEN next_timestamp - timestamp > 300 THEN 300
                        WHEN next_timestamp > timestamp THEN next_timestamp - timestamp
                        ELSE 0
                    END
                ELSE 0 END) AS on_battery_seconds
            FROM observations
            GROUP BY hour_epoch, bkey
        )
        INSERT OR REPLACE INTO hourly_aggregates
            (hour_epoch, bundle_id, display_name,
             total_energy_raw, total_cpu_ns, total_wakeups,
             sample_count, avg_battery_percent, on_battery_seconds)
        SELECT
            e.hour_epoch, e.bkey, e.dname,
            e.total_energy, e.total_cpu, e.total_wakeups,
            e.sample_count, e.avg_battery,
            COALESCE(d.on_battery_seconds, 0)
        FROM energy e
        LEFT JOIN duration d ON d.hour_epoch = e.hour_epoch AND d.bkey = e.bkey;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, since)
        try stmt.bind(2, currentHour)
        try stmt.bind(3, since)
        try stmt.bind(4, currentHour)
        try stmt.execute()
        if sinceEpochSec == nil {
            try db.setMeta(key: "aggregated_through", value: "\(currentHour)")
        }
    }
}
