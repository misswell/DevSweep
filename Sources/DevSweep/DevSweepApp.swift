import SwiftUI

@main
struct DevSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppServices.shared.store
    @StateObject private var updater = AppServices.shared.updater

    var body: some Scene {
        Window("DevSweep", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(AppServices.shared.scheduler)
                .environmentObject(AppServices.shared.presentation)
        }
        .windowResizability(.contentSize)
        .commands {
            // 设置窗口由 AppKit 托管；这里只负责替换系统“设置…”菜单和 Cmd+,。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
