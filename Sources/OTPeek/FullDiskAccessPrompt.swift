import AppKit

/// Invites the user to grant Full Disk Access, and takes them to it.
///
/// macOS never asks for this permission on its own — it simply denies the
/// read — so without an invitation people never discover that texts are the
/// half of the app that is missing. The flow deliberately ends with a restart
/// button, because the permission is only picked up when the process starts.
enum FullDiskAccessPrompt {

    private static var shownThisLaunch = false

    /// Shows the invitation once per launch, unless it was dismissed for good.
    static func presentIfNeeded() {
        guard !shownThisLaunch else { return }
        guard !SettingsStore.shared.settings.declinedFullDiskAccess else { return }
        shownThisLaunch = true
        present(invitedAutomatically: true)
    }

    /// Shown directly from the menu item, ignoring any earlier dismissal.
    static func presentFromMenu() {
        shownThisLaunch = true
        present(invitedAutomatically: false)
    }

    private static func present(invitedAutomatically: Bool) {
        // An .accessory app cannot reliably put a window in front, so become a
        // regular app for as long as the invitation is up.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Let OTPeek catch the codes your phone receives"
        alert.informativeText = """
            Most one-time codes arrive by text. To read the ones your iPhone \
            forwards to this Mac, OTPeek needs Full Disk Access — the permission \
            macOS uses to protect your Messages history.

            Your messages are read on this Mac and never sent anywhere.

            Opening Settings takes you straight there, with OTPeek revealed in \
            Finder to drag in.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if invitedAutomatically {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }

        let response = alert.runModal()

        if invitedAutomatically, alert.suppressionButton?.state == .on {
            SettingsStore.shared.update { $0.declinedFullDiskAccess = true }
            Log.write("[ok] full disk access invitation dismissed for good")
        }

        guard response == .alertFirstButtonReturn else {
            NSApp.setActivationPolicy(previousPolicy)
            return
        }

        openSettingsPane()
        awaitReturn(previousPolicy: previousPolicy)
    }

    private static func openSettingsPane() {
        // Reveal first, so Finder ends up behind Settings rather than in front
        // of it — otherwise the Applications folder is all you see.
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])

        // Ventura renamed this pane. The old identifier still "opens"
        // successfully but lands nowhere, so the modern one is tried first and
        // the legacy one is only a fallback for older systems.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                Log.write("[ok] opened Full Disk Access settings")
                return
            }
        }
        Log.write("[error] could not open the Full Disk Access pane")
    }

    /// The permission is read at process start, so offer the restart directly.
    private static func awaitReturn(previousPolicy: NSApplication.ActivationPolicy) {
        let follow = NSAlert()
        follow.messageText = "Added OTPeek to the list?"
        follow.informativeText = """
            Switch on OTPeek under Full Disk Access, then restart it here. \
            macOS only applies the permission when the app starts.
            """
        follow.alertStyle = .informational
        follow.addButton(withTitle: "Restart OTPeek")
        follow.addButton(withTitle: "Later")

        if follow.runModal() == .alertFirstButtonReturn {
            restart()
        } else {
            NSApp.setActivationPolicy(previousPolicy)
        }
    }

    private static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let bundle = Bundle.main.bundleURL
        Log.write("[ok] restarting to pick up Full Disk Access")
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
