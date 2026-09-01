import Foundation

/// Powermetrics ile cross-check kalibrasyonu.
///
/// `powermetrics` package/processor enerjisi verir; `ri_billed_energy` ise
/// process-attributed, Apple'a özel bir sayaçtır. Sonuç bu nedenle model ve
/// workload'a bağlı bir tahmindir; doğrudan pil enerjisi ölçümü değildir.
public struct CalibrationResult {
    public let factor: Double           // estimated package J / raw_unit
    public let totalJoules: Double      // estimated processor/package energy
    public let totalRawDelta: UInt64    // readable user processes' raw delta
    public let durationSec: Double
    public let plistSampleCount: Int
}

public enum CalibrationError: Error, CustomStringConvertible {
    case authorization(String)
    case powermetricsLaunch(String)
    case powermetricsExit(Int32, String)
    case parse(String)
    case insufficientLoad(String)

    public var description: String {
        switch self {
        case .authorization(let m): return "sudo authorization failed: \(m)"
        case .powermetricsLaunch(let m): return "powermetrics launch failed: \(m)"
        case .powermetricsExit(let c, let s): return "powermetrics exited \(c): \(s)"
        case .parse(let m): return "parse failed: \(m)"
        case .insufficientLoad(let m): return "calibration unreliable: \(m)"
        }
    }
}

public enum Calibrator {
    /// duration: toplam ölçüm saniyesi. intervalMs: powermetrics sample aralığı (ms).
    public static func run(durationSec: Int, intervalMs: Int = 5000) throws -> CalibrationResult {
        guard durationSec > 0, intervalMs > 0, durationSec <= Int.max / 1000 else {
            throw CalibrationError.parse("duration and interval must be positive")
        }
        let n = max(1, (durationSec * 1000) / intervalMs)

        // Authenticate before taking the baseline so password entry is not part
        // of the rusage measurement window.
        try authenticateSudo()

        // 1. Baseline rusage snapshot
        let baseline = snapshotRusages()

        // 2. powermetrics çalıştır (sudo gerek). Write to a file instead of a
        // pipe: waiting for a child while its stdout pipe is full deadlocks.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openmacbattery-powermetrics-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let pm = Process()
        pm.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        pm.arguments = [
            "-n",
            "/usr/bin/powermetrics",
            "--samplers", "cpu_power",
            "--format", "plist",
            "-i", String(intervalMs),
            "-n", String(n),
            "-o", outputURL.path
        ]
        let stderr = Pipe()
        pm.standardOutput = FileHandle.nullDevice
        pm.standardError = stderr

        let t0 = Date()
        do { try pm.run() }
        catch { throw CalibrationError.powermetricsLaunch("\(error)") }
        pm.waitUntilExit()
        let elapsed = Date().timeIntervalSince(t0)
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if pm.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CalibrationError.powermetricsExit(pm.terminationStatus, msg)
        }

        // Take the endpoint before parsing the file so parsing time is not in
        // the rusage window.
        let final = snapshotRusages()
        let outData: Data
        do {
            outData = try Data(contentsOf: outputURL)
        } catch {
            throw CalibrationError.parse("cannot read powermetrics output: \(error)")
        }

        // 3. Birden fazla plist document peş peşe; her biri NUL byte ile ayrılır.
        let samples = try parsePlistStream(data: outData)
        guard !samples.isEmpty else {
            throw CalibrationError.parse("no plist samples in powermetrics output")
        }

        // 4. Package/processor energy estimate.
        var totalJoules: Double = 0
        var sampleCount = 0
        for sample in samples {
            if let joules = packageEnergy(in: sample) {
                totalJoules += joules
                sampleCount += 1
            }
        }
        guard totalJoules > 0, sampleCount > 0 else {
            throw CalibrationError.parse(
                "no usable processor power readings (keys: \(samples.first?.keys.sorted().joined(separator: ",") ?? "—"))"
            )
        }
        if n > 1, sampleCount < 2 {
            throw CalibrationError.parse("only \(sampleCount) usable powermetrics sample; expected multiple samples")
        }

        // 5. rusage delta. Only processes readable at both endpoints can be
        // matched; short-lived processes are deliberately excluded.
        var totalRawDelta: UInt64 = 0
        for (key, finalEnergy) in final {
            if let baseEnergy = baseline[key], finalEnergy >= baseEnergy {
                let delta = finalEnergy - baseEnergy
                let (sum, overflow) = totalRawDelta.addingReportingOverflow(delta)
                guard !overflow else { throw CalibrationError.parse("raw energy total overflowed") }
                totalRawDelta = sum
            }
        }

