import AppKit

private let petBundleID = "com.alanzhu.claude-desktop-pet"
private let quitNotification = Notification.Name(petBundleID + ".quit")

private final class PetAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?
    private var monitor: ActivityMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let resources = Bundle.main.resourceURL else {
            NSApplication.shared.terminate(nil)
            return
        }
        let pet = PetController(resources: resources)
        controller = pet
        pet.start()
        let activity = ActivityMonitor { [weak pet] state, text in
            pet?.applyActivity(state: state, text: text)
        }
        monitor = activity
        activity.start()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quitRequested), name: quitNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func quitRequested(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}

@main
private enum PetMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-test"] {
            do {
                guard let resources = Bundle.main.resourceURL else {
                    throw NSError(domain: petBundleID, code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing app resources"])
                }
                try PetController.selfTest(resources: resources)
                try ActivityMonitor.selfTest()
                print("PASS: 11 animated expressions, unchanged artwork, transparent redraw, hover and gestures, temporary/pinned/random selections, free idle and activity following, slow-tick idle scheduling, and task supersession fixtures")
            } catch {
                fputs("Self-test failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        if arguments == ["--quit"] {
            DistributedNotificationCenter.default().postNotificationName(quitNotification, object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        guard arguments.isEmpty else {
            fputs("Usage: ClaudeDesktopPet [--self-test | --quit]\n", stderr)
            exit(2)
        }
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: petBundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard otherInstances.isEmpty else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = PetAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
