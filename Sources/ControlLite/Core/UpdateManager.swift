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
        if Bundle.main.bundleIdentifier == "com.aethernative.aetherswitch",
           let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.currentVersion = ver
        } else {
            self.currentVersion = "1.0.0"
        }
    }

    public func setVersionForSnapshot(version: String = "1.0.0", status: UpdateStatus = .upToDate) {
        self.currentVersion = version
        self.status = status
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
                    self.status = manual ? .failed(reason: "暂时无法检查更新，请稍后重试") : .idle
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
                    self.status = manual ? .failed(reason: "暂时无法检查更新，请稍后重试") : .idle
                }
            } catch {
                self.status = manual ? .failed(reason: "暂时无法检查更新，请稍后重试") : .idle
            }
        }
    }

    /// 触发自动更新安装流程
    public func downloadAndInstall() {
        guard case .available(_, let url) = status else { return }
        // 由系统浏览器下载签名安装包，避免未经验证的脚本覆盖当前应用。
        NSWorkspace.shared.open(url)
    }

    /// 模拟测试用：切换为发现新版本状态
    public func simulateNewVersionForDemo(version: String = "1.0.1") {
        let fakeUrl = URL(string: "https://github.com/bcblr1993/AetherSwitch/releases/download/v\(version)/AetherSwitch-\(version)-arm64.dmg")!
        self.status = .available(version: version, downloadURL: fakeUrl)
    }

    private func isRemoteNewer(current: String, remote: String) -> Bool {
        return remote.compare(current, options: .numeric) == .orderedDescending
    }
}
