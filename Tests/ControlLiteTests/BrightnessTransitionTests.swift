import XCTest
import os
@testable import ControlLite

private final class TransitionValues: Sendable {
    let values = OSAllocatedUnfairLock(initialState: [[Double]](repeating: [], count: 2))
    func append(_ value: Double, channel: Int) { values.withLock { $0[channel].append(value) } }
}

final class BrightnessTransitionTests: XCTestCase {
    func testNativeBrightnessKeysInterruptFadeWithoutBeingOverwritten() async {
        let transition = BrightnessTransition()
        let model = OSAllocatedUnfairLock(initialState: (value: 0.8, writes: [Double]()))
        let native = NativeBrightnessTransition(initial: 0.8, read: { model.withLock { $0.value } }, write: { value in
            model.withLock { state in
                state.writes.append(value)
                state.value = state.writes.count == 3 ? 0.6 : value
            }
            return true
        }, cancel: { transition.cancel() })
        let result = await transition.run([.init(from: 0.8, to: 0, apply: { native.apply($0) })],
            token: transition.token(), duration: .zero)
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(native.wasInterrupted)
        XCTAssertEqual(model.withLock { $0.writes.count }, 3)
        XCTAssertEqual(model.withLock { $0.value }, 0.6)
        XCTAssertFalse(model.withLock { $0.writes.contains(0) })
    }

    func testOwnNativeFramesDoNotCancelTheirAnimation() async {
        let transition = BrightnessTransition()
        let value = OSAllocatedUnfairLock(initialState: 0.8)
        let native = NativeBrightnessTransition(initial: 0.8, read: { value.withLock { $0 } }, write: { level in
            value.withLock { $0 = level }; return true
        }, cancel: { transition.cancel() })
        let result = await transition.run([.init(from: 0.8, to: 0, apply: { native.apply($0) })],
            token: transition.token(), duration: .zero)
        XCTAssertFalse(result.cancelled)
        XCTAssertFalse(native.wasInterrupted)
        XCTAssertEqual(value.withLock { $0 }, 0)
    }
    func testScreensUseOneSmoothTimelineAndReachExactZero() async {
        let transition = BrightnessTransition(), values = TransitionValues()
        let steps = [
            BrightnessTransition.Step(from: 1, to: 0, apply: { values.append($0, channel: 0); return true }),
            BrightnessTransition.Step(from: 0.5, to: 0, apply: { values.append($0, channel: 1); return true })
        ]
        let result = await transition.run(steps, token: transition.token(), duration: .zero)
        let recorded = values.values.withLock { $0 }
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.frames, 12)
        XCTAssertEqual(recorded[0].count, 12)
        XCTAssertEqual(recorded[0].last, 0)
        XCTAssertGreaterThan(recorded[0][0], 0.95, "The first frame must not abruptly switch to black")
        for index in 1..<12 { XCTAssertLessThan(recorded[0][index], recorded[0][index - 1]) }
        for index in 0..<12 { XCTAssertEqual(recorded[1][index], recorded[0][index] / 2, accuracy: 0.00001) }
        let firstChange = 1 - recorded[0][0], middleChange = recorded[0][5] - recorded[0][6]
        XCTAssertLessThan(firstChange, middleChange, "Ease in and out instead of making a visible initial jump")
    }

    func testNewInputStopsOldBlackoutAndRetargetsFromCurrentLevel() async {
        let transition = BrightnessTransition(), values = TransitionValues()
        let step = BrightnessTransition.Step(from: 1, to: 0, apply: { value in
            values.append(value, channel: 0)
            if values.values.withLock({ $0[0].count }) == 3 { transition.cancel() }
            return true
        })
        let first = await transition.run([step], token: transition.token(), duration: .zero)
        XCTAssertTrue(first.cancelled)
        let level = values.values.withLock { $0[0].last! }
        XCTAssertGreaterThan(level, 0)
        let second = await transition.run([.init(from: level, to: 0.8, apply: {
            values.append($0, channel: 1); return true
        })], token: transition.token(), duration: .zero)
        XCTAssertFalse(second.cancelled)
        XCTAssertEqual(values.values.withLock { $0[1].last }, 0.8)
        XCTAssertFalse(values.values.withLock { $0[0].contains(0) }, "Cancelled blackout must never reach zero later")
    }

    func testCancelledBeforeStartNeverTouchesHardwareAndIdleLevelsAreWrittenOnce() async {
        let transition = BrightnessTransition(), values = TransitionValues()
        let old = transition.token()
        transition.cancel()
        let step = BrightnessTransition.Step(from: 0.5, to: 0.5, apply: { values.append($0, channel: 0); return true })
        let cancelled = await transition.run([step], token: old, duration: .zero)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(values.values.withLock { $0[0].isEmpty })
        let stable = await transition.run([step], token: transition.token())
        XCTAssertEqual(stable.frames, 1)
        XCTAssertEqual(values.values.withLock { $0[0] }, [0.5])
    }

    func testFailedScreenDoesNotBlockOtherScreenAndDoesNotRepeatFailedWrites() async {
        let transition = BrightnessTransition(), values = TransitionValues()
        let result = await transition.run([
            .init(from: 1, to: 0, apply: { values.append($0, channel: 0); return false }),
            .init(from: 1, to: 0, apply: { values.append($0, channel: 1); return true })
        ], token: transition.token(), duration: .zero)
        XCTAssertEqual(result.failed, [0])
        XCTAssertEqual(values.values.withLock { $0[0].count }, 1)
        XCTAssertEqual(values.values.withLock { $0[1].last }, 0)
    }
}
