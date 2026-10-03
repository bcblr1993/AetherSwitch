import Foundation
import os

/// Bounded, opt-in timing evidence for real hardware acceptance. No polling,
/// logging, or file I/O is enabled during ordinary application use.
final class BrightnessTrace: Sendable {
    struct Event: Codable, Sendable {
        let milliseconds: Double
        let kind: String
        let display: UInt32
        let value: Double
        let durationMilliseconds: Double
    }
    private struct State { var start: Double?; var events = [Event]() }
    static let shared = BrightnessTrace()
    private let state = OSAllocatedUnfairLock(initialState: State())
    func begin() { state.withLock { $0 = State(start: ProcessInfo.processInfo.systemUptime) } }
    func record(_ kind: String, display: UInt32, value: Double, duration: Double = 0) {
        state.withLock { state in
            guard let start = state.start, state.events.count < 2048 else { return }
            state.events.append(Event(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                      kind: kind, display: display, value: value, durationMilliseconds: duration * 1000))
        }
    }
    func finish() -> [Event] { state.withLock { state in state.start = nil; return state.events } }
}
