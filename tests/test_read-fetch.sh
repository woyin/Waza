#!/usr/bin/env bash
# Smoke for /read fetch.sh privacy-first cascade.
# - Local extractor handles a simple HTML page (no third-party request).
# - --use-proxy flag is recognized (we do not actually call defuddle/jina
#   in the smoke test; tier=local will succeed on example.com and we never
#   reach the proxy tiers).
# - Structured stderr lines are emitted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

if [ "${WAZA_SMOKE_OFFLINE:-0}" = "1" ]; then
  echo "read fetch smoke: skipped (WAZA_SMOKE_OFFLINE=1)"
  exit 0
fi

tmpdir=$(make_tmpdir)

# Transient example.com hiccups must not fail the mandatory test gate; retry
# each successful-path fetch with backoff before declaring the network broken.
retry3() {
  local out="$1" err="$2"
  shift 2
  local attempt
  for attempt in 1 2 3; do
    if "$@" >"$out" 2>"$err"; then
      return 0
    fi
    sleep $((attempt * 2))
  done
  echo "read fetch smoke: failed after 3 attempts: $*" >&2
  cat "$err" >&2
  return 1
}

# Case 1: default invocation extracts content with structured stderr.
retry3 "$tmpdir/out.md" "$tmpdir/err.log" \
  bash "$ROOT/skills/read/scripts/fetch.sh" "https://example.com"
grep -q "Example Domain" "$tmpdir/out.md"
grep -q "tier=local status=ok" "$tmpdir/err.log"

# Case 2: --use-proxy flag is accepted (and local tier still tried first).
retry3 "$tmpdir/proxy-out.md" "$tmpdir/proxy-err.log" \
  bash "$ROOT/skills/read/scripts/fetch.sh" --use-proxy "https://example.com"
grep -q "Example Domain" "$tmpdir/proxy-out.md"
grep -q "tier=local status=ok" "$tmpdir/proxy-err.log"

# Case 3: fetch_local.py runnable directly with --prefer stdlib.
retry3 "$tmpdir/local.md" "$tmpdir/local.err" \
  python3 "$ROOT/skills/read/scripts/fetch_local.py" --prefer stdlib "https://example.com"
grep -q "Example Domain" "$tmpdir/local.md"
grep -q "extractor=stdlib" "$tmpdir/local.err"

# Case 4: a clearly unreachable URL fails with structured stderr.
if bash "$ROOT/skills/read/scripts/fetch.sh" "http://invalid.localhost.invalid/" \
     >"$tmpdir/dead.md" 2>"$tmpdir/dead.err"; then
  echo "fetch.sh should fail on unreachable URL"
  exit 1
fi
grep -q "status=fail" "$tmpdir/dead.err"

echo "read fetch smoke: ok"
