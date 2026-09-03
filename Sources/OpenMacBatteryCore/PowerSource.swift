import Foundation
import CoreGraphics
import Darwin
import IOKit
import IOKit.ps

public struct PowerState {
    public let isOnBattery: Bool
    public let batteryPercent: Int?  // 0-100, AC + no battery durumunda nil

    public static let unknown = PowerState(isOnBattery: false, batteryPercent: nil)
}

/// Pil sağlığı + kapasite + macOS'un kalan süre tahmini.
public struct BatterySnapshot {
    public let percent: Int                // 0-100
    public let isCharging: Bool
    public let externalConnected: Bool     // adaptör takılı mı (şarj olmasa bile)
    public let designCapacity_mAh: Int     // orijinal tasarım kapasitesi
    public let maxCapacity_mAh: Int        // şu anki sağlıklı tavan (yıpranmaya göre)
    public let currentCapacity_mAh: Int    // şu an dolu olan
    public let voltage_mV: Int
    public let amperage_mA: Int            // negatif = deşarj, pozitif = şarj
    public let temperatureC: Double        // °C (Temperature × 0.01)
    public let macOsTimeRemainingMin: Int? // sistem tahmini (kaynaklı)
    public let cycleCount: Int
    public let serial: String?
    public let chargeLimitPercent: Int?
    public let adapterWatts: Int?
    public let adapterVoltage_mV: Int?
    public let adapterCurrent_mA: Int?
    public let adapterIsWireless: Bool?
    public let lowPowerModeEnabled: Bool

    /// Kullanılabilir tam doluluk Wh
    public var fullWh: Double {
        let cap = maxCapacity_mAh > 0 ? maxCapacity_mAh : designCapacity_mAh
        return Double(cap) * Double(voltage_mV) / 1_000_000.0
    }
    /// Şu an pildeki Wh
    public var remainingWh: Double {
        return Double(currentCapacity_mAh) * Double(voltage_mV) / 1_000_000.0
    }
    /// Sağlık % (max / design)
    public var healthPercent: Int {
        guard designCapacity_mAh > 0 else { return 100 }
        return min(100, max(0, Int(round(Double(maxCapacity_mAh) / Double(designCapacity_mAh) * 100))))
    }
}

/// Anlık güç çekişi (W). Pozitif = pildeyken çekiş, negatif = şarj olurken doluş.
public struct LivePowerReading {
    public let watts: Double          // mutlak değer
    public let isCharging: Bool
    public let amperage_mA: Int       // ham
    public let voltage_mV: Int        // ham

    public static func compute(amperage_mA: Int, voltage_mV: Int, isCharging: Bool? = nil) -> LivePowerReading {
        let w = Double(abs(amperage_mA)) * Double(voltage_mV) / 1_000_000.0
        return LivePowerReading(
            watts: w,
            isCharging: isCharging ?? (amperage_mA > 0),
            amperage_mA: amperage_mA,
            voltage_mV: voltage_mV
        )
    }
}

public struct DisplayPowerEstimate {
    public let watts: Double
    public let displayCount: Int
    public let brightness: Double?

    /// Generic built-in display estimate: about 0.6 W at minimum brightness and 4 W at full.
    public static func estimatedWatts(brightness: Double, displayCount: Int) -> Double {
        guard displayCount > 0 else { return 0 }
        let level = min(max(brightness, 0), 1)
        return Double(displayCount) * (0.6 + 3.4 * level)
    }
}

