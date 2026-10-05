import SwiftUI

@main
struct CamerAppApp: App {
    init() {
        Diagnostics.installCrashHandler()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
