#!/bin/bash
# Static audit of what this app is able to do with a network connection.
#
# The point is that "it doesn't phone home" should be checkable rather than
# taken on trust. Networking may appear only in the two files that route
# through NetworkPolicy, which refuses any host the user did not configure.
# If that ever stops being true, this fails and build.sh refuses to ship.
set -uo pipefail
cd "$(dirname "$0")"

NET_FILES="IMAPClient.swift MicrosoftOAuth.swift"
NET_APIS="NWConnection|URLSession|URLRequest|CFStream|CFSocket|getaddrinfo|NSTask|Process\("
FAILURES=0

echo "== Network reachability =="
for file in Sources/OTPeek/*.swift; do
  name="$(basename "$file")"
  case " $NET_FILES " in *" $name "*) continue ;; esac
  if grep -nE "$NET_APIS" "$file" > /dev/null 2>&1; then
    echo "  FAIL  $name uses a networking API but does not go through NetworkPolicy"
    grep -nE "$NET_APIS" "$file" | sed 's/^/          /'
    FAILURES=$((FAILURES + 1))
  fi
done
[ "$FAILURES" -eq 0 ] && echo "  ok    networking confined to: $NET_FILES"

echo "== Every connection is gated =="
for name in $NET_FILES; do
  if grep -q "NetworkPolicy.check" "Sources/OTPeek/$name"; then
    echo "  ok    $name checks NetworkPolicy before connecting"
  else
    echo "  FAIL  $name opens connections without calling NetworkPolicy.check"
    FAILURES=$((FAILURES + 1))
  fi
done

echo "== Telemetry =="
if grep -rniE "analytics|telemetry|mixpanel|segment\.io|amplitude|sentry|firebase|crashlytics|posthog" Sources > /dev/null 2>&1; then
  echo "  FAIL  found something that looks like analytics"
  grep -rniE "analytics|telemetry|mixpanel|segment\.io|amplitude|sentry|firebase|crashlytics|posthog" Sources | sed 's/^/          /'
  FAILURES=$((FAILURES + 1))
else
  echo "  ok    no analytics or crash-reporting code"
fi

echo "== Third-party code =="
if grep -q "dependencies:" Package.swift && grep -qE '\.package\(' Package.swift; then
  echo "  FAIL  Package.swift pulls in a third-party dependency"
  FAILURES=$((FAILURES + 1))
else
  echo "  ok    no third-party packages — nothing to audit but this repo"
fi

echo "== Hosts hardcoded in shipping code =="
echo "  (help links open in your browser; only NetworkPolicy decides what is connected to)"
grep -rhoE 'https?://[a-zA-Z0-9.-]+' \
  $(ls Sources/OTPeek/*.swift | grep -vE 'SelfTest|DemoMode') | sort -u | sed 's/^/          /'

echo "== Hosts appearing only in tests and demo data =="
grep -rhoE 'https?://[a-zA-Z0-9.-]+' Sources/OTPeek/SelfTest*.swift Sources/OTPeek/DemoMode.swift 2>/dev/null \
  | sort -u | sed 's/^/          /'

if [ "$FAILURES" -gt 0 ]; then
  echo
  echo "AUDIT FAILED: $FAILURES problem(s)."
  exit 1
fi
echo
echo "Audit passed."