public enum PowerSourceReader {
    public static func current() -> PowerState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }

        var isOnBattery = false
        var percent: Int? = nil

        // Provider tipini de oku — "Battery Power" → pildeyken
        if let provType = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            isOnBattery = (provType == kIOPSBatteryPowerValue)
        }

        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let cap = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(cap) / Double(max) * 100.0).rounded())
            }
        }

        return PowerState(isOnBattery: isOnBattery, batteryPercent: percent)
    }

    /// Sistem genel anlık güç tüketimi (W). Pildeyken pil deşarj hızından çekiş, şarjda doluş.
    /// IOPS sadece mA verir, voltage'ı vermez — `AppleSmartBattery` IORegistry entry'sini okuyoruz.
    /// Sudo / private framework gerekmez; ioreg bunları zaten public okuyor.
    public static func liveWatts() -> LivePowerReading? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(svc) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        // Voltage mV — battery nominal ~11400, dolu ~12600
        let voltage_mV: Int = (dict["Voltage"] as? Int) ?? 0
        // Amperage mA — pildeyken negatif (deşarj), şarjda pozitif
        let amperage_mA: Int = (dict["InstantAmperage"] as? Int)
            ?? (dict["Amperage"] as? Int)
            ?? 0
        guard voltage_mV > 0, amperage_mA != 0 else { return nil }
        return LivePowerReading.compute(
            amperage_mA: amperage_mA,
            voltage_mV: voltage_mV,
            isCharging: dict["IsCharging"] as? Bool
        )
    }

    /// Estimated power used by awake built-in displays. This is a model, not a wattmeter.
    public static func displayPowerEstimate() -> DisplayPowerEstimate? {
        var count: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }

        let builtIn = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
        guard !builtIn.isEmpty else { return nil }
        let awake = builtIn.filter { CGDisplayIsAsleep($0) == 0 }
        guard !awake.isEmpty else {
            return DisplayPowerEstimate(watts: 0, displayCount: builtIn.count, brightness: nil)
        }

        let levels = awake.compactMap(displayBrightness)
        let brightness = levels.count == awake.count
            ? levels.reduce(0, +) / Double(levels.count)
            : nil
        // CoreDisplay/DisplayServices are private APIs. Keep the old midpoint
        // estimate when Apple removes or changes the getter.
        let level = brightness ?? 0.5
        return DisplayPowerEstimate(
            watts: DisplayPowerEstimate.estimatedWatts(brightness: level, displayCount: awake.count),
            displayCount: awake.count,
            brightness: brightness
        )
    }

    private static func displayBrightness(_ displayID: CGDirectDisplayID) -> Double? {
        let frameworks = [
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        ]
        for path in frameworks {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            defer { dlclose(handle) }

            if path.contains("CoreDisplay"),
               let symbol = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") {
                typealias GetBrightness = @convention(c) (CGDirectDisplayID) -> Float
                let value = Double(unsafeBitCast(symbol, to: GetBrightness.self)(displayID))
                if value.isFinite, (0...1).contains(value) { return value }
            }

            if path.contains("DisplayServices"),
               let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
                typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
                var value: Float = 0
                let result = unsafeBitCast(symbol, to: GetBrightness.self)(displayID, &value)
                let level = Double(value)
                if result == 0, level.isFinite, (0...1).contains(level) { return level }
            }
        }
        return nil
    }

    private static func configuredChargeLimit() -> Int? {
        let defaults = UserDefaults(suiteName: "com.apple.batteryui.charging.mac")
        let limit = defaults?.integer(forKey: "com.apple.batteryui.charging.mac.prior.limit") ?? 0
        return (50...100).contains(limit) ? limit : nil
    }

    public static func batterySnapshot() -> BatterySnapshot? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        let percent = (dict["CurrentCapacity"] as? Int) ?? 0
        let voltage = (dict["Voltage"] as? Int) ?? 0
        let amperage = (dict["InstantAmperage"] as? Int)
            ?? (dict["Amperage"] as? Int) ?? 0
        let isCharging = (dict["IsCharging"] as? Bool) ?? false
        let external = (dict["ExternalConnected"] as? Bool) ?? false
        let design = (dict["DesignCapacity"] as? Int) ?? 0
        let rawMax = (dict["AppleRawMaxCapacity"] as? Int) ?? 0
        let maxCap = rawMax > 0 ? rawMax : design
        let curRaw = (dict["AppleRawCurrentCapacity"] as? Int) ?? 0
        let currentCapacity = curRaw > 0
            ? curRaw
            : Int((Double(maxCap) * Double(percent) / 100.0).rounded())
        func validTime(_ key: String) -> Int? {
            guard let value = dict[key] as? Int, value > 0, value < 65535 else { return nil }
            return value
        }
        let tRem = validTime(isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty")
            ?? validTime("TimeRemaining")
        let cycles = (dict["CycleCount"] as? Int) ?? 0
        let temp = Double((dict["Temperature"] as? Int) ?? 0) / 100.0
        let serial = dict["Serial"] as? String
        // DailyMaxSoc is macOS's adaptive daily target, not the user's
        // configured charge limit. The selected limit is stored by Battery
        // settings in its own user-defaults domain.
        let chargeLimit = configuredChargeLimit()
        let adapter = (dict["AdapterDetails"] as? [String: Any])
            ?? (dict["AppleRawAdapterDetails"] as? [String: Any])

        return BatterySnapshot(
            percent: percent,
            isCharging: isCharging,
            externalConnected: external,
            designCapacity_mAh: design,
            maxCapacity_mAh: maxCap,
            currentCapacity_mAh: currentCapacity,
            voltage_mV: voltage,
            amperage_mA: amperage,
            temperatureC: temp,
            macOsTimeRemainingMin: tRem,
            cycleCount: cycles,
            serial: serial,
            chargeLimitPercent: chargeLimit,
            adapterWatts: adapter?["Watts"] as? Int,
            adapterVoltage_mV: adapter?["AdapterVoltage"] as? Int,
            adapterCurrent_mA: adapter?["Current"] as? Int,
            adapterIsWireless: adapter?["IsWireless"] as? Bool,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}
