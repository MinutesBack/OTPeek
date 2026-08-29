import AppKit
import SwiftUI

/// Hosts the settings UI. Everything a user needs to configure OTPeek lives
/// here — there is deliberately no command line step.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var model: SettingsModel?
    private var pendingAddSheet = false
    private let onSaved: () -> Void

    init(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        super.init()
    }

    func show(openingAddSheet: Bool = false) {
        if window == nil {
            let model = SettingsModel(onSaved: onSaved)
            self.pendingAddSheet = openingAddSheet
            self.model = model
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "OTPeek Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 400))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        // A menu bar app runs as .accessory, which cannot reliably bring a
        // window to the front or give it keyboard focus — the window would
        // open behind everything, or not appear at all. Becoming a regular
        // app for as long as a window is open fixes both, and gives the
        // window a Dock icon and Cmd-Tab entry while it is up.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        if pendingAddSheet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.model?.showingAdd = true
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var accounts: [Account]
    @Published var smsEnabled: Bool
    @Published var timeoutSeconds: Double
    @Published var playSound: Bool
    @Published var autoCopy: Bool
    @Published var showingAdd = false

    private let onSaved: () -> Void

    init(onSaved: @escaping () -> Void) {
        let settings = SettingsStore.shared.settings
        accounts = settings.accounts
        smsEnabled = settings.smsEnabled
        timeoutSeconds = settings.hud.timeoutSeconds
        playSound = settings.hud.playSound
        autoCopy = settings.hud.autoCopy
        self.onSaved = onSaved
    }

    func persist() {
        SettingsStore.shared.update { settings in
            settings.accounts = accounts
            settings.smsEnabled = smsEnabled
            settings.hud.timeoutSeconds = timeoutSeconds
            settings.hud.playSound = playSound
            settings.hud.autoCopy = autoCopy
        }
        onSaved()
    }

    func add(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        persist()
    }

    func remove(_ account: Account) {
        Keychain.delete(account.id)
        Keychain.delete(MicrosoftOAuth.refreshKey(account.id))
        accounts.removeAll { $0.id == account.id }
        persist()
    }
}

// MARK: - Main view

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mailboxes")
                .font(.headline)

            if model.accounts.isEmpty {
                HStack {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("No mailboxes yet. Add one to catch codes from email.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else {
                List {
                    ForEach(model.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.label)
                                Text(account.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { model.remove(account) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: 140)
                .border(Color.secondary.opacity(0.2))
            }

            Button {
                model.showingAdd = true
            } label: {
                Label("Add mailbox", systemImage: "plus")
            }

            Divider()

            Toggle("Watch text messages from my iPhone", isOn: $model.smsEnabled)
                .onChange(of: model.smsEnabled) { _, _ in model.persist() }
            Text("Requires Full Disk Access, and Text Message Forwarding enabled on the iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Popup")
                .font(.headline)

            HStack {
                Text("Stays for")
                Slider(value: $model.timeoutSeconds, in: 10...120, step: 5)
                    .frame(width: 200)
                Text("\(Int(model.timeoutSeconds))s")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
            }
            .onChange(of: model.timeoutSeconds) { _, _ in model.persist() }

            Toggle("Play a sound", isOn: $model.playSound)
                .onChange(of: model.playSound) { _, _ in model.persist() }
            Toggle("Copy the code automatically, without clicking", isOn: $model.autoCopy)
                .onChange(of: model.autoCopy) { _, _ in model.persist() }

            Spacer()
        }
        .padding(20)
        .frame(width: 560)
        .sheet(isPresented: $model.showingAdd) {
            AddAccountView(model: model)
        }
    }
}

// MARK: - Add account

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Coloured initial standing in for the provider.
///
/// Deliberately not the real Gmail or Outlook logo: shipping trademarked marks
/// in an open-source app, next to a password field, would imply an endorsement
/// that does not exist. A monogram in the provider's own colour gives the same
/// at-a-glance recognition without pretending to be them.
///
/// Drawn to an NSImage rather than composed in SwiftUI because AppKit menus
/// render images but not arbitrary SwiftUI shapes.
enum ProviderMark {
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: Provider, size: CGFloat = 18) -> NSImage {
        let key = "\(provider.key)-\(Int(size))"
        if let cached = cache[key] { return cached }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: size * 0.3, yRadius: size * 0.3).setClip()
            nsColor(provider.tintHex).setFill()
            rect.fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.62, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let text = provider.monogram as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (size - textSize.width) / 2,
                                  y: (size - textSize.height) / 2),
                      withAttributes: attributes)
            return true
        }
        cache[key] = image
        return image
    }

    private static func nsColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

