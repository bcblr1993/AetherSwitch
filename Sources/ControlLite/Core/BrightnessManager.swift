import AppKit
import Combine
import CoreGraphics

/// 单个显示器的对外亮度快照（供分屏幕独立亮度抽屉与自动化读取）。
public struct DisplayBrightnessItem: Equatable, Sendable, Identifiable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let brightness: Double
    public let supportsControl: Bool

    public init(
        id: CGDirectDisplayID,
        name: String,
        isBuiltIn: Bool,
        brightness: Double,
        supportsControl: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.brightness = brightness.isFinite ? min(1, max(0, brightness)) : 0
        self.supportsControl = supportsControl
    }
}

struct BrightnessDisplay: Equatable, Sendable, Identifiable {
    enum Control: String, Sendable { case native, ddc, unavailable }
    let id: UInt32
    let name: String
    let control: Control
    var value: Double?
    var issue: String?
    var isSoftwareBlackout = false
    var hardwareValue: Double?
    var softwareDimming: Double = 1
    var isBacklightOff = false
    var supportsBacklightOff = false
    var wasInterruptedBySystem = false
    var isBuiltIn: Bool? = nil
    var isControllable: Bool { control != .unavailable && value != nil }
    var resolvedIsBuiltIn: Bool { isBuiltIn ?? (control == .native) }
}

protocol BrightnessHardware: Sendable {
    func discover() async -> [BrightnessDisplay]
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay]
    func readNativeBrightness(displays: [BrightnessDisplay]) async -> [BrightnessDisplay]
    func cancelPendingTransition()
    @MainActor func updateBrightnessTarget(_ value: Double, displays: [BrightnessDisplay]) -> Set<UInt32>
    func settleBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay]
}

extension BrightnessHardware {
    func cancelPendingTransition() {}
    @MainActor func updateBrightnessTarget(_ value: Double, displays: [BrightnessDisplay]) -> Set<UInt32> { [] }
    func settleBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        await setBrightness(value, displays: displays)
    }
}

/// No polling while folded. One worker serializes refreshes and coalesces slider events.
@MainActor
public final class BrightnessManager: ObservableObject {
    public static let shared = BrightnessManager(hardware: SystemBrightnessHardware())
    static let followExternalDisplaysKey = "followExternalDisplays"

    struct Snapshot: Equatable {
        var displays: [BrightnessDisplay] = []
        var value: Double = 0.5
        var isBusy = false
        var hasRefreshed = false
        var systemObservationUnavailable = false
        var pendingDisplayOverrides: [CGDirectDisplayID: Double] = [:]
        var canAdjust: Bool { displays.contains(where: \.isControllable) }
        var displayItems: [DisplayBrightnessItem] {
            displays.map { display in
                let rawBrightness = pendingDisplayOverrides[display.id] ?? display.value ?? 0
                let clamped = rawBrightness.isFinite ? min(1, max(0, rawBrightness)) : 0
                return DisplayBrightnessItem(
                    id: display.id,
                    name: display.name,
                    isBuiltIn: display.resolvedIsBuiltIn,
                    brightness: clamped,
                    supportsControl: display.isControllable
                )
            }
        }
        var message: String {
            guard hasRefreshed else { return "正在读取显示器…" }
            guard !displays.isEmpty else { return "没有可用的显示器" }
            let failures = displays.filter { $0.issue != nil }
            if let first = failures.first, let issue = first.issue {
                return "\(first.name)：\(issue)\(failures.count > 1 ? "（另有 \(failures.count - 1) 块）" : "")"
            }
            if displays.contains(where: \.isBacklightOff) {
                return "外屏背光已关闭 · 调高亮度恢复"
            }
            if displays.contains(where: \.isSoftwareBlackout) {
                return "外屏已软件全黑 · 调高滑条恢复（背光仍可能亮）"
            }
            if systemObservationUnavailable { return "系统亮度同步不可用 · 拖动滑条同步" }
            let values = displays.compactMap(\.value)
            let differs = (values.max() ?? 0) - (values.min() ?? 0) > 0.015
            return differs ? "亮度不同 · 拖动后同步 \(values.count) 块屏幕" : "同步控制 \(values.count) 块屏幕"
        }
    }

