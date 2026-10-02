import AppKit
import Combine

struct BrightnessDisplay: Equatable, Sendable, Identifiable {
    enum Control: String, Sendable { case native, ddc, unavailable }
    let id: UInt32
    let name: String
    let control: Control
    var value: Double?
    var issue: String?
    var isSoftwareBlackout = false
    var hardwareValue: Double?
    var isControllable: Bool { control != .unavailable && value != nil }
}

protocol BrightnessHardware: Sendable {
    func discover() async -> [BrightnessDisplay]
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay]
}

/// No polling while folded. One worker serializes refreshes and coalesces slider events.
@MainActor
final class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager(hardware: SystemBrightnessHardware())

    struct Snapshot: Equatable {
        var displays: [BrightnessDisplay] = []
        var value: Double = 0.5
        var isBusy = false
        var hasRefreshed = false
        var canAdjust: Bool { displays.contains(where: \.isControllable) }
        var message: String {
            guard hasRefreshed else { return "正在读取显示器…" }
            guard !displays.isEmpty else { return "没有可用的显示器" }
            let failures = displays.filter { $0.issue != nil }
            if let first = failures.first, let issue = first.issue {
                return "\(first.name)：\(issue)\(failures.count > 1 ? "（另有 \(failures.count - 1) 块）" : "")"
            }
            if displays.contains(where: \.isSoftwareBlackout) {
                return "外屏已软件全黑 · 调高滑条恢复（背光仍可能亮）"
            }
            let values = displays.compactMap(\.value)
            let differs = (values.max() ?? 0) - (values.min() ?? 0) > 0.015
            return differs ? "亮度不同 · 拖动后同步 \(values.count) 块屏幕" : "同步控制 \(values.count) 块屏幕"
        }
    }

    @Published private(set) var snapshot = Snapshot()
    private let hardware: any BrightnessHardware
    private let coalescingDelay: Duration
    private var pendingValue: Double?
    private var needsRefresh = false
    private var worker: Task<Void, Never>?
    private var screenObserver: AnyCancellable?

    init(hardware: any BrightnessHardware, coalescingDelay: Duration = .milliseconds(80), observeScreens: Bool = true) {
        self.hardware = hardware
        self.coalescingDelay = coalescingDelay
        if observeScreens {
            screenObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
        }
    }

    func refresh() {
        needsRefresh = true
        startWorker()
    }

    func setBrightness(_ value: Double) {
        guard value.isFinite, snapshot.canAdjust else { return }
        let value = min(1, max(0, value))
        pendingValue = value
        snapshot.value = value
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        snapshot.isBusy = true
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while needsRefresh || pendingValue != nil {
            // Hot-plug discovery takes priority; never reuse a removed display's endpoint.
            if needsRefresh {
                needsRefresh = false
                let displays = await hardware.discover()
                snapshot.displays = displays
                snapshot.hasRefreshed = true
                if pendingValue == nil { snapshot.value = displays.first(where: \.isControllable)?.value ?? 0.5 }
            }
            if pendingValue != nil {
                try? await Task.sleep(for: coalescingDelay)
                if needsRefresh { continue }
                guard let value = pendingValue else { continue }
                pendingValue = nil
                let displays = await hardware.setBrightness(value, displays: snapshot.displays)
                // A late response must not rewind the thumb while the user is still dragging.
                if pendingValue == nil && !needsRefresh {
                    snapshot.displays = displays
                    snapshot.value = displays.first(where: \.isControllable)?.value ?? value
                }
            }
        }
        snapshot.isBusy = false
        worker = nil
    }

    /// Used by native acceptance checks; waits for the final coalesced hardware operation.
    func waitUntilIdle() async { await worker?.value }
}
