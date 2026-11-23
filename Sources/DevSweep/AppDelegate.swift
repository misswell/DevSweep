import AppKit
import Combine
import SwiftUI

/// 主窗口由 SwiftUI `Window` 场景持有；关闭后场景仍在，但视图已不可直接访问。
/// 菜单栏通过这个桥接对象调用 `openWindow(id:)` 重新打开窗口。
@MainActor
final class AppWindowRouter {
    static let shared = AppWindowRouter()

    var openMainWindow: (() -> Void)?

    private init() {}
}

/// 设置窗口由 AppKit 直接托管，不依赖 SwiftUI `Settings` 场景的私有 action。
/// 之前菜单栏发送 `showSettingsWindow:` 在无 Dock / 只有菜单栏入口时会“成功”
/// 却没有任何窗口出现，这里改成真正的 NSWindow，确保菜单栏、Cmd+, 都能打开。
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let services = AppServices.shared
        let root = SettingsView(onClose: { [weak self] in self?.window?.performClose(nil) })
            .environmentObject(services.store)
            .environmentObject(services.updater)
            .environmentObject(services.scheduler)
            .environmentObject(services.presentation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 720))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// 菜单栏图标、应用生命周期和窗口重新打开。
///
/// 使用 NSStatusItem 而不是 `MenuBarExtra`：菜单栏需要在设置里随时开关，
/// 菜单内容也依赖扫描/清理/定时任务的实时状态，AppKit 菜单更直接。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false

        let services = AppServices.shared
        services.presentation.applyActivationPolicy()
        services.presentation.$showMenuBarIcon
            .sink { [weak self] visible in
                self?.syncStatusItem(visible: visible)
            }
            .store(in: &cancellables)
        services.scheduler.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasMainWindow = NSApp.windows.contains { $0.title == "DevSweep" && $0.isVisible }
        if !hasMainWindow {
            openMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    // MARK: - 菜单栏

    private func syncStatusItem(visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DevSweep")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "DevSweep"
            }
            item.menu = menu
            statusItem = item
        } else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let services = AppServices.shared
        let store = services.store
        let scheduler = services.scheduler

        menu.removeAllItems()
        menu.addItem(actionItem("打开 DevSweep", action: #selector(openMainWindow)))

        if store.isScanning {
            let scanning = NSMenuItem(title: "正在扫描…", action: nil, keyEquivalent: "")
            scanning.isEnabled = false
            menu.addItem(scanning)
        } else {
            let scan = actionItem("立即扫描", action: #selector(scanNow))
            scan.isEnabled = !store.isCleaning
            menu.addItem(scan)
        }

        let clean = actionItem(cleanTitle(store: store), action: #selector(cleanQuickCleanNow))
        clean.isEnabled = !store.isCleaning && store.quickCleanEntries.contains(where: \.isAutomatic)
        menu.addItem(clean)

        menu.addItem(.separator())

        if scheduler.isEnabled, let next = scheduler.nextRunAt {
            menu.addItem(infoItem("下次自动清理：\(devSweepShortTimestamp(next))"))
        } else {
            menu.addItem(infoItem("自动清理未开启"))
        }
        if let lastRun = scheduler.lastRunAt {
            menu.addItem(infoItem("上次自动清理：\(devSweepShortTimestamp(lastRun))"))
        }
        if let result = scheduler.lastResult {
            let item = infoItem(result)
            item.toolTip = result
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("设置…", action: #selector(openSettings)))
        menu.addItem(actionItem("退出 DevSweep", action: #selector(quit)))
    }

    private func cleanTitle(store: DevSweepStore) -> String {
        if store.isCleaning {
            return "正在清理常用项…"
        }
        let count = store.quickCleanEntries.filter(\.isAutomatic).count
        return count > 0 ? "清理常用项（\(count) 项）" : "清理常用项"
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 动作

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "DevSweep" && $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            AppWindowRouter.shared.openMainWindow?()
        }
    }

    @objc private func scanNow() {
        AppServices.shared.store.scan()
    }

    @objc private func cleanQuickCleanNow() {
        AppServices.shared.store.cleanAllQuickCleanFromDisk()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
