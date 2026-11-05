import AppKit
import Darwin

/// CLI 诊断入口、运行期回执安全写入与开机项验收逻辑（与 AppDelegate 界面职责解耦）。
enum RuntimeAcceptance {
    @MainActor
    static func handleLaunchArguments(_ arguments: [String] = CommandLine.arguments) -> Bool {
        if arguments.contains("--keep-awake-status") {
            let manager = SwitchManager.shared
            let restored = manager.restoreKeepAwakePreference()
            let result: [String: Any] = [
                "saved": UserDefaults.standard.bool(forKey: SwitchManager.keepAwakePreferenceKey),
                "active": manager.getCurrentStates().isKeepAwakeActive,
                "restored": restored
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
               let json = String(data: data, encoding: .utf8) { print(json) }
            return true
        }
        if arguments.contains("--acceptance-brightness-following") || arguments.contains("--brightness-status") || arguments.contains("--acceptance-brightness-cycle") || arguments.contains("--acceptance-brightness-blackout") || arguments.contains("--acceptance-brightness-system-sync") || arguments.contains("--acceptance-brightness-restore") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let result: [String: Any]
                if let index = arguments.firstIndex(of: "--acceptance-brightness-restore"), index + 1 < arguments.count {
                    result = await BrightnessAcceptance.restore(from: arguments[index + 1])
                } else if arguments.contains("--acceptance-brightness-following") {
                    result = await BrightnessAcceptance.runFollowing()
                } else if arguments.contains("--acceptance-brightness-system-sync") {
                    result = await BrightnessAcceptance.runSystemSync()
                } else if arguments.contains("--acceptance-brightness-cycle") || arguments.contains("--acceptance-brightness-blackout") {
                    result = await BrightnessAcceptance.run(includeBlackout: arguments.contains("--acceptance-brightness-blackout"))
                } else {
                    result = ["displays": BrightnessAcceptance.record(await SystemBrightnessHardware(recoverPower: false).discover())]
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) { print(json) }
                exit(result["passed"] as? Bool == false ? 1 : 0)
            }
            app.run()
            return true
        }
        if arguments.contains("--login-item-status") {
            print(LoginItemManager.shared.snapshot.status.rawValue)
            return true
        }
        if arguments.contains("--diagnose") {
            _ = SystemMonitor.shared.sample(fullMetrics: false)
            Thread.sleep(forTimeInterval: 1)
            let m = SystemMonitor.shared.sample(fullMetrics: true)
            print("CPU=\(m.cpuUsage) GPU=\(m.gpuUsage) GPU_CORES=\(m.gpuCoreCount) RAM_USED_GB=\(m.ramUsedGB) RAM_AVAILABLE_GB=\(m.ramFreeGB) RAM_TOTAL_GB=\(m.ramTotalGB) DISK_USED_GB=\(m.diskUsedGB) DISK_TOTAL_GB=\(m.diskTotalGB)")
            return true
        }
        return false
    }

    static func runtimeStatusPath(suffix: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let dir = environment["AETHERSWITCH_RUNTIME_STATUS_DIR"] ?? "/tmp"
        let file = suffix.isEmpty ? "AetherSwitch-runtime.json" : "AetherSwitch-runtime-\(getpid()).json"
        return (dir as NSString).appendingPathComponent(file)
    }

    /// 拒绝向符号链接路径写入状态回执，防止共享临时目录下的符号链接覆盖攻击。
    @discardableResult
    static func writeStatusJSON(_ json: [String: Any], to path: String) -> Bool {
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            return false
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// peak 为 true 时返回进程生命周期内的物理内存峰值，便于定位是哪一步推高了峰值。
    static func physicalFootprintMB(peak: Bool = false) -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(peak ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint) / 1_048_576
    }

    /// Exercise the same switch action as the user, then restore the original registration.
    @MainActor
    static func runLoginItemAcceptance() {
        let manager = LoginItemManager.shared
        manager.refresh()
        let original = manager.snapshot.status
        var results: [String: Any] = ["original": original.rawValue]
        defer {
            manager.setEnabled(original.isEnabled)
            results["restored"] = manager.snapshot.status.rawValue
            let path = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_LOG"] ?? "/tmp/AetherSwitch-login-item.json"
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            NSApp.terminate(nil)
        }
        guard original == .enabled || original == .disabled else { results["error"] = "Login item is unavailable or requires approval"; return }
        let controller = NativePanelController()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let control = descendants(controller.view).compactMap({ $0 as? NSSwitch }).first(where: { $0.accessibilityLabel() == "开机自启动" }) else { results["error"] = "Login switch was not found"; return }
        for enabled in [true, false] {
            control.state = enabled ? .on : .off
            _ = control.target?.perform(control.action, with: control)
            let expected: LoginItemStatus = enabled ? .enabled : .disabled
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--login-item-status"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let freshStatus = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                results[enabled ? "enabled" : "disabled"] = ["system": manager.snapshot.status.rawValue, "freshProcess": freshStatus ?? "missing", "switchOn": control.state == .on]
                guard process.terminationStatus == 0, manager.snapshot.status == expected, freshStatus == expected.rawValue,
                      (control.state == .on) == enabled, manager.snapshot.error == nil else {
                    results["error"] = manager.snapshot.message ?? "System or UI state did not match"
                    return
                }
            } catch { results["error"] = error.localizedDescription; return }
        }
        results["passed"] = true
    }
}