    @Published private(set) var snapshot = Snapshot()
    public var displayItems: [DisplayBrightnessItem] { snapshot.displayItems }
    @Published private(set) var backlightOffAtZero = DisplayBacklightControl.shared.enabled
    @Published var followExternalDisplays: Bool {
        didSet {
            guard oldValue != followExternalDisplays else { return }
            defaults.set(followExternalDisplays, forKey: Self.followExternalDisplaysKey)
        }
    }
    private let hardware: any BrightnessHardware
    private let defaults: UserDefaults
    private let coalescingDelay: Duration
    private var pendingValue: Double?
    private var pendingSourceID: UInt32?
    private var pendingDisplayValues: [CGDirectDisplayID: Double] = [:]
    private var activePerDisplayID: CGDirectDisplayID?
    private var needsRefresh = false
    private var needsNativeRead = false
    private var forwardedNativeValues: [UInt32: Double] = [:]
    private var worker: Task<Void, Never>?
    private var nativeReader: Task<Void, Never>?
    private var screenObserver: AnyCancellable?
    private var brightnessSubscription: AnyCancellable?
    private var nativeObserver: SystemBrightnessObserver?
    private var systemObservationStopped = false
    private var forceExternalWrite = false
    private var scheduledNativeIDs: Set<UInt32> = []

