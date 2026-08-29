# OTPeek

A macOS menu bar app that watches your inboxes and your iPhone's texts, and
pops the one-time code on screen the moment it arrives.

Stop digging through four mailboxes wondering which one the code went to.

**[otpeek website →](https://minutesback.github.io/OTPeek/)**

- **Click to copy.** The popup never takes focus, so the login field you were
  already typing in stays focused and `⌘V` works immediately.
- **Push, not polling.** IMAP IDLE means a code appears about a second after
  the mail lands.
- **Texts too.** Reads the local Messages database, so codes your iPhone
  forwards to your Mac show up in the same place.
- **Local only.** No server, no telemetry, no account. Mail is read straight
  from your provider over TLS; passwords live in the macOS Keychain.
- **No dependencies.** Pure Swift against the system frameworks.

## Install

Requires macOS 14 or later.

```bash
git clone https://github.com/MinutesBack/OTPeek.git
cd OTPeek && ./build.sh --install
```

That compiles it, runs the test suite, builds `OTPeek.app`, and launches it
from `/Applications`.

Everything after this point is a normal Mac app — settings are a window, not a
config file you edit by hand.

> The app is signed ad-hoc rather than notarized, because notarization needs a
> paid Apple Developer account. Building it yourself, as above, avoids
> Gatekeeper entirely. If you instead download a release zip, macOS will block
> it on first launch: open **System Settings → Privacy & Security**, scroll to
> the blocked-app notice and choose **Open Anyway**.

## Setup

### Mailboxes

Open **Settings…** from the menu bar icon and click **Add mailbox**. Pick your
provider, enter your address and password, and OTPeek connects to the real
server before saving — so a wrong password tells you immediately instead of
failing silently later.

Presets cover Gmail and Google Workspace, Outlook.com / Hotmail / Live,
Microsoft 365, iCloud, Proton Mail, Fastmail, Yahoo, Zoho, GMX, AOL, Orange,
Free, SFR and Laposte.net — plus any other IMAP server by hostname.

Where a provider requires an **app password** rather than your normal one, the
sheet opens the page that creates it and **fills the field in for you** as soon
as you copy it. Google shows app passwords in four spaced groups; the spaces
are stripped automatically, which is a common cause of "credentials rejected"
elsewhere.

Two Microsoft paths exist because the endpoints genuinely differ. **Personal
accounts** (outlook.com, hotmail, live) still accept an app password on
`imap-mail.outlook.com` and need no registration at all. Only **work and school
accounts** hit `LOGINDISABLED` and require the browser sign-in below.

**Proton Mail** needs [Proton Mail Bridge](https://proton.me/mail/bridge)
running, with its IMAP connection mode set to SSL. Bridge serves IMAP on
loopback with a self-signed certificate, which OTPeek accepts for loopback
addresses only.

Mailboxes and passwords are saved, and adding your first one switches on
**Start at login**, so codes keep arriving after a restart. You never reconnect
a mailbox.

### Text messages

Two things are needed:

1. **On your iPhone:** Settings → Apps → Messages → Text Message Forwarding,
   and enable your Mac.
2. **On your Mac:** grant Full Disk Access to OTPeek, so it can read the
   Messages database. macOS never asks for this permission by itself — it just
   returns nothing — so OTPeek invites you on launch, opens the right settings
   pane, reveals the app in Finder to drag in, and offers to restart itself
   afterwards, since the permission is only picked up when the app starts. The
   same flow is on the menu under **Grant Full Disk Access…**.

Full Disk Access is tied to the app's signature, so if you rebuild OTPeek you
may need to remove and re-add it in that list.

### Outlook / Microsoft 365

Microsoft disabled password-based IMAP, so Outlook accounts sign in through
your browser. That needs a free app registration, once:

1. Go to [entra.microsoft.com](https://entra.microsoft.com) → **App
   registrations** → **New registration**
2. Name it `OTPeek`, and choose *Accounts in any organizational directory and
   personal Microsoft accounts*
3. Under **Authentication**, turn on **Allow public client flows**
4. Under **API permissions**, add **APIs my organization uses** → *Office 365
   Exchange Online* → **Delegated** → `IMAP.AccessAsUser.All`
5. Copy the **Application (client) ID** from the Overview page into OTPeek

OTPeek then shows a short code, opens Microsoft's sign-in page, and stores the
refresh token in your Keychain. You will not be asked again.

## How it decides what to show

Everything is scored rather than first-match, because the failure that
actually hurts is pasting an order number into a login form.

- A code has to sit **close** to language like *verification code*, *code de
  sécurité*, *one-time password*. English and French are both first-class.
- Numbers hugged by *order*, *invoice*, *tracking*, *facture*, *montant* are
  rejected — as are prices, dates, years, and round numbers like `45000`.
- In HTML mail, a number alone in its own styled cell scores highly; that is
  how nearly every provider lays out a code.
- Links only count if they look like a real activation path (`/verify`,
  `/activer`, `/magic`, `?token=`) and are not an unsubscribe or social link.
- A code you can paste beats a link you have to click, so it wins ties.
- For links, the popup shows the **real destination host**, so a lookalike
  domain is visible before you click.

Some cases this was tuned against, all of which are in the test suite:

| Message | Result |
|---|---|
| `Your Uber code is 4829. Reply STOP to unsubscribe.` | `4829` — the unsubscribe footer must not veto it |
| `Order #48192033 shipped. Separately: your verification code is 771204.` | `771204`, not the order number |
| `We now support 2FA for all 45000 of our customers.` | nothing — the mail discusses 2FA, it isn't a code |
| `Facture n 20240815 d'un montant de 1250,00 EUR` | nothing |

## Development

```bash
./run-tests.sh          # extractor corpus + mail parsing
./build.sh              # build into ./dist
./build.sh --install    # build, install to /Applications, launch
OTPeek --imap-probe imap.gmail.com   # check connectivity to a server
```

`build.sh` refuses to produce an app if the tests fail.

If a code is ever missed, or a popup fires when it shouldn't, add the message
to `Sources/OTPeek/SelfTest.swift` as a case and adjust the scoring — that
file is the fastest way to tune detection.

### Layout

| File | Role |
|---|---|
| `Extractor.swift` | Scoring engine — decides if a message contains a code or link |
| `Vocabulary.swift` | The keyword and URL-shape lists it scores against |
| `HTMLText.swift` | Flattens HTML mail to text, nodes and links |
| `MIME.swift` | Headers, encoded words, quoted-printable, base64, multipart |
| `IMAPClient.swift` | Minimal IMAP over TLS, including IDLE |
| `IMAPWatcher.swift` | One mailbox: connect, idle, fetch, reconnect |
| `MessagesWatcher.swift` | Polls the local Messages database |
| `TypedStream.swift` | Reads message bodies out of `attributedBody` |
| `HUDPanel.swift` | The floating popup |
| `SettingsWindow.swift` | Account setup UI |
| `MicrosoftOAuth.swift` | Device code flow for Outlook |

A note on `TypedStream`: on current macOS the `message.text` column is empty
and the body lives in an `NSAttributedString` typedstream archive. Swift has no
`NSUnarchiver`, so the payload is parsed from the bytes directly. That parser
was verified byte-for-byte against `NSUnarchiver`'s output across a real
message database before it was trusted.

## Troubleshooting

The log is at `~/Library/Logs/OTPeek/otpeek.log` (**Open log** in the menu). It
records source status and hits — senders and confidence scores, never message
content.

- **Nothing for email.** The menu shows each mailbox as `push` or `polling`,
  plus any connection error.
- **Nothing for SMS.** The menu says if Full Disk Access is missing. On launch
  the log also reports a decoder self-test; `0 plain, N decoded from blob` is
  the expected healthy result on macOS 14+, while `N unreadable` means the
  decoder needs attention.

## Security

You are about to type a mail password into an app you downloaded. That deserves
more than a promise, so the guarantee is enforced in code and checked by the
test suite.

**There is no OTPeek server.** Your mail is read by connecting straight from
your Mac to your provider over TLS. Nothing is relayed through anyone else —
not the author, not an organisation, not an analytics service.

**Connections are allow-listed, not merely intended.** Every outbound
connection passes through `NetworkPolicy`, which permits exactly two things: a
mail server you entered yourself, and `login.microsoftonline.com` for Outlook
sign-in. Anything else throws before a socket opens, and the refusal is logged.

**The build refuses to ship if that stops being true.** `./audit.sh` fails if a
networking API appears in any file other than the two that route through the
gate, if either stops calling it, if anything resembling analytics appears, or
if a third-party dependency is added. `build.sh` runs it and will not produce
an app if it fails.

**Passwords go to the Keychain, never to disk.** They are stored with
`kSecAttrAccessibleWhenUnlocked`, so they are unreadable while the Mac is
locked. The config file at `~/Library/Application Support/OTPeek/config.json`
holds server names and addresses only — no secrets.

**You can see what it talked to.** Every connection is written to
`~/Library/Logs/OTPeek/otpeek.log`, senders and hosts only, never message
content or codes.

Check it yourself:

```bash
./audit.sh          # what this build can reach, and why
./run-tests.sh      # 43 tests, including the refusal path
```

The strongest guarantee is the one you already use to install it: the source is
here, it has no dependencies, and you build it yourself.

## Privacy

Everything runs on your Mac. Mail is read over TLS directly from your provider,
texts come from the local Messages database, and nothing is sent anywhere.
Passwords and OAuth refresh tokens are stored in the macOS Keychain, never in
the config file at `~/Library/Application Support/OTPeek/config.json`.

## License

MIT
