import Foundation

/// Tests for the network gate.
///
/// The promise that a downloaded copy cannot send your mail password anywhere
/// is only worth something if it is checked, so the refusal path is tested the
/// same way the extractor is.
extension SelfTest {

    static func runSecurity() -> Int {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            print("[\(condition ? "PASS" : "FAIL")] \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(detail)")
            if !condition { failures.append("  \(name): \(detail)") }
        }

        // An arbitrary host must be refused outright.
        var refused = false
        do {
            try NetworkPolicy.check("unexpected-host.example.invalid")
        } catch {
            refused = true
        }
        check("unknown host refused", refused, refused ? "" : "connection was allowed")

        // Microsoft's sign-in endpoint is the one fixed exception.
        var signInAllowed = true
        do { try NetworkPolicy.check(NetworkPolicy.signInHost) } catch { signInAllowed = false }
        check("microsoft sign-in allowed", signInAllowed)

        // A mailbox being verified is allowed only inside that scope.
        let probe = "imap.example.org"
        var allowedDuring = true
        NetworkPolicy.whileVerifying(probe) {
            do { try NetworkPolicy.check(probe) } catch { allowedDuring = false }
        }
        check("allowed while verifying", allowedDuring)

        var refusedAfter = false
        do { try NetworkPolicy.check(probe) } catch { refusedAfter = true }
        check("refused again afterwards", refusedAfter,
              refusedAfter ? "" : "temporary allowance outlived its scope")

        // Nothing beyond the sign-in host is reachable with no mailboxes set up.
        let allowed = NetworkPolicy.allowedHosts()
        let configured = Set(SettingsStore.shared.settings.accounts.map { $0.host.lowercased() })
        let unexpected = allowed.subtracting(configured).subtracting([NetworkPolicy.signInHost])
        check("no host beyond your own", unexpected.isEmpty,
              unexpected.isEmpty ? "\(allowed.count) allowed" : "extra: \(unexpected.sorted())")

        print("\n\(5 - failures.count) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("\nFailures:")
            failures.forEach { print($0) }
        }
        return failures.count
    }
}
