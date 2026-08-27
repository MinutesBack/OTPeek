import AppKit

/// The floating panel that shows a code the moment it arrives.
///
/// A non-activating panel on purpose: clicking it copies the code without
/// taking focus, so the login field you were already typing in stays focused
/// and Cmd-V works immediately.
final class HUDPanel: NSObject {

    static let width: CGFloat = 330
    static let height: CGFloat = 148
    private static let margin: CGFloat = 14

    let hit: Hit
    private let settings: HUDSettings
    private weak var manager: HUDManager?

    private var panel: NSPanel!
    private var hint: NSTextField!
    private var progress: ProgressView!
    private var timer: Timer?
    private var remaining: TimeInterval
    private var total: TimeInterval
    fileprivate var hovering = false

    init(hit: Hit, settings: HUDSettings, manager: HUDManager) {
        self.hit = hit
        self.settings = settings
        self.manager = manager
        self.remaining = settings.timeoutSeconds
        self.total = settings.timeoutSeconds
        super.init()
        build()
    }

    // MARK: - Construction

    private func build() {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The text below is drawn white, and .hudWindow follows the system
        // appearance — on a light-mode Mac that would render light-on-light.
        // Pinning the panel to dark keeps it readable either way.
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        let content = ClickableView(frame: frame)
        content.owner = self
        content.addSubview(blur)

        // Source line.
        let source = label(sourceText(), size: 11,
                           color: NSColor.white.withAlphaComponent(0.55))
        source.frame = NSRect(x: Self.margin + 4, y: Self.height - 30,
                              width: Self.width - 60, height: 16)
        content.addSubview(source)

        if let code = hit.code {
            let codeField = label(code, size: 38, color: .white,
                                  font: .monospacedDigitSystemFont(ofSize: 38, weight: .medium))
            codeField.frame = NSRect(x: Self.margin + 2, y: Self.height - 88,
                                     width: Self.width - Self.margin * 2, height: 48)
            content.addSubview(codeField)

            hint = label("Click to copy", size: 12,
                         color: NSColor.white.withAlphaComponent(0.6))
            hint.frame = NSRect(x: Self.margin + 4, y: 26,
                                width: Self.width - Self.margin * 2, height: 18)
            content.addSubview(hint)

            if let link = hit.link {
                let extra = label("⌥-click to open \(host(link))", size: 11,
                                  color: NSColor.white.withAlphaComponent(0.4))
                extra.frame = NSRect(x: Self.margin + 4, y: 10,
                                     width: Self.width - Self.margin * 2, height: 16)
                content.addSubview(extra)
            }
        } else {
            let title = label("Verification link", size: 22, color: .white,
                              font: .systemFont(ofSize: 22, weight: .semibold))
            title.frame = NSRect(x: Self.margin + 2, y: Self.height - 74,
                                 width: Self.width - Self.margin * 2, height: 30)
            content.addSubview(title)

            // Showing the real host matters: it is the only way to tell a
            // genuine activation link from a lookalike.
            let hostField = label(host(hit.link ?? ""), size: 14,
                                  color: NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1),
                                  font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            hostField.frame = NSRect(x: Self.margin + 4, y: Self.height - 98,
                                     width: Self.width - Self.margin * 2, height: 20)
            content.addSubview(hostField)

            hint = label("Click to open  ·  ⌥-click to copy link", size: 12,
                         color: NSColor.white.withAlphaComponent(0.6))
            hint.frame = NSRect(x: Self.margin + 4, y: 16,
                                width: Self.width - Self.margin * 2, height: 18)
            content.addSubview(hint)
        }

        progress = ProgressView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 3))
        content.addSubview(progress)

        panel.contentView = content
        panel.alphaValue = 0
        self.panel = panel
    }

    private func label(_ text: String, size: CGFloat, color: NSColor,
                       font: NSFont? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = color
        field.font = font ?? .systemFont(ofSize: size)
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        return field
    }

    private func sourceText() -> String {
        let icon = hit.source == "email" ? "✉︎" : "💬"
        let who = hit.senderShort.isEmpty ? hit.account : hit.senderShort
        // Naming the mailbox matters when codes arrive across several
        // addresses; for texts the service name adds nothing.
        if hit.source == "email", !hit.account.isEmpty, hit.account != who {
            return String("\(icon)  \(who)  ·  \(hit.account)".prefix(54))
        }
        return String("\(icon)  \(who)".prefix(48))
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? String(url.prefix(34))
    }

    // MARK: - Presentation

    func show(slot: Int) {
        position(slot: slot)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        if settings.playSound { NSSound(named: "Tink")?.play() }

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func position(slot: Int) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.origin.x + visible.width - Self.width - 16
        let y = visible.origin.y + visible.height - Self.height - 12
              - CGFloat(slot) * (Self.height + 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func tick() {
        // Hovering pauses the countdown so there is time to read it.
        if !hovering { remaining -= 0.1 }
        progress.fraction = total > 0 ? remaining / total : 0
        if remaining <= 0 { dismiss() }
    }

    // MARK: - Interaction

    fileprivate func handleClick(option: Bool) {
        if let code = hit.code, !option {
            copy(code)
            flash("Copied — press ⌘V")
        } else if let link = hit.link, let code = hit.code, option, !code.isEmpty {
            open(link)
        } else if let link = hit.link, !option {
            open(link)
        } else if let link = hit.link, option {
            copy(link)
            flash("Link copied")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func open(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
        flash("Opening…")
    }

    private func flash(_ message: String) {
        hint.stringValue = message
        hint.textColor = NSColor(calibratedRed: 0.5, green: 0.95, blue: 0.6, alpha: 1)
        remaining = min(remaining, 1.6)
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        manager?.remove(self)
    }
}

// MARK: - Views

private final class ClickableView: NSView {
    weak var owner: HUDPanel?

    override func mouseDown(with event: NSEvent) {
        owner?.handleClick(option: event.modifierFlags.contains(.option))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { owner?.hovering = true }
    override func mouseExited(with event: NSEvent) { owner?.hovering = false }
}

/// Thin countdown line along the bottom edge.
private final class ProgressView: NSView {
    var fraction: Double = 1 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
        bounds.fill()
        NSColor(calibratedRed: 0.42, green: 0.72, blue: 1, alpha: 0.85).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(1, fraction))),
               height: bounds.height).fill()
    }
}

/// Keeps popups stacked without overlapping.
final class HUDManager {
    private var active: [HUDPanel] = []
    private let settings: HUDSettings

    init(settings: HUDSettings) {
        self.settings = settings
    }

    func present(_ hit: Hit) {
        if active.count >= 4 { active.first?.dismiss() }
        let panel = HUDPanel(hit: hit, settings: settings, manager: self)
        active.append(panel)
        panel.show(slot: active.count - 1)
    }

    func remove(_ panel: HUDPanel) {
        active.removeAll { $0 === panel }
        for (index, remaining) in active.enumerated() { remaining.position(slot: index) }
    }
}
