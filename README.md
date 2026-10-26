# nanomail

A mail client for macOS and iOS that speaks [JMAP](https://jmap.io)
(RFC 8620, RFC 8621), written in Zig 0.17 on [nanoui](https://github.com/justrach/nanoui):
native UI drawn with Metal and CoreText, no webview, one ~2 MB binary.

It's tested against [Stalwart](https://stalw.art); it keeps to the RFCs,
so Fastmail, Cyrus and other JMAP servers should work too (Fastmail with
an API token).

## What it does

- **Three panes**, as Mail's: folders with unread counts (roles first,
  nested folders indented), the list of the folder open (virtualized, paged
  as you scroll), and the message open.
- **Reading:** plain text as sent; HTML mail read as text (paragraphs,
  lists, quotes, tables, entities), with *Open in Browser* for the
  original. Quoted lines set apart. Selectable, copyable text.
  **Links** are underlined and open with a click (the pointer over one
  shows where it really goes; `mailto:` opens a new message), in HTML mail
  and in plain text alike. **Pictures** show where the mail puts them
  (`cid:` parts) and attached pictures get previews; pictures from the web
  wait for *Load Pictures* (they tell the sender you read the mail), and
  tracking pixels are skipped. Attachments download to `~/Downloads` and
  show in the Finder.
- **Writing:** new messages, reply, reply all, forward (with the original
  attachments, by reference), drafts saved and opened again, a choice of
  identity. Replies are threaded (`In-Reply-To`, `References`) and mark the
  original answered.
- **Organizing:** archive, move to any folder, trash (and delete for good
  from the trash), flag, mark read or unread. Changes show at once and
  are sent to the server after.
- **Shared mailboxes:** every account the session lists with mail (other
  people's folders shared with you, a group's mailbox) gets a section of
  the sidebar, named after it. What a folder's `myRights` don't allow is
  greyed out (a lock marks read-only folders), roles (Trash, Archive) are
  each account's own, and a group's mail is answered from the group's
  identity, kept in its Drafts and Sent. Some servers don't push changes
  in accounts shared by others, so those refresh every two minutes.
- **Search** in the folder open, on the server (`Email/query` text filter).
- **Push:** new mail and changes made elsewhere appear by themselves
  (JMAP EventSource), with a refresh every few minutes in case push
  isn't there.
- **Keys:** ↑ ↓ or j k to move, e to archive, ⌫ to trash, s to flag,
  u for read/unread, r / a / f to reply, reply all, forward, c to compose,
  / to search. With ⌘: N new, R reply, ⇧R reply all, ⇧F forward,
  ⌃A archive, ⇧U read/unread, ⇧L flag, ⇧N get mail, F find, ↩ send.
- **Light and dark**, following the system. Unread count on the Dock icon.
- **Accounts:** your address and password, an API token, or **signing in
  through the browser** (OAuth 2.0 / OpenID Connect). The server is found
  from your address (`/.well-known/jmap`), or given. The password, token or
  refresh token is kept in the login keychain, the rest in
  `~/Library/Application Support/nanomail/account.json`.

## Build and run

You need Zig 0.17.0 and the macOS SDK (Xcode or the Command Line Tools);
for iOS, Xcode.

```sh
zig build run                 # build and open nanomail
zig build test                # the tests (views rendered offscreen)
sh macos/package.sh           # zig-out/package/nanomail.app, signed ad hoc
DMG=1 sh macos/package.sh     # and a disk image
```

### iOS

The same app, on iPhone and iPad: narrower than 900 points (a phone, an
iPad held upright) the panes stack, Mailboxes → list → message with back
buttons, the message's actions at its foot. Signing in through the browser
uses a sign-in sheet (`ASWebAuthenticationSession`) that comes back to
`dev.nanomail.app:/oauth/callback`. Downloads go to the app's Documents
(Files › On My iPhone › nanomail). HTTP goes through NSURLSession on iOS
(std.http has no certificates to trust there): the system's trust store,
proxies and App Transport Security, which lets plain `http://` reach only
the local network. The Simulator reads the app's keychain entitlements
from a section of the binary (`ios/simulator.entitlements`); a device app
gets them from its provisioning profile.

Zig 0.17.0's std needs one line fixed to build for iOS, which nanoui's
`tools/ios/zig-lib.sh` does (it prints the flag that uses its copy):

```sh
zig build $(sh zig-pkg/nanoui-*/tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator      # zig-out/ios/nanomail.app
xcrun simctl boot "iPhone 16 Pro"                                                          # a Simulator, headless
zig build $(sh zig-pkg/nanoui-*/tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator run  # installs and runs it
```

`-Dtarget=aarch64-ios` builds for devices. Zig compiles that one and
Apple's linker (`xcrun clang`) links it: an iPhone won't start a program
Zig 0.17 links itself. To install it, put a provisioning profile that
covers `dev.nanomail.app` in the bundle as `embedded.mobileprovision`,
`codesign` it with your Apple Development certificate and entitlements
naming `<team>.dev.nanomail.app` (as `application-identifier` and the
keychain access group), and `xcrun devicectl device install app`.

### Signing in

- **Through the browser (OAuth / OIDC):** choose *Browser*, give your
  address (and the server, if it isn't your address's domain), and
  *Continue in Browser*. nanomail finds the server's sign-in (RFC 9728,
  RFC 8414 or OpenID Connect discovery), registers itself where the server
  allows it (RFC 7591; otherwise enter a client ID), and opens the page
  with PKCE. The browser comes back to a loopback address nanomail
  listens on for the sign-in (RFC 8252): no URL scheme to register, so it
  works for `zig build run` as for the app. Access tokens are renewed with
  the refresh token, which is what the keychain keeps.

