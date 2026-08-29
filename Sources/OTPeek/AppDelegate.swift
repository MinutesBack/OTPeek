import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The same code arriving twice inside this window is one event: providers
    /// often send the SMS and the email together.
    private static let dedupeSeconds: TimeInterval = 90

    private var statusItem: NSStatusItem!
    var menu = NSMenu()
    var hudManager: HUDManager!

    private var messagesWatcher: MessagesWatcher?
    private var imapWatchers: [IMAPWatcher] = []

    var history: [Hit] = []
    var statuses: [(key: String, state: SourceState, detail: String)] = []
    private var recentHits: [String: Date] = [:]

    private var settingsController: SettingsWindowController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        hudManager = HUDManager(settings: SettingsStore.shared.settings.hud)
        buildStatusItem()

        let settings = SettingsStore.shared.settings
        Log.write("[ok] OTPeek launched — "
                  + "\(settings.accounts.count) mailbox(es), "
                  + "sms \(settings.smsEnabled ? "on" : "off"), "
                  + "bundle \(Bundle.main.bundleURL.path)")

        startWatchers()

        // First run with nothing configured is a dead end otherwise.
        if SettingsStore.shared.settings.accounts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.openSettings(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatchers()
    }

    /// Clicking the app in Finder, Spotlight or the Dock while it is already
    /// running previously did nothing at all: a menu bar app has no Dock icon
    /// and no window, so there was no feedback that it was running. Show
    /// settings instead.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openSettings(nil)
        return true
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "key.horizontal.fill",
                                accessibilityDescription: "OTPeek")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "🔑" }
        }
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil,
                     key: String = "", enabled: Bool = true,
                     represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == nil ? nil : self
        item.isEnabled = enabled && action != nil
        item.representedObject = represented
        menu.addItem(item)
        return item
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let settings = SettingsStore.shared.settings

        if !history.isEmpty {
            add("Recent", enabled: false)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for hit in history.prefix(settings.historySize) {
                var label = hit.code ?? hit.link ?? ""
                if hit.code == nil { label = "link · " + String(label.prefix(44)) }
                let who = String((hit.senderShort.isEmpty ? hit.account : hit.senderShort).prefix(22))
                add("  \(label)   —   \(who)  \(formatter.string(from: hit.received))",
                    #selector(copyHistoryItem(_:)), represented: hit.code ?? hit.link ?? "")
            }
            menu.addItem(.separator())
        }

        add("Sources", enabled: false)
        if statuses.isEmpty {
            add("  starting…", enabled: false)
        }
        for status in statuses.sorted(by: { $0.key < $1.key }) {
            let dot = status.state == .ok ? "●" : (status.state == .connecting ? "◌" : "○")
            add("  \(dot)  \(String(status.detail.prefix(58)))", enabled: false)
        }

        menu.addItem(.separator())
        add("Test popup", #selector(testPopup(_:)))
        if statuses.contains(where: { $0.state == .error && $0.detail.contains("Full Disk Access") }) {
            add("⚠️  Grant Full Disk Access…", #selector(grantFullDiskAccess(_:)))
        }
        add("Settings…", #selector(openSettings(_:)), key: ",")
        add("Reconnect all", #selector(reconnect(_:)))
        add("Open log", #selector(openLog(_:)))

        menu.addItem(.separator())
        let loginItem = add("Start at login", #selector(toggleLaunchAtLogin(_:)))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("Quit OTPeek", #selector(quit(_:)), key: "q")
    }

    // MARK: - Watchers

    private func startWatchers() {
        let settings = SettingsStore.shared.settings

        if settings.smsEnabled {
            let watcher = MessagesWatcher(
                maxAgeMinutes: settings.maxAgeMinutes,
                onMessage: { [weak self] message in self?.deliver(message) },
                onStatus: { [weak self] key, state, detail in
                    self?.updateStatus(key, state, detail)
                })
            watcher.start()
            messagesWatcher = watcher
        }

        for account in settings.accounts {
            let watcher = IMAPWatcher(
                account: account,
                maxAgeMinutes: settings.maxAgeMinutes,
                credentialProvider: { account in
                    switch account.auth {
                    case .password: return Keychain.get(account.id)
                    case .xoauth2: return MicrosoftOAuth.accessToken(for: account)
                    }
                },
                onMessage: { [weak self] message in self?.deliver(message) },
                onStatus: { [weak self] key, state, detail in
                    self?.updateStatus(key, state, detail)
                })
            watcher.start()
            imapWatchers.append(watcher)
        }

        if settings.accounts.isEmpty && !settings.smsEnabled {
            updateStatus("setup", .error, "Nothing to watch — open Settings")
        }
    }

    private func stopWatchers() {
        messagesWatcher?.stop()
        messagesWatcher = nil
        imapWatchers.forEach { $0.stop() }
        imapWatchers = []
    }

    // MARK: - Message handling

    private func updateStatus(_ key: String, _ state: SourceState, _ detail: String) {
        Log.write("[\(state.rawValue)] \(key): \(detail)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let index = self.statuses.firstIndex(where: { $0.key == key }) {
                self.statuses[index] = (key, state, detail)
            } else {
                self.statuses.append((key, state, detail))
            }
            self.rebuildMenu()

            if key == "sms", state == .error, detail.contains("Full Disk Access") {
                // Let the menu bar item appear first, so the invitation has
                // something to point at.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    FullDiskAccessPrompt.presentIfNeeded()
                }
            }
        }
    }

    private func deliver(_ message: IncomingMessage) {
        DispatchQueue.main.async { [weak self] in self?.handle(message) }
    }

    private func handle(_ message: IncomingMessage) {
        var result = Extractor.analyze(subject: message.subject, body: message.body,
                                       isHTML: message.isHTML, sender: message.sender)
        // HTML-only mail sometimes hides the code in the plain-text alternative.
        if result.kind == .none, let plain = message.plainAlternative, !plain.isEmpty {
            result = Extractor.analyze(subject: message.subject, body: plain,
                                       isHTML: false, sender: message.sender)
        }
        guard result.kind != .none else { return }

        let key = result.code ?? result.link ?? ""
        let now = Date()
        recentHits = recentHits.filter { now.timeIntervalSince($0.value) < Self.dedupeSeconds }
        if recentHits[key] != nil { return }
        recentHits[key] = now

        let hit = Hit(code: result.code, link: result.link,
                      source: message.source, account: message.account,
                      sender: message.sender, senderShort: Self.shortSender(message.sender),
                      subject: message.subject, received: message.received,
                      confidence: result.confidence)

        history.insert(hit, at: 0)
        let limit = SettingsStore.shared.settings.historySize
        if history.count > limit { history.removeLast(history.count - limit) }

        if SettingsStore.shared.settings.hud.autoCopy, let code = result.code {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }

        Log.write("hit \(message.source) from \(hit.senderShort): "
                  + "\(result.code.map { "code " + $0 } ?? "link") "
                  + String(format: "(confidence %.2f)", result.confidence))

        hudManager.present(hit)
        rebuildMenu()
    }

    private static func shortSender(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let match = raw.range(of: #"^\s*"?([^"<]+?)"?\s*<"#, options: .regularExpression) {
            let inner = raw[match]
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: "\"", with: "")
            return inner.trimmingCharacters(in: .whitespaces)
        }
        return String(raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).prefix(40))
    }

    // MARK: - Actions

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func testPopup(_ sender: Any?) {
        hudManager.present(Hit(code: "482913", link: nil, source: "sms",
                               account: "Messages", sender: "OTPeek",
                               senderShort: "OTPeek test", subject: "",
                               received: Date(), confidence: 1))
    }

    @objc private func grantFullDiskAccess(_ sender: Any?) {
        FullDiskAccessPrompt.presentFromMenu()
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController { [weak self] in self?.reconnect(nil) }
        }
        settingsController?.show()
    }

    @objc private func reconnect(_ sender: Any?) {
        stopWatchers()
        statuses = []
        SettingsStore.shared.reload()
        startWatchers()
        rebuildMenu()
    }

    @objc private func openLog(_ sender: Any?) {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("[error] launch at login: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quit(_ sender: Any?) {
        stopWatchers()
        NSApplication.shared.terminate(nil)
    }
}
