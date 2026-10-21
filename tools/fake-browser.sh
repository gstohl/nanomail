#!/bin/sh
# Stands in for the browser in headless runs against a local Stalwart:
# signs in on its page (tools/stalwart-browser.sh, as alice by default),
# then follows the redirect back to nanomail's loopback address.
#
#   NANOMAIL_OPEN_URL_WITH=tools/fake-browser.sh zig-out/bin/nanomail --nanoui-snapshot=…
set -eu
here=$(cd "$(dirname "$0")" && pwd)
url=$(sh "$here/stalwart-browser.sh" "$1")
curl -fsS "$url" >/dev/null
