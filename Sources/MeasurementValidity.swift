import Foundation

/// Shared gate for benchmark results that report a usable measurement.
enum MeasurementValidity {
    static func isValid(statusPassed: Bool, ok: Bool, fps: Double?) -> Bool {
        guard statusPassed, ok, let fps else { return false }
        return fps.isFinite && fps > 0
    }
}
