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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
