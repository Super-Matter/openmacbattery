import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct CalibrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Show native process energy measurement status"
    )

    @Flag(name: .long, help: "Just show the current factor and exit")
    var show: Bool = false

    func run() throws {
        let db = try openDatabase()

        if show {
            if let f = db.meta(key: "energy_unit_factor") {
                print("Current native energy factor: \(f) J / nJ")
                if let when = db.meta(key: "energy_unit_calibrated_at") {
                    print("Calibrated at:  \(when)")
                }
            } else {
                print("Native energy measurement is not initialized; run: openmacbattery calibrate")
            }
            return
        }

        try db.setMeta(key: "energy_metric", value: "ri_energy_nj")
        try db.setMeta(key: "energy_unit_factor", value: "1e-9")
        print("Native energy measurement is already enabled.")
        print("  Source:  ri_energy_nj")
        print("  Unit:    1 nJ = 1e-9 J")
        print("  No sudo calibration is needed on Apple Silicon.")
    }
}
