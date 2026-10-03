import XCTest
@testable import ControlLite

final class BrightnessScaleTests: XCTestCase {
    func testContinuousScaleSpansBlackHardwareMinimumAndMaximum() {
        for value in [0.0, 0.001, 0.1, 0.249, 0.25, 0.251, 0.5, 1] {
            let result = BrightnessScale.components(value)
            XCTAssertEqual(BrightnessScale.combined(hardware: result.hardware, software: result.software), value, accuracy: 0.000001)
            if value < 0.25 { XCTAssertEqual(result.hardware, 0) }
        }
    }
    func testPowerPacketsValidateCodeChecksumAndDiscretePowerReply() {
        XCTAssertEqual(BrightnessDDC.request(), [0x82, 0x01, 0x10, 0xFD])
        XCTAssertEqual(BrightnessDDC.request(.powerMode), [0x82, 0x01, 0xD6, 0x3B])
        let packet = BrightnessDDC.write(4, command: .powerMode)
        XCTAssertEqual(Array(packet.prefix(5)), [0x84, 0x03, 0xD6, 0, 4])
        XCTAssertEqual(packet.reduce(UInt8(0x6E ^ 0x51), ^), 0)
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0, 0xD6, 1, 0, 0, 0, 4]
        reply.append(reply.reduce(0x50, ^))
        XCTAssertEqual(BrightnessDDC.parse(reply, command: .powerMode)?.current, 4)
        XCTAssertNil(BrightnessDDC.parse(reply))
        reply[10] ^= 1
        XCTAssertNil(BrightnessDDC.parse(reply, command: .powerMode))
    }
}
