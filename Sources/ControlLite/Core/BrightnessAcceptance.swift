import AppKit

/// Opt-in hardware acceptance, using the panel's actual slider action. Always restore
/// each screen separately because their initial brightness levels may differ.
@MainActor
enum BrightnessAcceptance {
    static func record(_ displays: [BrightnessDisplay]) -> [[String: Any]] {
        displays.map {
            var item: [String: Any] = ["id": $0.id, "name": $0.name, "control": $0.control.rawValue]
            if let value = $0.value { item["brightness"] = value }
            if let issue = $0.issue { item["issue"] = issue }
            if $0.isSoftwareBlackout { item["softwareBlackout"] = true }
            if let value = $0.hardwareValue { item["hardwareBrightness"] = value }
            return item
        }
    }

    static func run(includeBlackout: Bool = false) async -> [String: Any] {
        let hardware = SystemBrightnessHardware()
        let manager = BrightnessManager(hardware: hardware, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        let original = manager.snapshot.displays
        let controlled = original.filter(\.isControllable)
        var result: [String: Any] = ["before": record(original)]
        guard !controlled.isEmpty else {
            result["passed"] = false; result["error"] = "No controllable displays"; return result
        }
        guard !includeBlackout || controlled.contains(where: { $0.control == .ddc }) else {
            result["passed"] = false; result["error"] = "A real DDC display is required for blackout acceptance"; return result
        }
        let controller = NativePanelController(brightness: manager)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let slider = descendants(controller.view).compactMap { $0 as? NSSlider }.first
        await manager.waitUntilIdle()
        let target = min(0.8, max(0.2, (controlled.first?.value ?? 0.5) + 0.04))
        if let slider {
            if includeBlackout {
                slider.doubleValue = 0
                _ = slider.target?.perform(slider.action, with: slider)
                await manager.waitUntilIdle()
                result["zeroAfterWrite"] = record(manager.snapshot.displays)
                let zero = await hardware.discover()
                result["zero"] = record(zero)
                result["zeroVerified"] = controlled.allSatisfy { original in
                    zero.contains { $0.id == original.id && $0.issue == nil && ($0.value ?? -1) <= 0.01 &&
                        (original.control != .ddc || $0.isSoftwareBlackout) }
                }
                try? await Task.sleep(for: .milliseconds(750))
            }
            for value in [target - 0.02, target - 0.01, target] {
                slider.doubleValue = value
                _ = slider.target?.perform(slider.action, with: slider)
            }
            await manager.waitUntilIdle()
            result["afterWrite"] = record(manager.snapshot.displays)
            let after = await hardware.discover()
            result["target"] = target
            result["after"] = record(after)
            result["synchronized"] = controlled.allSatisfy { original in
                after.contains { $0.id == original.id && $0.issue == nil && !$0.isSoftwareBlackout && abs(($0.value ?? -1) - target) < 0.02 }
            }
        } else { result["error"] = "Slider was not found" }
        var restorationIssues: [String] = []
        for display in controlled {
            let restored = await hardware.setBrightness(display.value!, displays: [display])
            restorationIssues += restored.compactMap(\.issue)
        }
        if !DisplayGammaBlackout.shared.restoreAll() { restorationIssues.append("Gamma restoration failed") }
        let restored = await hardware.discover()
        result["restored"] = record(restored)
        let restoredAll = restorationIssues.isEmpty && controlled.allSatisfy { original in
            restored.contains { $0.id == original.id && abs(($0.value ?? -1) - original.value!) < 0.02 }
        }
        result["restoredOriginalValues"] = restoredAll
        result["passed"] = (result["synchronized"] as? Bool == true) && restoredAll && (!includeBlackout || result["zeroVerified"] as? Bool == true)
        return result
    }
}
