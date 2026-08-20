import SwiftUI

@main
struct DevSweepApp: App {
    @StateObject private var store = DevSweepStore()
    @StateObject private var updater = DevSweepSoftwareUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(updater)
        }
        .windowResizability(.contentSize)

        Settings {
            HelpView()
                .environmentObject(updater)
        }
    }
}
