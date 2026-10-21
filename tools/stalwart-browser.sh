#!/bin/sh
# Headless stand-in for the browser half of Stalwart's (v0.16) OAuth
# authorization-code flow.
#
# Usage: browser.sh 'http://127.0.0.1:8080/login?response_type=code&client_id=...'
#
# Credentials: OAUTH_USER / OAUTH_PASS (defaults: alice@example.test / alice-pass).
# USER is honoured only when it contains '@', because every shell already sets
# $USER to the login name. PASS is honoured when OAUTH_PASS is unset.
#
# It does what the /login page's JS does: it reads the authorization request
# parameters from the URL, sends one POST to <origin>/api/auth with a JSON
# {"type":"authCode",...} body, and builds
#   redirect_uri?code=<client_code>&state=<state>&iss=<iss>
# from the {"type":"authenticated","client_code":...,"iss":...} reply.
# It prints that URL on stdout and does NOT request it.
# Exit codes: 0 ok, 1 bad credentials, 2 usage or protocol error, 3 MFA required.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 AUTHORIZATION_URL" >&2; exit 2; }
auth_url=$1

case ${USER:-} in *@*) def_user=$USER ;; *) def_user=alice@example.test ;; esac
OAUTH_USER=${OAUTH_USER:-$def_user}
OAUTH_PASS=${OAUTH_PASS:-${PASS:-alice-pass}}
export OAUTH_USER OAUTH_PASS

tmp=$(mktemp -d "${TMPDIR:-/tmp}/oauth-browser.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# 1. Build the JSON body and the API endpoint from the authorization URL.
python3 -I - "$auth_url" "$tmp" <<'PY'
import json, os, sys
from urllib.parse import urlsplit, parse_qs
url, tmp = sys.argv[1], sys.argv[2]
u = urlsplit(url)
if not u.scheme or not u.netloc:
    sys.exit("browser.sh: not an absolute URL: " + url)
q = parse_qs(u.query, keep_blank_values=True)
g = lambda k: (q.get(k) or [None])[0]
if not g("redirect_uri"):
    sys.exit("browser.sh: authorization URL has no redirect_uri")
body = {"type": "authCode",
        "accountName": os.environ["OAUTH_USER"],
        "accountSecret": os.environ["OAUTH_PASS"],
        "clientId": g("client_id") or ""}
for param, key in (("redirect_uri", "redirectUri"), ("scope", "scope"),
                   ("state", "state"), ("nonce", "nonce"),
                   ("code_challenge", "codeChallenge"),
                   ("code_challenge_method", "codeChallengeMethod")):
    if g(param):
        body[key] = g(param)
if q.get("resource"):
    body["resource"] = q["resource"]
origin = u.scheme + "://" + u.netloc
with open(os.path.join(tmp, "body.json"), "w") as f:
    json.dump(body, f)
with open(os.path.join(tmp, "endpoint"), "w") as f:
    f.write(origin + "/api/auth")
PY

# 2. The single request the login page sends.
status=$(curl -sS -o "$tmp/resp.json" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary "@$tmp/body.json" "$(cat "$tmp/endpoint")")
if [ "$status" != 200 ]; then
    # 401 here means the authorization request was rejected before the password
    # was checked: redirect_uri not registered, PKCE missing or not S256, etc.
    echo "browser.sh: /api/auth returned HTTP $status: $(cat "$tmp/resp.json")" >&2
    exit 2
fi

# 3. Do what the page does with the reply: build the redirect location.
python3 -I - "$auth_url" "$tmp/resp.json" <<'PY'
import json, sys
from urllib.parse import urlsplit, urlunsplit, parse_qs, parse_qsl, urlencode
url, resp_path = sys.argv[1], sys.argv[2]
raw = open(resp_path).read()
try:
    r = json.loads(raw)
except ValueError:
    print("browser.sh: unparseable reply: " + raw, file=sys.stderr); sys.exit(2)
t = r.get("type") if isinstance(r, dict) else None
if t == "failure":
    print("browser.sh: login failed: invalid username or password", file=sys.stderr); sys.exit(1)
if t == "mfaRequired":
    print("browser.sh: account needs a TOTP code (resend with mfaToken)", file=sys.stderr); sys.exit(3)
if t != "authenticated" or not isinstance(r.get("client_code"), str):
    print("browser.sh: unexpected reply: " + raw, file=sys.stderr); sys.exit(2)
u = urlsplit(url)
q = parse_qs(u.query, keep_blank_values=True)
redirect_uri = q["redirect_uri"][0]
state = (q.get("state") or [None])[0]
origin = u.scheme + "://" + u.netloc
# Same as the page: URL.searchParams.set(code), set(state) if present,
# set(iss, reply.iss || page origin). Existing redirect_uri params are kept.
ru = urlsplit(redirect_uri)
params = [(k, v) for k, v in parse_qsl(ru.query, keep_blank_values=True)
          if k not in ("code", "state", "iss")]
params.append(("code", r["client_code"]))
if state:
    params.append(("state", state))
params.append(("iss", r.get("iss") or origin))
print(urlunsplit((ru.scheme, ru.netloc, ru.path, urlencode(params), ru.fragment)))
PY
