import AppKit

/// DisplayServices uses CFNotificationCallback, not a callback carrying a float.
/// Read the current native value after notification; do not trust undocumented payloads.
/// ABI: https://github.com/alin23/Lunar/blob/master/Lunar/DDC/Lunar-Bridging-Header.h
@MainActor
final class SystemBrightnessObserver {
    static let didChange = Notification.Name("com.aethernative.aetherswitch.systemBrightnessChanged")
    private typealias Register = @convention(c) (UInt32, UInt32, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (UInt32, UInt32) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let register: Register?
    private let unregister: Unregister?
    // Accessed on the main actor; deinit occurs only after the owner releases it.
    private var registered: Set<UInt32> = []

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        self.handle = handle
        register = handle.flatMap { dlsym($0, "DisplayServicesRegisterForBrightnessChangeNotifications") }
            .map { unsafeBitCast($0, to: Register.self) }
        unregister = handle.flatMap { dlsym($0, "DisplayServicesUnregisterForBrightnessChangeNotifications") }
            .map { unsafeBitCast($0, to: Unregister.self) }
    }

    @discardableResult
    func update(displays: [BrightnessDisplay]) -> Bool {
        let desired = Set(displays.filter { $0.control == .native }.map(\.id))
        guard let register, let unregister else { return desired.isEmpty }
        for id in registered.subtracting(desired) {
            _ = unregister(id, id)
            registered.remove(id)
        }
        for id in desired.subtracting(registered) {
            let result = register(id, id) { _, _, _, _, _ in
                Task { @MainActor in
                    NotificationCenter.default.post(name: SystemBrightnessObserver.didChange, object: nil)
                }
            }
            if result == 0 { registered.insert(id) }
        }
        return desired.isSubset(of: registered)
    }

    deinit {
        for id in registered { _ = unregister?(id, id) }
        // A queued system callback may still execute after unregister. Keep the
        // framework loaded for process lifetime rather than invalidating its code.
    }
}