struct AddAccountView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    @State private var providerIndex = 0
    @State private var email = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var clientID = ""
    @State private var tenant = "common"

    @State private var explaining = true
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var deviceCode: MicrosoftOAuth.DeviceCodeChallenge?

    private var provider: Provider { Provider.all[providerIndex] }
    private var isMicrosoft: Bool { provider.auth == .xoauth2 }
    private var isCustom: Bool { provider.key == "custom" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a mailbox").font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerPicker
                    credentials
                    explainer
                    reassurance
                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(failed ? Color.red : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 1)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(isMicrosoft ? "Sign in with Microsoft" : "Check and save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || email.isEmpty || (!isMicrosoft && password.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480, height: 560)
        .onAppear { syncProviderDefaults() }
    }

    // MARK: Sections

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider").font(.subheadline).foregroundStyle(.secondary)
            Menu {
                ForEach(Array(Provider.all.enumerated()), id: \.offset) { index, item in
                    Button {
                        providerIndex = index
                        syncProviderDefaults()
                    } label: {
                        Label {
                            Text(item.label)
                        } icon: {
                            Image(nsImage: ProviderMark.image(for: item))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: ProviderMark.image(for: provider, size: 20))
                    Text(provider.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(provider.help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Email address", help: "The address codes are sent to.") {
                TextField("you@example.com", text: $email)
            }

            if isCustom {
                field("IMAP server", help: "Your provider's help pages list this.") {
                    TextField("imap.example.com", text: $host)
                }
                field("Port", help: nil) { TextField("993", text: $port) }
            }

            if isMicrosoft {
                field("Application (client) ID",
                      help: "From the free app registration — the guide is linked below.") {
                    TextField("00000000-0000-0000-0000-000000000000", text: $clientID)
                }
                field("Tenant", help: nil) { TextField("common", text: $tenant) }

                if let challenge = deviceCode {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Enter this code in the browser window that just opened:")
                                .font(.callout)
                            Text(challenge.userCode)
                                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Open Microsoft sign-in again") {
                                if let url = URL(string: challenge.verificationURI) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                field(provider.needsAppPassword ? "App password" : "Password",
                      help: provider.needsAppPassword
                          ? "16 characters from \(shortName). Not the password you normally type."
                          : nil) {
                    SecureField("", text: $password)
                }
            }
        }
    }

    @ViewBuilder
    private var explainer: some View {
        if !provider.why.isEmpty {
            DisclosureGroup(isExpanded: $explaining) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(provider.why)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(provider.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(step)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let credentialURL = provider.credentialURL,
                       let url = URL(string: credentialURL) {
                        Button("Open \(shortName) to create one") {
                            NSWorkspace.shared.open(url)
                        }
                        .padding(.top, 2)
                    }
                    if isMicrosoft,
                       let guide = URL(string: "https://github.com/MinutesBack/OTPeek#outlook--microsoft-365") {
                        Button("Open the setup guide") { NSWorkspace.shared.open(guide) }
                            .padding(.top, 2)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(isMicrosoft
                     ? "Why does this need a browser sign-in?"
                     : "Why not my normal password?")
                    .font(.callout)
            }
        }
    }

    private var reassurance: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)
            Text("Saved in your Mac's Keychain and sent only to \(isCustom ? "your mail server" : shortName). "
                 + "OTPeek has no server of its own, so nothing is sent anywhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    /// "Gmail / Google Workspace" reads badly mid-sentence.
    private var shortName: String {
        provider.label.split(separator: "/").first?
            .trimmingCharacters(in: .whitespaces) ?? provider.label
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, help: String?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func syncProviderDefaults() {
        host = provider.host
        port = String(provider.port)
        message = nil
        failed = false
        deviceCode = nil
        explaining = !provider.why.isEmpty
    }

    /// Every account is checked against the real server before it is saved, so
    /// a wrong password surfaces here rather than as silence later.
    private func submit() {
        busy = true
        message = nil
        failed = false

        let accountID = email.replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        var account = Account(
            id: accountID, label: email, user: email,
            host: isCustom ? host : provider.host,
            port: Int(port) ?? 993, auth: provider.auth, folder: "INBOX")

        if isMicrosoft {
            account.clientID = clientID
            account.tenant = tenant.isEmpty ? "common" : tenant
        }

        let secret = password
        DispatchQueue.global().async {
            do {
                let token: String
                if isMicrosoft {
                    let challenge = try MicrosoftOAuth.beginDeviceFlow(
                        clientID: account.clientID ?? "", tenant: account.tenant ?? "common")
                    DispatchQueue.main.async {
                        deviceCode = challenge
                        message = "Waiting for you to approve it in the browser…"
                        if let url = URL(string: challenge.verificationURI) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    token = try MicrosoftOAuth.completeDeviceFlow(
                        challenge: challenge, clientID: account.clientID ?? "",
                        tenant: account.tenant ?? "common", accountID: account.id,
                        shouldCancel: { false })
                } else {
                    token = secret
                }

                let push = try NetworkPolicy.whileVerifying(account.host) { () -> Bool in
                    let client = IMAPClient(host: account.host, port: account.port)
                    try client.connect()
                    if isMicrosoft {
                        try client.authenticateXOAUTH2(user: account.user, token: token)
                    } else {
                        try client.login(user: account.user, password: token)
                    }
                    try client.select(account.folder)
                    let supportsPush = client.supportsIDLE
                    client.logout()
                    return supportsPush
                }

                if !isMicrosoft { _ = Keychain.set(secret, for: account.id) }

                DispatchQueue.main.async {
                    busy = false
                    model.add(account)
                    message = push ? "Connected. Codes will arrive instantly."
                                   : "Connected. Checking every 15 seconds."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { dismiss() }
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    failed = true
                    deviceCode = nil
                    explaining = true      // the answer is almost always in here
                    message = error.localizedDescription
                }
            }
        }
    }
}