- **Fastmail:** your address, *API token* (Settings → Privacy & Security
  → API tokens, with mail and submission access), and leave the server
  empty.
- **Stalwart, Cyrus, others:** your address and password; the server's
  address if it isn't your address's domain (e.g. `https://mail.example.com`
  or the session URL itself).

## Trying it without an account of yours

`NANOMAIL_URL`, `NANOMAIL_USER` and `NANOMAIL_PASSWORD` (or
`NANOMAIL_TOKEN`) sign in without touching the keychain or saved settings.
Against a local [Stalwart](https://stalw.art) in Docker:

```sh
NANOMAIL_URL=http://127.0.0.1:8080 NANOMAIL_USER=alice@example.test \
NANOMAIL_PASSWORD=alice-pass zig build run
```

The app can also be rendered without a window, which is how it's checked:

```sh
zig-out/bin/nanomail --nanoui-snapshot=shot.png --nanoui-wait=3 \
  --nanoui-script="click:Inbox;key:down;live:1"
```

Signing in through the browser runs headless too: `NANOMAIL_OPEN_URL_WITH`
names a command that gets the sign-in URL in place of the browser (and
then nothing is saved). `tools/fake-browser.sh` signs in on a local
Stalwart's page as alice and follows the redirect back:

```sh
NANOMAIL_OPEN_URL_WITH=tools/fake-browser.sh zig-out/bin/nanomail --nanoui-snapshot=shot.png \
  --nanoui-script="click:Browser;click:you@example.com;type:alice@example.test;click:https://mail.example.com;type:http://127.0.0.1:8080;click:Continue in Browser;live:6"
```

The live client test talks to such a server, and changes that account
(it sends a message, flags and moves one, and puts them back):

```sh
NANOMAIL_TEST_URL=http://127.0.0.1:8080 NANOMAIL_TEST_USER=alice@example.test \
NANOMAIL_TEST_PASSWORD=alice-pass NANOMAIL_TEST_TO=bob@example.test zig build test
```

## How it's made

```
src/main.zig            the app: windows, menu bar, Dock badge, the account kept
src/ios_auth.zig        iOS's sign-in sheet (ASWebAuthenticationSession)
src/model.zig           the state, on the main thread; model_actions.zig: what's done to messages
src/compose.zig         a message being written: reply, forward, drafts
src/view*.zig           the views: sidebar, list, reader, compose, sign-in
src/sync.zig            the sync thread (jobs in, events out) and push
src/jmap/               JMAP: session discovery, requests, the client, sending, HTTP
                        (std.http; http_apple*.zig: NSURLSession, for iOS),
                        OAuth (oauth.zig) and the browser's way back (loopback.zig)
src/mail/               HTML as text, dates, addresses, the app's own kinds of data
src/keychain.zig        Security.framework, called directly
src/config.zig          account.json and the keychain item
tools/icon.zig          the app icon, drawn by nanoui
tools/fake-browser.sh   the browser's part of signing in, for headless runs
macos/package.sh        the .app bundle
```

The UI thread never waits on the network. The model asks the sync thread
for work (each job copied into an arena of its own). The sync thread does
it with `std.http`, each request raced against a timeout, and answers with
an event that runs on the main thread (libdispatch), carrying the arena
its data lives in.

## Not yet

Several accounts; conversations grouped by thread; attaching files from
disk; rich text when writing; offline cache; images in HTML mail; colour
emoji (nanoui draws glyphs as masks).

Known limits:

- The text being written is at most 16 KB (nanoui's text field). Longer
  quotes are shortened, with a note; a longer draft opens as its start
  only, and the original is kept.
- Servers are found through `/.well-known/jmap`, not DNS SRV records, so
  Fastmail on your own domain needs the session URL typed in
  (`https://api.fastmail.com/jmap/session`).
- A reply saved as a draft and sent later doesn't mark the original
  answered.

## License

nanomail is licensed under the [Zero-Clause BSD license](LICENSE) (0BSD).
Dependencies and third-party components retain their respective licenses and rights.