    init(
        hardware: any BrightnessHardware,
        coalescingDelay: Duration = .milliseconds(16),
        observeScreens: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.hardware = hardware
        self.coalescingDelay = coalescingDelay
        self.defaults = defaults
        self.followExternalDisplays = (defaults.object(forKey: Self.followExternalDisplaysKey) as? Bool) ?? true
        if observeScreens {
            nativeObserver = SystemBrightnessObserver()
            brightnessSubscription = NotificationCenter.default.publisher(for: SystemBrightnessObserver.didChange)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.systemBrightnessChanged() }
                }
            screenObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.nativeObserver?.update(displays: [])
                        self?.refresh()
                    }
                }
        }
    }

    func setFollowExternalDisplays(_ enabled: Bool) {
        followExternalDisplays = enabled
    }

    func refresh() {
        needsRefresh = true
        startWorker()
    }

    func setBrightness(_ value: Double) {
        guard !systemObservationStopped, value.isFinite, snapshot.canAdjust else { return }
        let value = min(1, max(0, value))
        let scheduled = hardware.updateBrightnessTarget(value, displays: snapshot.displays)
        if scheduled.isEmpty { hardware.cancelPendingTransition() }
        scheduledNativeIDs = Set(snapshot.displays.filter { $0.control == .native && scheduled.contains($0.id) }.map(\.id))
        var next = snapshot
        for index in next.displays.indices where scheduledNativeIDs.contains(next.displays[index].id) {
            next.displays[index].value = value
            next.displays[index].issue = nil
            forwardedNativeValues[next.displays[index].id] = value
        }
        pendingDisplayValues.removeAll()
        next.pendingDisplayOverrides.removeAll()
        pendingValue = value
        pendingSourceID = nil
        next.value = value
        snapshot = next
        startWorker()
    }

    /// 按单个显示器 ID 独立调整亮度；仅写入目标显示器并复用既有的按端点隔离 I2C 锁与 EDID 校验，
    /// 不覆盖其他屏幕，也不破坏主总滑条与 `followExternalDisplays` 的既有行为。
    public func setDisplayBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        guard !systemObservationStopped, value.isFinite else { return }
        guard let index = snapshot.displays.firstIndex(where: { $0.id == displayID }),
              snapshot.displays[index].isControllable else { return }
        let clamped = min(1, max(0, value))
        let targetDisplay = snapshot.displays[index]
        let scheduled = hardware.updateBrightnessTarget(clamped, displays: [targetDisplay])
        var next = snapshot
        if targetDisplay.control == .native && scheduled.contains(displayID) {
            next.displays[index].value = clamped
            next.displays[index].issue = nil
            forwardedNativeValues[displayID] = clamped
            pendingDisplayValues.removeValue(forKey: displayID)
            next.pendingDisplayOverrides.removeValue(forKey: displayID)
            if next.displays.first(where: \.isControllable)?.id == displayID {
                next.value = clamped
            }
            snapshot = next
            return
        }
        pendingDisplayValues[displayID] = clamped
        next.pendingDisplayOverrides[displayID] = clamped
        if targetDisplay.control == .native {
            forwardedNativeValues[displayID] = clamped
        }
        snapshot = next
        startWorker()
    }

    func setBacklightOffAtZero(_ enabled: Bool) {
        DisplayBacklightControl.shared.enabled = enabled
        backlightOffAtZero = enabled
        if snapshot.value == 0 {
            forceExternalWrite = true
            setBrightness(0)
        }
    }

    /// Shared by the native notification path and deterministic acceptance tests.
    func systemBrightnessChanged() {
        guard !systemObservationStopped else { return }
        needsNativeRead = true
        // Native notifications must be consumed even while the external worker
        // awaits an I2C transaction or a running fade.
        if nativeReader == nil {
            nativeReader = Task { [weak self] in
                guard let self else { return }
                while self.needsNativeRead && !self.systemObservationStopped {
                    await self.readNativeChanges()
                }
                self.nativeReader = nil
                self.startWorker()
            }
        }
        startWorker()
    }

    func stopObservingSystemBrightness() {
        hardware.cancelPendingTransition()
        systemObservationStopped = true
        needsNativeRead = false
        needsRefresh = false
        pendingValue = nil
        pendingSourceID = nil
        pendingDisplayValues.removeAll()
        activePerDisplayID = nil
        snapshot.pendingDisplayOverrides.removeAll()
        scheduledNativeIDs = []
        brightnessSubscription = nil
        screenObserver = nil
        nativeObserver = nil
    }

    private func startWorker() {
        guard worker == nil else { return }
        snapshot.isBusy = true
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while needsRefresh || needsNativeRead || pendingValue != nil || !pendingDisplayValues.isEmpty {
            if needsNativeRead, let nativeReader { await nativeReader.value }
            // Hot-plug discovery takes priority; never reuse a removed display's endpoint.
            if needsRefresh {
                needsRefresh = false
                let displays = await hardware.discover()
                snapshot.displays = displays
                let controllableIDs = Set(displays.filter(\.isControllable).map(\.id))
                pendingDisplayValues = pendingDisplayValues.filter { controllableIDs.contains($0.key) }
                snapshot.pendingDisplayOverrides = snapshot.pendingDisplayOverrides.filter { controllableIDs.contains($0.key) }
                if let nativeObserver {
                    snapshot.systemObservationUnavailable = !nativeObserver.update(displays: displays)
                }
                // Refresh cannot acknowledge changes not yet sent to followers.
                let nativeIDs = Set(displays.filter { $0.control == .native }.map(\.id))
                forwardedNativeValues = forwardedNativeValues.filter { nativeIDs.contains($0.key) }
                for display in displays where display.control == .native && forwardedNativeValues[display.id] == nil {
                    forwardedNativeValues[display.id] = display.value
                }
                snapshot.hasRefreshed = true
                if pendingValue == nil { snapshot.value = displays.first(where: \.isControllable)?.value ?? 0.5 }
            }
            if needsNativeRead, nativeReader == nil { await readNativeChanges() }
            if pendingValue != nil {
                // Direct drags are submitted synchronously. Only system notification
                // bursts need a short merge interval; never pause each drag update.
                if pendingSourceID != nil { try? await Task.sleep(for: coalescingDelay) }
                if needsRefresh { continue }
                // Read the most recent system value once at the deadline; a
                // stream of duplicate notifications must not postpone writes.
                if needsNativeRead, nativeReader == nil { await readNativeChanges() }
                if needsRefresh { continue }
                guard let value = pendingValue else { continue }
                let sourceID = pendingSourceID
                let nativeIDs = scheduledNativeIDs
                scheduledNativeIDs = []
                pendingValue = nil
                pendingSourceID = nil
                let forceExternal = forceExternalWrite
                forceExternalWrite = false
                // Never write the source display back: macOS already set it.
                let targets = snapshot.displays.filter { display in
                    guard display.id != sourceID,
                          !nativeIDs.contains(display.id),
                          pendingDisplayValues[display.id] == nil,
                          display.isControllable else { return false }
                    if sourceID != nil && !followExternalDisplays && display.control == .ddc { return false }
                    let reachingZero = value == 0 && display.value != 0
                    let recovering = value > 0 && (display.value == 0 || display.isSoftwareBlackout || display.isBacklightOff)
                    let needsBlackout = display.control == .ddc && value == 0 && !display.isSoftwareBlackout && !display.isBacklightOff
                    return (forceExternal && display.control == .ddc) || (sourceID == nil && display.control == .native) || display.issue != nil ||
                        abs((display.value ?? -1) - value) >= 0.005 || reachingZero || recovering || needsBlackout
                }
                let updated = targets.isEmpty ? [] : await hardware.settleBrightness(value, displays: targets)
                let displays = snapshot.displays.map { display in updated.first(where: { $0.id == display.id }) ?? display }
                for display in displays where display.control == .native {
                    if display.wasInterruptedBySystem { needsNativeRead = true; continue }
                    if let value = display.value { forwardedNativeValues[display.id] = value }
                }
                // A late response must not rewind the thumb while the user is still dragging.
                if !needsRefresh {
                    snapshot.displays = displays
                    if pendingValue == nil && !needsNativeRead && pendingDisplayValues.isEmpty {
                        snapshot.value = displays.first(where: \.isControllable)?.value ?? value
                    }
                }
            }
            if !pendingDisplayValues.isEmpty {
                if needsRefresh { continue }
                guard let targetDisplay = snapshot.displays.first(where: { pendingDisplayValues[$0.id] != nil }),
                      let requestedValue = pendingDisplayValues.removeValue(forKey: targetDisplay.id) else {
                    pendingDisplayValues.removeAll()
                    snapshot.pendingDisplayOverrides.removeAll()
                    continue
                }
                guard targetDisplay.isControllable else {
                    snapshot.pendingDisplayOverrides.removeValue(forKey: targetDisplay.id)
                    continue
                }
                let reachingZero = requestedValue == 0 && targetDisplay.value != 0
                let recovering = requestedValue > 0 && (targetDisplay.value == 0 || targetDisplay.isSoftwareBlackout || targetDisplay.isBacklightOff)
                let needsBlackout = targetDisplay.control == .ddc && requestedValue == 0 && !targetDisplay.isSoftwareBlackout && !targetDisplay.isBacklightOff
                let shouldWrite = targetDisplay.control == .native || targetDisplay.issue != nil ||
                    abs((targetDisplay.value ?? -1) - requestedValue) >= 0.005 || reachingZero || recovering || needsBlackout
                if shouldWrite {
                    activePerDisplayID = targetDisplay.id
                    let updated = await hardware.settleBrightness(requestedValue, displays: [targetDisplay])
                    activePerDisplayID = nil
                    let displays = snapshot.displays.map { display in updated.first(where: { $0.id == display.id }) ?? display }
                    for display in updated where display.control == .native {
                        if display.wasInterruptedBySystem { needsNativeRead = true; continue }
                        if let settled = display.value { forwardedNativeValues[display.id] = settled }
                    }
                    if !needsRefresh {
                        snapshot.displays = displays
                        if pendingDisplayValues[targetDisplay.id] == nil {
                            snapshot.pendingDisplayOverrides.removeValue(forKey: targetDisplay.id)
                        }
                        if pendingValue == nil && !needsNativeRead && pendingDisplayValues.isEmpty {
                            snapshot.value = displays.first(where: \.isControllable)?.value ?? snapshot.value
                        }
                    }
                } else if pendingDisplayValues[targetDisplay.id] == nil {
                    snapshot.pendingDisplayOverrides.removeValue(forKey: targetDisplay.id)
                }
            }
        }
        snapshot.isBusy = false
        worker = nil
    }

    private func readNativeChanges() async {
        needsNativeRead = false
        let readings = await hardware.readNativeBrightness(displays: snapshot.displays)
        guard !systemObservationStopped else { return }
        // An app drag owns the target until it completes. Its own system
        // notification must neither rewind the thumb nor cause a write loop.
        if pendingValue == nil || pendingSourceID != nil {
            let changed = readings.first { display in
                guard pendingDisplayValues[display.id] == nil, activePerDisplayID != display.id else { return false }
                guard let value = display.value, let previous = forwardedNativeValues[display.id] else { return false }
                return abs(value - previous) >= 0.005 ||
                    (value != previous && (value == 0 || previous == 0))
            }
            for display in readings where pendingDisplayValues[display.id] == nil && activePerDisplayID != display.id {
                if let index = snapshot.displays.firstIndex(where: { $0.id == display.id }) {
                    snapshot.displays[index] = display
                }
            }
            if let changed, let value = changed.value {
                forwardedNativeValues[changed.id] = value
                let followers = snapshot.displays.filter {
                    $0.id != changed.id && (followExternalDisplays || $0.control != .ddc)
                }
                if followers.contains(where: \.isControllable) {
                    let scheduled = hardware.updateBrightnessTarget(value, displays: followers)
                    if scheduled.isEmpty { hardware.cancelPendingTransition() }
                    scheduledNativeIDs = Set(snapshot.displays.filter { $0.control == .native && scheduled.contains($0.id) }.map(\.id))
                    for index in snapshot.displays.indices where scheduledNativeIDs.contains(snapshot.displays[index].id) {
                        snapshot.displays[index].value = value
                        forwardedNativeValues[snapshot.displays[index].id] = value
                    }
                    pendingValue = value
                    pendingSourceID = changed.id
                    snapshot.value = value
                } else if pendingValue == nil {
                    snapshot.value = value
                }
            } else if pendingValue == nil && pendingDisplayValues.isEmpty {
                snapshot.value = snapshot.displays.first(where: \.isControllable)?.value ?? snapshot.value
            }
        }
    }

    /// Used by native acceptance checks; waits for the final coalesced hardware operation.
    func waitUntilIdle() async {
        repeat {
            await nativeReader?.value
            await worker?.value
        } while nativeReader != nil || worker != nil
    }
}
