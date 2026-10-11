import SwiftUI

@main
struct CintaBarApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            TreadmillMenu(treadmill: delegate.treadmill)
        } label: {
            MenuBarLabel(treadmill: delegate.treadmill)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here rather than by a view so the connection starts at launch, not when the menu
    // first opens.
    let treadmill = Treadmill()

    func applicationWillTerminate(_ notification: Notification) {
        treadmill.disconnect()
    }
}
