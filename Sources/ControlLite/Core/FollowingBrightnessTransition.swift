import Foundation
import os

/// Retarget one running fade instead of cancelling and restarting it. Sleeping
/// after each presented frame prevents overdue frames from being replayed in a burst.
final class FollowingBrightnessTransition: Sendable {
    private struct State {
        var value: Double
        var target: Double
        var failed = false
        var stopped = false
        var worker: Task<Void, Never>?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let interval: Duration
    private let apply: @Sendable (Double) -> Bool

    init(initial: Double, interval: Duration = .milliseconds(16), apply: @escaping @Sendable (Double) -> Bool) {
        state = OSAllocatedUnfairLock(initialState: State(value: initial, target: initial))
        self.interval = interval
        self.apply = apply
    }

    var value: Double { state.withLock { $0.value } }
    var target: Double { state.withLock { $0.target } }
    var failed: Bool { state.withLock { $0.failed } }
    var isRunning: Bool { state.withLock { $0.worker != nil } }

    @discardableResult
    func retarget(_ value: Double, animated: Bool = true) -> Bool {
        guard value.isFinite, (0...1).contains(value) else { return false }
        return state.withLock { state in
            guard !state.stopped else { return false }
            state.target = value
            state.failed = false
            if !animated {
                state.failed = !apply(value)
                if !state.failed { state.value = value }
            }
            if state.value != state.target, state.worker == nil {
                state.worker = Task.detached { [self] in await run() }
            }
            return !state.failed
        }
    }

    private func run() async {
        while state.withLock({ state in
            guard !state.stopped, !state.failed, state.value != state.target else {
                state.worker = nil
                return false
            }
            let delta = state.target - state.value
            // Follow the moving target from the last displayed value.
            // Bound each change so a stalled WindowServer cannot cause a large jump.
            let limit = state.value < 0.31 ? 0.015 : 0.04
            let next = abs(delta) < 0.002 ? state.target : state.value + max(-limit, min(limit, delta * 0.24))
            state.failed = !apply(next)
            if !state.failed { state.value = next }
            return true
        }) {
            try? await Task.sleep(for: interval)
        }
    }

    func waitUntilIdle() async {
        while let worker = state.withLock({ $0.worker }) { await worker.value }
    }

    func stop() { state.withLock { $0.stopped = true } }
}

/// A separate lane for slow DDC writes. There is only one in-flight write and
/// one latest desired value; obsolete intermediate values never form a queue.
final class CoalescedBrightnessWriter: Sendable {
    private struct State {
        var desired: UInt16
        var applied: UInt16
        var failed = false
        var stopped = false
        var worker: Task<Void, Never>?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let maximumStep: UInt16
    private let write: @Sendable (UInt16, @Sendable () -> Bool) -> Bool
    init(initial: UInt16, maximumStep: UInt16 = .max, write: @escaping @Sendable (UInt16, @Sendable () -> Bool) -> Bool) {
        state = OSAllocatedUnfairLock(initialState: State(desired: initial, applied: initial))
        self.maximumStep = max(1, maximumStep)
        self.write = write
    }
    var applied: UInt16 { state.withLock { $0.applied } }
    var failed: Bool { state.withLock { $0.failed } }
    var isRunning: Bool { state.withLock { $0.worker != nil } }
    private var mayWrite: Bool { state.withLock { !$0.stopped } }

    func request(_ value: UInt16) -> Bool {
        state.withLock { state in
            guard !state.stopped, !state.failed else { return false }
            state.desired = value
            if state.desired != state.applied, state.worker == nil {
                state.worker = Task.detached { [self] in drain() }
            }
            return true
        }
    }
    private func drain() {
        while let value = state.withLock({ state -> UInt16? in
            guard !state.stopped, !state.failed, state.desired != state.applied else {
                state.worker = nil
                return nil
            }
            return state.desired > state.applied ? state.applied + min(maximumStep, state.desired - state.applied) :
                state.applied - min(maximumStep, state.applied - state.desired)
        }) {
            let success = write(value, { [self] in mayWrite })
            state.withLock { state in
                state.failed = !success && !state.stopped
                if success { state.applied = value }
            }
        }
    }
    func waitUntilIdle() async {
        while let worker = state.withLock({ $0.worker }) { await worker.value }
    }
    func stop() { state.withLock { $0.stopped = true } }
}
