import AppKit

/// Renders the interface with sample data so documentation screenshots can be
/// captured from the real views rather than mocked up.
///
///     OTPeek --demo-hud       the popups
///     OTPeek --demo-settings  the settings window
enum DemoMode {

    static let sampleHits: [Hit] = [
        Hit(code: "482913", link: "https://accounts.google.com/verify/abc",
            source: "sms", account: "SMS", sender: "Google", senderShort: "Google",
            subject: "", received: Date(), confidence: 0.9),
        Hit(code: nil, link: "https://linear.app/auth/magic?token=xyz789abcdef",
            source: "email", account: "Work Gmail", sender: "Linear",
            senderShort: "Linear", subject: "Sign in", received: Date(), confidence: 1.0),
    ]

    final class Delegate: NSObject, NSApplicationDelegate {
        enum Mode { case hud, settings }

        private let mode: Mode
        private var hudManager: HUDManager?
        private var backdrop: NSWindow?
        private var settingsController: SettingsWindowController?

        init(mode: Mode) {
            self.mode = mode
            super.init()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            switch mode {
            case .hud:
                // The popups use translucent HUD material, so on their own they
                // take on whatever is behind them. A controlled backdrop makes
                // documentation screenshots reproducible instead of dependent
                // on whatever happened to be on screen.
                backdrop = Self.makeBackdrop()
                let manager = HUDManager(settings: HUDSettings(autoCopy: false,
                                                               timeoutSeconds: 120,
                                                               playSound: false))
                sampleHits.forEach { manager.present($0) }
                hudManager = manager

            case .settings:
                let controller = SettingsWindowController(onSaved: {})
                controller.show()
                settingsController = controller
            }
        }

        private static func makeBackdrop() -> NSWindow? {
            guard let screen = NSScreen.main else { return nil }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            // Above ordinary windows, below the popups themselves.
            window.level = NSWindow.Level(rawValue: 20)
            window.isOpaque = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let view = GradientView(frame: screen.frame)
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
    }

    /// Plain diagonal wash, so captured popups sit on a predictable ground.
    final class GradientView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.99, alpha: 1),
                NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.93, alpha: 1),
            ])
            gradient?.draw(in: bounds, angle: -60)
        }
    }
}
