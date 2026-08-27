import AppKit

if CommandLine.arguments.contains("--self-test") {
    print("=== Extractor ===")
    let extractorFailures = SelfTest.run()
    print("\n=== Mail parsing ===")
    let mimeFailures = SelfTest.runMIME()
    exit(extractorFailures + mimeFailures == 0 ? 0 : 1)
}

// Connectivity check for troubleshooting: OTPeek --imap-probe imap.gmail.com
if let probeIndex = CommandLine.arguments.firstIndex(of: "--imap-probe") {
    let host = CommandLine.arguments.count > probeIndex + 1
        ? CommandLine.arguments[probeIndex + 1] : "imap.gmail.com"
    let client = IMAPClient(host: host, port: 993)
    do {
        try client.connect()
        print("connected to \(host)")
        print("IDLE supported: \(client.supportsIDLE)")
        print("capabilities: \(client.capabilities.sorted().joined(separator: " "))")
        client.logout()
        exit(0)
    } catch {
        print("failed: \(error.localizedDescription)")
        exit(1)
    }
}

// Documentation screenshots: render the real views with sample data.
let demoModes: [String: DemoMode.Delegate.Mode] = [
    "--demo-hud": .hud, "--demo-settings": .settings,
]
if let flagIndex = CommandLine.arguments.firstIndex(of: "--demo-hit"),
   flagIndex + 1 < CommandLine.arguments.count,
   let which = Int(CommandLine.arguments[flagIndex + 1]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let demoDelegate = DemoMode.Delegate(mode: .single(which))
    app.delegate = demoDelegate
    app.run()
    exit(0)
}
for (flag, mode) in demoModes where CommandLine.arguments.contains(flag) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let demoDelegate = DemoMode.Delegate(mode: mode)
    app.delegate = demoDelegate
    app.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
