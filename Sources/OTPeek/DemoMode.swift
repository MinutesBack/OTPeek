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
            source: "email", account: "Personal Gmail", sender: "Linear",
            senderShort: "Linear", subject: "Sign in", received: Date(), confidence: 1.0),
        Hit(code: "728193", link: nil,
            source: "email", account: "Work Gmail", sender: "Stripe",
            senderShort: "Stripe", subject: "", received: Date(), confidence: 0.9),
        Hit(code: "947201", link: nil,
            source: "email", account: "Outlook", sender: "Microsoft",
            senderShort: "Microsoft", subject: "", received: Date(), confidence: 0.9),
        Hit(code: nil, link: "https://www.notion.so/activate/9f2b1c7ade",
            source: "email", account: "iCloud", sender: "Notion",
            senderShort: "Notion", subject: "Activate", received: Date(), confidence: 1.0),
        Hit(code: "55712", link: nil,
            source: "sms", account: "SMS", sender: "Qonto", senderShort: "Qonto",
            subject: "", received: Date(), confidence: 0.9),
    ]

    final class Delegate: NSObject, NSApplicationDelegate {
        enum Mode: Equatable { case hud, settings, addSheet, single(Int) }

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
            case .single(let index):
                backdrop = Self.makeBackdrop()
                let manager = HUDManager(settings: HUDSettings(autoCopy: false,
                                                               timeoutSeconds: 300,
                                                               playSound: false))
                if index < sampleHits.count { manager.present(sampleHits[index]) }
                hudManager = manager

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

            case .settings, .addSheet:
                let controller = SettingsWindowController(onSaved: {})
                controller.show(openingAddSheet: mode == .addSheet)
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
