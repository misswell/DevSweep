import SwiftUI

@main
struct DevSweepApp: App {
    @StateObject private var store = DevSweepStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)

        Settings {
            HelpView()
        }
    }
}
