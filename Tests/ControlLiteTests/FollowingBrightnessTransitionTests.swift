import XCTest
import os
@testable import ControlLite

final class FollowingBrightnessTransitionTests: XCTestCase {
    func testMovingTargetKeepsFollowingAndNeverReachesObsoleteBlackout() async {
        let values = OSAllocatedUnfairLock(initialState: [Double]())
        let fade = FollowingBrightnessTransition(initial: 0.8, interval: .milliseconds(1)) {
            value in values.withLock { $0.append(value) }; return true
        }
        fade.retarget(0)
        for _ in 0..<10_000 { if !values.withLock({ $0.isEmpty }) { break }; await Task.yield() }
        fade.retarget(0.7)
        await fade.waitUntilIdle()
        let frames = values.withLock { $0 }
        XCTAssertFalse(frames.contains(0))
        XCTAssertEqual(frames.last, 0.7)
        var previous = 0.8
        for value in frames { XCTAssertLessThanOrEqual(abs(value - previous), 0.060001); previous = value }
    }

    func testReduceMotionFailureAndShutdown() async {
        let values = OSAllocatedUnfairLock(initialState: [Double]())
        let fade = FollowingBrightnessTransition(initial: 0.8) { value in values.withLock { $0.append(value) }; return true }
        XCTAssertFalse(fade.retarget(.nan))
        XCTAssertFalse(fade.retarget(2))
        XCTAssertTrue(fade.retarget(0, animated: false))
        await fade.waitUntilIdle()
        XCTAssertEqual(values.withLock { $0 }, [0])
        fade.stop()
        XCTAssertFalse(fade.retarget(1))
        let failed = FollowingBrightnessTransition(initial: 1, interval: .zero) { _ in false }
        failed.retarget(0)
        await failed.waitUntilIdle()
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.value, 1)
    }

    func testSlowFramesDoNotReplayMissedDeadlinesInABurst() async {
        let times = OSAllocatedUnfairLock(initialState: [Double]())
        let fade = FollowingBrightnessTransition(initial: 0.04, interval: .milliseconds(12)) { _ in
            Thread.sleep(forTimeInterval: 0.02)
            times.withLock { $0.append(ProcessInfo.processInfo.systemUptime) }
            return true
        }
        fade.retarget(0)
        await fade.waitUntilIdle()
        let recorded = times.withLock { $0 }
        XCTAssertGreaterThan(recorded.count, 3)
        for (a, b) in zip(recorded, recorded.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 0.029) }
        XCTAssertEqual(fade.value, 0)
    }

    func testDDCWriterDropsQueuedTargetsWhileOneWriteIsBlocked() async {
        let entered = expectation(description: "in-flight write")
        let release = DispatchSemaphore(value: 0)
        let values = OSAllocatedUnfairLock(initialState: [UInt16]())
        let writer = CoalescedBrightnessWriter(initial: 80) { value, mayWrite in
            let first = values.withLock { $0.isEmpty }
            if first { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            guard mayWrite() else { return false }
            values.withLock { $0.append(value) }
            return true
        }
        XCTAssertTrue(writer.request(20))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(writer.request(30)); XCTAssertTrue(writer.request(40)); XCTAssertTrue(writer.request(60))
        release.signal()
        await writer.waitUntilIdle()
        XCTAssertEqual(values.withLock { $0 }, [20, 60])
        XCTAssertEqual(writer.applied, 60)
    }

    func testDDCStepLimitAndStopBeforeLateWrite() async {
        let values = OSAllocatedUnfairLock(initialState: [UInt16]())
        let writer = CoalescedBrightnessWriter(initial: 0, maximumStep: 4) { value, _ in
            values.withLock { $0.append(value) }; return true
        }
        XCTAssertTrue(writer.request(18)); await writer.waitUntilIdle()
        XCTAssertEqual(values.withLock { $0 }, [4, 8, 12, 16, 18])
        XCTAssertTrue(writer.request(1)); await writer.waitUntilIdle()
        XCTAssertEqual(Array(values.withLock { $0 }.suffix(5)), [14, 10, 6, 2, 1])
        let entered = expectation(description: "blocked write")
        let release = DispatchSemaphore(value: 0)
        let committed = OSAllocatedUnfairLock(initialState: false)
        let stopped = CoalescedBrightnessWriter(initial: 100) { _, mayWrite in
            entered.fulfill(); _ = release.wait(timeout: .now() + 5)
            guard mayWrite() else { return false }
            committed.withLock { $0 = true }; return true
        }
        XCTAssertTrue(stopped.request(0))
        await fulfillment(of: [entered], timeout: 2)
        stopped.stop(); release.signal(); await stopped.waitUntilIdle()
        XCTAssertFalse(committed.withLock { $0 })
        XCTAssertFalse(stopped.request(50))
    }

    func testNativeSmoothSetterUsesDeltaAndReduceMotionUsesAbsoluteValue() {
        let model = OSAllocatedUnfairLock(initialState: (current: 0.4, smooth: [Double](), direct: [Double]()))
        let native = NativeBrightnessControl(read: { _ in model.withLock { $0.current } }, set: { _, value in
            model.withLock { $0.current = value; $0.direct.append(value) }; return true
        }, smooth: { _, delta in model.withLock { $0.current += delta; $0.smooth.append(delta) }; return true })
        XCTAssertTrue(native.set(0.7, on: 1, animated: true))
        XCTAssertTrue(native.set(0.2, on: 1, animated: true))
        XCTAssertTrue(native.set(0.8, on: 1, animated: false))
        XCTAssertFalse(native.set(.infinity, on: 1, animated: true))
        let result = model.withLock { $0 }
        XCTAssertEqual(result.smooth[0], 0.3, accuracy: 0.00001)
        XCTAssertEqual(result.smooth[1], -0.5, accuracy: 0.00001)
        XCTAssertEqual(result.direct, [0.8])
    }

    func testNativeSmoothFailureFallsBackAndInvalidReadbackIsRejected() {
        let written = OSAllocatedUnfairLock(initialState: [Double]())
        let native = NativeBrightnessControl(read: { _ in 0.4 }, set: { _, value in
            written.withLock { $0.append(value) }; return true
        }, smooth: { _, _ in false })
        XCTAssertTrue(native.set(0.6, on: 1, animated: true))
        XCTAssertEqual(written.withLock { $0 }, [0.6])
        let invalid = NativeBrightnessControl(read: { _ in .nan }, set: { _, _ in true })
        XCTAssertFalse(invalid.set(0.6, on: 1, animated: true))
    }

    func testNativeFallbackWithoutSmoothSymbol() {
        let target = OSAllocatedUnfairLock(initialState: 0.4)
        let native = NativeBrightnessControl(read: { _ in target.withLock { $0 } }, set: { _, value in
            target.withLock { $0 = value }; return true
        })
        XCTAssertTrue(native.set(0.6, on: 1, animated: true))
        XCTAssertEqual(target.withLock { $0 }, 0.6)
        XCTAssertFalse(NativeBrightnessControl(read: { _ in nil }, set: { _, _ in true }).set(0.6, on: 1, animated: true))
    }
}
