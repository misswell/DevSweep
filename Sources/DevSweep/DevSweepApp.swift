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

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(AppServices.shared.scheduler)
                .environmentObject(AppServices.shared.presentation)
        }
    }
}
