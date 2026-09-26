import Foundation
import AppKit

/// 自动更新状态
public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String, downloadURL: URL)
    case downloading(progress: Double)
    case readyToRestart(appPath: URL)
    case failed(reason: String)
}

/// 自动检查更新与静默安装管理器
@MainActor
public final class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    @Published public private(set) var status: UpdateStatus = .idle
    @Published public private(set) var currentVersion: String = "1.0.0"

    private let updateCheckURL = URL(string: "https://api.github.com/repos/bcblr1993/AetherSwitch/releases/latest")!

    private init() {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.currentVersion = ver
        }
    }

    /// 检查更新
    public func checkForUpdates(manual: Bool = false) {
        guard status != .checking else { return }
        self.status = .checking

        Task {
            do {
                var request = URLRequest(url: updateCheckURL)
                request.timeoutInterval = 8.0
                request.setValue("AetherSwitch/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
                    // 若 GitHub 仓库未发布 release 或接口返回异常
                    self.status = manual ? .upToDate : .idle
                    return
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    let remoteVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    
                    if isRemoteNewer(current: currentVersion, remote: remoteVer) {
                        // 寻找 dmg 下载资源
                        var downloadURL = URL(string: "https://github.com/bcblr1993/AetherSwitch/releases/latest")!
                        if let assets = json["assets"] as? [[String: Any]] {
                            for asset in assets {
                                if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                                   let browserUrl = asset["browser_download_url"] as? String,
                                   let url = URL(string: browserUrl) {
                                    downloadURL = url
                                    break
                                }
                            }
                        }
                        self.status = .available(version: remoteVer, downloadURL: downloadURL)
                    } else {
                        self.status = .upToDate
                    }
                } else {
                    self.status = manual ? .upToDate : .idle
                }
            } catch {
                self.status = manual ? .upToDate : .idle
            }
        }
    }

    /// 触发自动更新安装流程
    public func downloadAndInstall() {
        guard case .available(_, let url) = status else { return }
        self.status = .downloading(progress: 0.1)

        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AetherSwitchUpdate_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let dmgFile = tempDir.appendingPathComponent("Update.dmg")

                self.status = .downloading(progress: 0.3)
                let (downloadedLocation, _) = try await URLSession.shared.download(from: url)
                try FileManager.default.moveItem(at: downloadedLocation, to: dmgFile)
                self.status = .downloading(progress: 0.8)

                // 挂载 DMG 并提取新版本
                let mountDir = tempDir.appendingPathComponent("Mount")
                let attachTask = Process()
                attachTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                attachTask.arguments = ["attach", dmgFile.path, "-mountpoint", mountDir.path, "-nobrowse", "-quiet"]
                try attachTask.run()
                attachTask.waitUntilExit()

                let sourceApp = mountDir.appendingPathComponent("AetherSwitch.app")
                let stagingApp = tempDir.appendingPathComponent("AetherSwitch.app")
                if FileManager.default.fileExists(atPath: sourceApp.path) {
                    try FileManager.default.copyItem(at: sourceApp, to: stagingApp)
                }

                // 卸载 DMG
                let detachTask = Process()
                detachTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detachTask.arguments = ["detach", mountDir.path, "-quiet"]
                try? detachTask.run()
                detachTask.waitUntilExit()

                // 执行替换与重启脚本
                self.status = .readyToRestart(appPath: stagingApp)
                self.performRestartAndReplace(newAppPath: stagingApp.path)
            } catch {
                self.status = .failed(reason: "下载更新失败，请稍后重试")
            }
        }
    }

    /// 模拟测试用：切换为发现新版本状态
    public func simulateNewVersionForDemo(version: String = "1.0.1") {
        let fakeUrl = URL(string: "https://github.com/bcblr1993/AetherSwitch/releases/download/v\(version)/AetherSwitch-\(version)-arm64.dmg")!
        self.status = .available(version: version, downloadURL: fakeUrl)
    }

    // MARK: - 替换并重启当前应用

    private func performRestartAndReplace(newAppPath: String) {
        guard let currentBundlePath = Bundle.main.bundlePath as String? else { return }
        
        let script = """
        sleep 1
        rm -rf "\(currentBundlePath)"
        cp -R "\(newAppPath)" "\(currentBundlePath)"
        open "\(currentBundlePath)"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApplication.shared.terminate(nil)
    }

    private func isRemoteNewer(current: String, remote: String) -> Bool {
        return remote.compare(current, options: .numeric) == .orderedDescending
    }
}
