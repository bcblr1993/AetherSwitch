import AppKit
import os

/// Software frames never await I2C. Hardware brightness is ramped through the
/// same combined scale, with obsolete DDC values coalesced on a separate worker.
final class ExternalBrightnessRuntime: Sendable {
    let identity: BrightnessDDC.Identity
    let maximum: UInt16
    let fade: FollowingBrightnessTransition
    let writer: CoalescedBrightnessWriter
    var isRunning: Bool { fade.isRunning || writer.isRunning }
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    var isStopped: Bool { stopped.withLock { $0 } }

    init(id: UInt32, endpoint: BrightnessDDCEndpoint, reading: BrightnessDDC.Reading,
         software: Double, dimmer: DisplayGammaBlackout, transport: BrightnessDDCTransport) {
        identity = endpoint.identity
        maximum = reading.maximum
        let key = endpoint.identity
        let retained = OSAllocatedUnfairLock(initialState: endpoint)
        let writer = CoalescedBrightnessWriter(initial: reading.current, maximumStep: max(1, reading.maximum / 25)) { raw, mayWrite in
            guard mayWrite(), CGDisplayIsOnline(id) != 0,
                  CGDisplayVendorNumber(id) == key.vendor, CGDisplayModelNumber(id) == key.product,
                  CGDisplaySerialNumber(id) == key.serial else { return false }
            let start = ProcessInfo.processInfo.systemUptime
            let endpoint = retained.withLock { $0 }
            if transport.matches(endpoint), transport.write(endpoint, packet: BrightnessDDC.write(raw), while: mayWrite) {
                BrightnessTrace.shared.record("ddc", display: id, value: Double(raw), duration: ProcessInfo.processInfo.systemUptime - start)
                return true
            }
            guard mayWrite(), let fresh = transport.endpoint(key) else { return false }
            retained.withLock { $0 = fresh }
            let success = transport.write(fresh, packet: BrightnessDDC.write(raw), while: mayWrite)
            if success { BrightnessTrace.shared.record("ddc", display: id, value: Double(raw), duration: ProcessInfo.processInfo.systemUptime - start) }
            return success
        }
        self.writer = writer
        let softwareLevel = OSAllocatedUnfairLock(initialState: software)
        fade = FollowingBrightnessTransition(initial: BrightnessScale.combined(
            hardware: Double(reading.current) / Double(reading.maximum), software: software)) { value in
            guard CGDisplayIsOnline(id) != 0, dimmer.matchesIdentity(id, key) else { return false }
            let start = ProcessInfo.processInfo.systemUptime
            let components = BrightnessScale.components(value)
            guard writer.request(BrightnessDDC.rawValue(components.hardware, maximum: reading.maximum)) else { return false }
            // Above the threshold the original Gamma stays intact; avoid a
            // ColorSync round trip for every hardware-only animation frame.
            if softwareLevel.withLock({ $0 == components.software }) {
                BrightnessTrace.shared.record("frame", display: id, value: value)
                return true
            }
            guard dimmer.setDimming(components.software, on: id) else { return false }
            softwareLevel.withLock { $0 = components.software }
            BrightnessTrace.shared.record("gamma", display: id, value: components.software, duration: ProcessInfo.processInfo.systemUptime - start)
            BrightnessTrace.shared.record("frame", display: id, value: value)
            return true
        }
    }
    func stop() {
        stopped.withLock { $0 = true }
        writer.stop()
        fade.stop()
    }
    func waitUntilIdle() async {
        repeat {
            await fade.waitUntilIdle()
            await writer.waitUntilIdle()
        } while isRunning
    }
}
