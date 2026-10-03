import AppKit

/// Opt-in hardware acceptance, using the panel's actual slider action. Always restore
/// each screen separately because their initial brightness levels may differ.
@MainActor
enum BrightnessAcceptance {
    static func restore(from path: String) async -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let before = object["before"] as? [[String: Any]] else {
            return ["passed": false, "error": "Missing acceptance brightness backup"]
        }
        DisplayGammaBlackout.shared.restoreAll()
        let hardware = SystemBrightnessHardware()
        let displays = await hardware.discover()
        var results: [BrightnessDisplay] = []
        for record in before {
            if let id = record["id"] as? UInt32, let value = record["brightness"] as? Double,
               let display = displays.first(where: { $0.id == id && $0.isControllable }) {
                results += await hardware.setBrightness(value, displays: [display])
            }
        }
        return ["restored": record(await hardware.discover()),
                "passed": results.count == before.count && results.allSatisfy { $0.issue == nil }]
    }
    /// Drive only the native display through a separate hardware instance. The
    /// observer must update the real slider and DDC followers without refresh().
    static func runSystemSync() async -> [String: Any] {
        DisplayGammaBlackout.shared.restoreAll()
        let hardware = SystemBrightnessHardware()
        let manager = BrightnessManager(hardware: hardware)
        manager.refresh(); await manager.waitUntilIdle()
        let original = manager.snapshot.displays
        guard let source = original.first(where: { $0.control == .native && $0.value != nil }),
              original.contains(where: { $0.control == .ddc && $0.isControllable }) else {
            return ["passed": false, "error": "Real native and DDC displays are required"]
        }
        var controller: NativePanelController? = NativePanelController(brightness: manager)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var slider = descendants(controller!.view).compactMap { $0 as? NSSlider }.first
        await manager.waitUntilIdle()
        let driver = SystemBrightnessHardware()
        _ = await driver.discover()
        let base = source.value!
        let first = base >= 0.8 ? base - 0.04 : max(0.2, base + 0.04)
        let second = first >= 0.8 ? first - 0.04 : first + 0.04
        var steps: [[String: Any]] = []
        for (index, target) in [first, second].enumerated() {
            let nativeWrite = await driver.setBrightness(target, displays: [source])
            var matched = false
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                await manager.waitUntilIdle()
                matched = manager.snapshot.displays.filter(\.isControllable).allSatisfy {
                    $0.issue == nil && abs(($0.value ?? -1) - target) < 0.02
                } && abs(manager.snapshot.value - target) < 0.02
                if matched { break }
            }
            let actual = await driver.discover()
            let readback = original.filter(\.isControllable).allSatisfy { prior in
                actual.contains { $0.id == prior.id && $0.issue == nil && abs(($0.value ?? -1) - target) < 0.02 }
            }
            let uiMatches = index != 0 || slider.map { abs($0.doubleValue - target) < 0.02 } == true
            steps.append(["target": target, "nativeWrite": record(nativeWrite), "actual": record(actual),
                          "slider": manager.snapshot.value, "panelLoaded": controller != nil,
                          "passed": matched && readback && uiMatches])
            // The second change must synchronize with no panel/controller alive.
            slider = nil; controller = nil
        }
        // Detach observation before restoring each screen's independent setting.
        manager.stopObservingSystemBrightness()
        await manager.waitUntilIdle()
        for display in original.filter(\.isControllable) {
            _ = await driver.setBrightness(display.value!, displays: [display])
        }
        let restored = await driver.discover()
        let restoredAll = original.filter(\.isControllable).allSatisfy { prior in
            restored.contains { $0.id == prior.id && $0.issue == nil && abs(($0.value ?? -1) - prior.value!) < 0.02 }
        }
        return ["before": record(original), "steps": steps, "restored": record(restored),
                "restoredOriginalValues": restoredAll,
                "passed": restoredAll && steps.allSatisfy { $0["passed"] as? Bool == true }]
    }

    static func record(_ displays: [BrightnessDisplay]) -> [[String: Any]] {
        displays.map {
            var item: [String: Any] = ["id": $0.id, "name": $0.name, "control": $0.control.rawValue]
            if let value = $0.value { item["brightness"] = value }
            if let issue = $0.issue { item["issue"] = issue }
            if $0.isSoftwareBlackout { item["softwareBlackout"] = true }
            if let value = $0.hardwareValue { item["hardwareBrightness"] = value }
            if $0.softwareDimming < 1 { item["softwareDimming"] = $0.softwareDimming }
            item["backlightOff"] = $0.isBacklightOff
            return item
        }
    }

    static func run(includeBlackout: Bool = false) async -> [String: Any] {
        DisplayGammaBlackout.shared.restoreAll()
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
                var dimmingSteps: [[String: Any]] = []
                for low in [0.2, 0.1, 0.02] {
                    slider.doubleValue = low
                    _ = slider.target?.perform(slider.action, with: slider)
                    await manager.waitUntilIdle()
                    let actual = await hardware.discover()
                    let passed = controlled.allSatisfy { prior in
                        actual.contains { display in
                            display.id == prior.id && display.issue == nil && abs((display.value ?? -1) - low) < 0.02 &&
                            (display.control != .ddc || (display.hardwareValue == 0 && abs(display.softwareDimming - low / BrightnessScale.softwareRange) < 0.01))
                        }
                    }
                    var step: [String: Any] = ["target": low, "actual": record(actual), "passed": passed]
                    if let transition = await hardware.lastTransition {
                        step["transitionFrames"] = transition.frames
                        step["transitionMilliseconds"] = transition.milliseconds
                        step["transitionCancelled"] = transition.cancelled
                    }
                    dimmingSteps.append(step)
                }
                result["dimmingSteps"] = dimmingSteps
                result["dimmingVerified"] = dimmingSteps.allSatisfy { $0["passed"] as? Bool == true }
                slider.doubleValue = 0
                _ = slider.target?.perform(slider.action, with: slider)
                await manager.waitUntilIdle()
                if let transition = await hardware.lastTransition {
                    result["zeroTransition"] = ["frames": transition.frames, "milliseconds": transition.milliseconds,
                                                "cancelled": transition.cancelled, "failedScreens": transition.failed.count]
                }
                result["zeroAfterWrite"] = record(manager.snapshot.displays)
                let zero = await hardware.discover()
                result["zero"] = record(zero)
                result["zeroVerified"] = controlled.allSatisfy { original in
                    zero.contains { $0.id == original.id && $0.issue == nil && ($0.value ?? -1) <= 0.01 &&
                        (original.control != .ddc || $0.isSoftwareBlackout || $0.isBacklightOff) }
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
        result["passed"] = (result["synchronized"] as? Bool == true) && restoredAll &&
            (!includeBlackout || (result["zeroVerified"] as? Bool == true && result["dimmingVerified"] as? Bool == true))
        return result
    }
}
