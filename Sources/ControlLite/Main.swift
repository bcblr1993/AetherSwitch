import Cocoa
import SwiftUI

/// 穿透鼠标事件的 HostingView，让底层的 NSStatusBarButton 原生处理点击与拖动
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 设置为附属模式（隐藏 Dock 栏图标，纯净菜单栏驻留）
        NSApp.setActivationPolicy(.accessory)

        // 2. 初始化 Popover 下拉毛玻璃面板
        let popover = NSPopover()
        popover.contentSize = NSSize(width: AppTheme.panelWidth, height: 440)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView(appState: AppState.shared))
        popover.delegate = self
        self.popover = popover

        // 3. 初始化 NSStatusItem
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            let hosting = PassthroughHostingView(rootView: MenuBarView(appState: AppState.shared))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)

            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])

            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时彻底释放常亮断言
        SwitchManager.shared.releaseKeepAwake()
    }

    // MARK: - 交互事件

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // 右键快捷菜单（退出/刷新）
            showContextMenu(sender)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            AppState.shared.isPopoverOpen = false
        } else {
            AppState.shared.isPopoverOpen = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "ControlLite v1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "刷新数据", action: #selector(refreshAction), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 ControlLite", action: #selector(quitAction), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // 恢复点击行为
    }

    @objc private func refreshAction() {
        AppState.shared.refreshFull()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        AppState.shared.isPopoverOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        AppState.shared.isPopoverOpen = false
    }
}
