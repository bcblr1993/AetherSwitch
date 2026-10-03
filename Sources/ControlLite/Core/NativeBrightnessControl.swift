import AppKit
import Darwin

/// DisplayServices' smooth setter accepts a delta, unlike its absolute setter.
/// Keep the framework loaded; immutable C entry points can serve the UI while DDC waits.
final class NativeBrightnessControl: Sendable {
    static let shared: NativeBrightnessControl = {
        typealias Get = @Sendable @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias Set = @Sendable @convention(c) (UInt32, Float) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness") else {
            return NativeBrightnessControl(read: { _ in nil }, set: { _, _ in false })
        }
        let get = unsafeBitCast(g, to: Get.self), set = unsafeBitCast(s, to: Set.self)
        let smooth = dlsym(handle, "DisplayServicesSetBrightnessSmooth").map { unsafeBitCast($0, to: Set.self) }
        return NativeBrightnessControl(read: { id in
            var value: Float = -1
            return get(id, &value) == 0 && value.isFinite && (0...1).contains(value) ? Double(value) : nil
        }, set: { set($0, Float($1)) == 0 }, smooth: smooth.map { function in
            { @Sendable id, delta in function(id, Float(delta)) == 0 }
        })
    }()

    private let readValue: @Sendable (UInt32) -> Double?
    private let setValue: @Sendable (UInt32, Double) -> Bool
    private let smoothValue: (@Sendable (UInt32, Double) -> Bool)?
    init(read: @escaping @Sendable (UInt32) -> Double?, set: @escaping @Sendable (UInt32, Double) -> Bool,
         smooth: (@Sendable (UInt32, Double) -> Bool)? = nil) {
        readValue = read; setValue = set; smoothValue = smooth
    }
    func read(_ id: UInt32) -> Double? { readValue(id) }
    func set(_ target: Double, on id: UInt32, animated: Bool) -> Bool {
        guard target.isFinite, (0...1).contains(target), let current = readValue(id),
              current.isFinite, (0...1).contains(current) else { return false }
        if animated, let smoothValue, smoothValue(id, target - current) { return true }
        return setValue(id, target)
    }
}
