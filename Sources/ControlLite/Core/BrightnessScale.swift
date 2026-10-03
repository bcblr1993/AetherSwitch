import Foundation

/// The bottom quarter continues below DDC's minimum using the original Gamma
/// curve. Conversion in both directions keeps discovery and slider in agreement.
enum BrightnessScale {
    static let softwareRange = 0.25
    static func components(_ value: Double) -> (hardware: Double, software: Double) {
        let value = min(1, max(0, value))
        if value < softwareRange { return (0, value / softwareRange) }
        return ((value - softwareRange) / (1 - softwareRange), 1)
    }
    static func combined(hardware: Double, software: Double) -> Double {
        let hardwareLevel = softwareRange + min(1, max(0, hardware)) * (1 - softwareRange)
        return min(1, max(0, software)) * hardwareLevel
    }
}