        guard totalRawDelta > 1000 else {
            throw CalibrationError.insufficientLoad(
                "rusage delta sum too small (\(totalRawDelta)); run a CPU workload during calibration"
            )
        }

        let factor = totalJoules / Double(totalRawDelta)
        guard factor.isFinite, factor > 0 else {
            throw CalibrationError.parse("computed factor is not finite")
        }
        return CalibrationResult(
            factor: factor,
            totalJoules: totalJoules,
            totalRawDelta: totalRawDelta,
            durationSec: elapsed,
            plistSampleCount: sampleCount
        )
    }

    // MARK: - Helpers

    private static func authenticateSudo() throws {
        let auth = Process()
        auth.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        auth.arguments = ["-v"]
        auth.standardInput = FileHandle.standardInput
        auth.standardOutput = FileHandle.standardOutput
        auth.standardError = FileHandle.standardError
        do { try auth.run() }
        catch { throw CalibrationError.authorization("\(error)") }
        auth.waitUntilExit()
        guard auth.terminationStatus == 0 else {
            throw CalibrationError.authorization("run calibration from Terminal and enter your password when prompted")
        }
    }

    /// Tüm okunabilir user process'lerin (pid,start) → billed_energy haritası.
    private static func snapshotRusages() -> [ProcessKey: UInt64] {
        var out: [ProcessKey: UInt64] = [:]
        for pid in ProcessInfoReader.listAllPids() {
            guard let id = ProcessInfoReader.identity(pid: pid), id.uid == getuid() else { continue }
            guard let r = ProcessInfoReader.rusage(pid: pid), r.rusageVersion >= 6 else { continue }
            out[ProcessKey(pid: pid, startTvSec: id.startTvSec, startTvUsec: id.startTvUsec)] = r.billedEnergy
        }
        return out
    }

    /// Return estimated processor/package joules for one powermetrics plist.
    /// Apple Silicon commonly exposes `processor.clusters[].combined_power` in mW;
    /// Intel exposes package joules/watts under `processor.packages`.
    static func packageEnergy(in sample: [String: Any]) -> Double? {
        guard let elapsedNs = number(sample["elapsed_ns"]), elapsedNs > 0 else { return nil }
        let seconds = elapsedNs / 1_000_000_000.0

        if let processor = sample["processor"] as? [String: Any] {
            if let packages = dictionaries(processor["packages"]) {
                var joules = 0.0
                var found = false
                for package in packages {
                    if let value = number(package["package_joules"]) {
                        joules += value
                        found = true
                    } else if let watts = number(package["package_watts"]) {
                        joules += watts * seconds
                        found = true
                    }
                }
                if found { return joules }
            }

            if let value = number(processor["package_joules"]) { return value }
            if let watts = number(processor["package_watts"]) { return watts * seconds }
            if let mw = number(processor["combined_power"]) {
                return mw / 1000.0 * seconds
            }

            if let clusters = dictionaries(processor["clusters"]) {
                let combinedMW = clusters.compactMap { number($0["combined_power"]) }.reduce(0, +)
                if combinedMW > 0 { return combinedMW / 1000.0 * seconds }

                let componentMW = clusters.flatMap { cluster in
                    ["cpu_power", "gpu_power", "ane_power"].compactMap { number(cluster[$0]) }
                }.reduce(0, +)
                if componentMW > 0 { return componentMW / 1000.0 * seconds }
            }
        }

        if let joules = number(sample["package_joules"]) { return joules }
        if let mw = number(sample["combined_power"]) { return mw / 1000.0 * seconds }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]]? {
        guard let values = value as? [Any] else { return nil }
        let result = values.compactMap { $0 as? [String: Any] }
        return result.isEmpty ? nil : result
    }

    /// powermetrics --format plist çıktısını parse et.
    static func parsePlistStream(data: Data) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var current = Data()
        for byte in data {
            if byte == 0x00 {
                if !current.isEmpty {
                    do {
                        guard let plist = try PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any] else {
                            throw CalibrationError.parse("powermetrics document is not a dictionary")
                        }
                        results.append(plist)
                    } catch let error as CalibrationError {
                        throw error
                    } catch {
                        throw CalibrationError.parse("invalid plist document \(results.count + 1): \(error)")
                    }
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            do {
                guard let plist = try PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any] else {
                    throw CalibrationError.parse("powermetrics document is not a dictionary")
                }
                results.append(plist)
            } catch let error as CalibrationError {
                throw error
            } catch {
                throw CalibrationError.parse("invalid plist document \(results.count + 1): \(error)")
            }
        }
        return results
    }
}
