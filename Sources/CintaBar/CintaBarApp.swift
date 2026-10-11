import AppKit
import TreadmillKit

@main
enum CintaBarApp {
    static func main() {
        let app = NSApplication.shared
        // Info.plist already marks the app as an agent; this covers `swift run`, which has no bundle.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication doesn't retain its delegate.
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let treadmill: Treadmill
    private var statusMenu: StatusMenuController?

    override init() {
        // `--simulate` swaps Bluetooth for a pretend treadmill, to work on the app without one.
        let link: any TreadmillLink = CommandLine.arguments.contains("--simulate") ? SimulatedLink() : BluetoothLink()
        treadmill = Treadmill(link: link)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController(treadmill: treadmill)
    }

    func applicationWillTerminate(_ notification: Notification) {
        treadmill.disconnect()
    }
}
