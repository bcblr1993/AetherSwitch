import Foundation
import os

/// A short, shared timeline for native brightness and external Gamma. New input
/// invalidates the current timeline synchronously, without queuing stale fades.
final class BrightnessTransition: Sendable {
    struct Step: Sendable {
        let from: Double
        let to: Double
        let apply: @Sendable (Double) -> Bool
    }
    struct Result: Sendable {
        var cancelled = false
        var failed: Set<Int> = []
        var frames = 0
        var milliseconds: Double = 0
    }
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))
    func token() -> UInt64 { generation.withLock { $0 } }
    func cancel() { generation.withLock { $0 &+= 1 } }
    func isCurrent(_ token: UInt64) -> Bool {
        !Task.isCancelled && generation.withLock { $0 == token }
    }

    func run(_ steps: [Step], token: UInt64, duration: Duration = .milliseconds(200), frameCount: Int = 12) async -> Result {
        var result = Result()
        let clock = ContinuousClock(), start = clock.now
        let count = max(1, frameCount)
        let animated = steps.contains { $0.from != $0.to }
        let frames = animated ? count : 1
        let interval = animated ? duration / count : .zero
        for frame in 1...frames {
            do { try await clock.sleep(until: start + interval * frame) }
            catch { result.cancelled = true; break }
            guard isCurrent(token) else { result.cancelled = true; break }
            let progress = Double(frame) / Double(frames)
            let eased = progress * progress * (3 - 2 * progress)
            for (index, step) in steps.enumerated() where !result.failed.contains(index) {
                if step.from == step.to && frame > 1 { continue }
                guard step.from.isFinite, step.to.isFinite,
                      (0...1).contains(step.from), (0...1).contains(step.to) else {
                    result.failed.insert(index); continue
                }
                guard isCurrent(token) else { result.cancelled = true; break }
                let value = frame == frames ? step.to : step.from + (step.to - step.from) * eased
                if !step.apply(value) { result.failed.insert(index) }
            }
            result.frames += 1
            if result.cancelled { break }
        }
        let elapsed = start.duration(to: clock.now).components
        result.milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        return result
    }
}

/// Yield to brightness keys or automatic brightness instead of overwriting a
/// native value changed by macOS between our animation frames.
final class NativeBrightnessTransition: Sendable {
    private struct State { var expected: Double; var interrupted = false }
    private let state: OSAllocatedUnfairLock<State>
    private let read: @Sendable () -> Double?
    private let write: @Sendable (Double) -> Bool
    private let cancel: @Sendable () -> Void
    init(initial: Double, read: @escaping @Sendable () -> Double?, write: @escaping @Sendable (Double) -> Bool,
         cancel: @escaping @Sendable () -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(expected: initial))
        self.read = read; self.write = write; self.cancel = cancel
    }
    var wasInterrupted: Bool { state.withLock { $0.interrupted } }
    func apply(_ value: Double) -> Bool {
        state.withLock { state in
            guard let current = read(), current.isFinite else { return false }
            if abs(current - state.expected) > 0.005 {
                state.interrupted = true
                cancel()
                return true
            }
            guard write(value) else { return false }
            state.expected = value
            return true
        }
    }
}
