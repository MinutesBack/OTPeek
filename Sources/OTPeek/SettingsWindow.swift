import AppKit
import SwiftUI

/// Hosts the settings UI. Everything a user needs to configure OTPeek lives
/// here — there is deliberately no command line step.
final class SettingsWindowController {

    private var window: NSWindow?
    private let onSaved: () -> Void

    init(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
    }

    func show() {
        if window == nil {
            let model = SettingsModel(onSaved: onSaved)
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "OTPeek Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

struct AddAccountView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    @State private var providerIndex = 0
    @State private var email = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var label = ""
    @State private var clientID = ""
    @State private var tenant = "common"

    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var deviceCode: MicrosoftOAuth.DeviceCodeChallenge?

    private var provider: Provider { Provider.all[providerIndex] }
    private var isMicrosoft: Bool { provider.auth == .xoauth2 }
    private var isCustom: Bool { provider.key == "custom" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a mailbox")
                .font(.headline)

            Picker("Provider", selection: $providerIndex) {
                ForEach(Array(Provider.all.enumerated()), id: \.offset) { index, item in
                    Text(item.label).tag(index)
                }
            }
            .onChange(of: providerIndex) { _, _ in
                host = provider.host
                port = String(provider.port)
                message = nil
            }

            Text(provider.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Email address", text: $email)

            if isCustom {
                TextField("IMAP host", text: $host)
                TextField("Port", text: $port)
            }

            if isMicrosoft {
                TextField("Application (client) ID", text: $clientID)
                TextField("Tenant", text: $tenant)
                Link("How do I get a client ID?",
                     destination: URL(string: "https://github.com/JMax92/OTPeek#outlook--microsoft-365")!)
                    .font(.caption)

                if let challenge = deviceCode {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Enter this code in your browser:")
                                .font(.caption)
                            Text(challenge.userCode)
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Open Microsoft sign-in") {
                                if let url = URL(string: challenge.verificationURI) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                SecureField("App password", text: $password)
                if let credentialURL = provider.credentialURL, let url = URL(string: credentialURL) {
                    Link("Create an app password", destination: url)
                        .font(.caption)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(failed ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(isMicrosoft ? "Sign in and save" : "Test and save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || email.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: isMicrosoft ? 500 : 400)
        .onAppear {
            host = provider.host
            port = String(provider.port)
        }
    }

    /// Every account is verified against the real server before it is saved,
    /// so a wrong password surfaces here rather than as silence later.
    private func submit() {
        busy = true
        message = nil
        failed = false

        let accountID = email.replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        var account = Account(
            id: accountID,
            label: label.isEmpty ? email : label,
            user: email,
            host: isCustom ? host : provider.host,
            port: Int(port) ?? 993,
            auth: provider.auth,
            folder: "INBOX")

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
                        message = "Waiting for you to approve in the browser…"
                    }
                    if let url = URL(string: challenge.verificationURI) {
                        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    }
                    token = try MicrosoftOAuth.completeDeviceFlow(
                        challenge: challenge, clientID: account.clientID ?? "",
                        tenant: account.tenant ?? "common", accountID: account.id,
                        shouldCancel: { false })
                } else {
                    token = secret
                }

                let client = IMAPClient(host: account.host, port: account.port)
                try client.connect()
                if isMicrosoft {
                    try client.authenticateXOAUTH2(user: account.user, token: token)
                } else {
                    try client.login(user: account.user, password: token)
                }
                try client.select(account.folder)
                let push = client.supportsIDLE
                client.logout()

                if !isMicrosoft { _ = Keychain.set(secret, for: account.id) }

                DispatchQueue.main.async {
                    busy = false
                    model.add(account)
                    message = push ? "Connected — push enabled" : "Connected (polling)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    failed = true
                    deviceCode = nil
                    message = error.localizedDescription
                }
            }
        }
    }
}
