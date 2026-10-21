# AGENTS.md

nanomail is a JMAP mail client for macOS in Zig 0.17 on
[nanoui](https://github.com/justrach/nanoui) (pinned in `build.zig.zon`;
its source is in `zig-pkg/` after a build). README.md says what it does
and how it's laid out.

## Commands

```sh
zig build                     # zig-out/bin/nanomail
zig build test                # every test; views through ui.Tester, offscreen
sh macos/package.sh           # zig-out/package/nanomail.app
zig build $(sh zig-pkg/nanoui-*/tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator   # zig-out/ios/nanomail.app
zig-out/bin/nanomail --nanoui-snapshot=/tmp/shot.png --nanoui-wait=3 --nanoui-script="click:Inbox;live:1"
```

`NANOMAIL_SHOTS=<dir> zig build test` leaves the tests' screenshots there.
iOS is checked in a Simulator booted headless (`xcrun simctl boot`):
install a copy of the bundle signed ad hoc, then
`xcrun simctl launch --console-pty <device> dev.nanomail.app --nanoui-snapshot=<host path> --nanoui-script=…`
renders it at the phone's size (`SIMCTL_CHILD_NANOMAIL_*` passes the
account), or `xcrun simctl io <device> screenshot` shows what it shows.
After any change, build for both macOS and iOS.
A device build (`-Dtarget=aarch64-ios`) is linked by Apple's linker
(`deviceLink` in build.zig): an iPhone silently refuses what Zig 0.17
links (no crash report, no pid), while the Simulator runs it.
`NANOMAIL_OPEN_URL_WITH=tools/fake-browser.sh` makes browser sign-in (OAuth)
run headless against a local Stalwart, saving nothing (README.md has the
script steps).
`NANOMAIL_URL` / `NANOMAIL_USER` / `NANOMAIL_PASSWORD` (or `NANOMAIL_TOKEN`)
sign the app in without the keychain; `NANOMAIL_TEST_URL` and friends turn
on the live client test (it changes that account: use a test server).

## Rules

- **Never open windows or drive the screen while working.** Check the look
  with `--nanoui-snapshot` (and `--nanoui-dark`), behavior with `ui.Tester`
  in `src/tests_views.zig`. `zig build run` is for people.
- **Never touch the user's keychain or saved account in tests.** Tests use
  the recorder backend and canned transports; the live test talks only to
  the server it's given.
- **The main thread never waits on the network.** New server work is a
  `Job` (src/mail/kinds.zig) done in `Sync.work`, answered by an `Event`
  applied in `Model.apply`. Jobs are deep-copied when queued (`copy.deep`);
  events carry the arena their data lives in, which the model keeps or
  frees.
- **Optimistic, then the server.** Model actions change the state at once
  and submit a job; a failure posts `failed`, which refreshes from the
  server.
- **Zig 0.17:** `std.Io` everywhere (`Io.Mutex`, `Io.Condition`,
  `Io.Select`), `std.http.Client.request` (not `fetch`, which can panic
  mid-body). `std.json.Value`'s null is `@as(std.json.Value, .null)`, never
  `std.json.Value.null` (that's the tag, written as the string "null").
- Files stay under 600 lines, as nanoui's do: split by responsibility.
- Every behavior gets a test: protocol shapes in `src/jmap/*.zig` and
  `src/tests_client.zig`, views and model in `src/tests_views.zig`.
