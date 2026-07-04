#!/usr/bin/env bash
# Offline smoke for scripts/check-update.sh: single last-check marker, legacy
# per-day marker cleanup, same-day short-circuit, newer-remote output, and
# silence when curl is missing. file:// URLs keep it network-free, so this is
# the gate that covers the checker's behavior when the e2e smoke is skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

tmpdir=$(make_tmpdir)
checker="$ROOT/scripts/check-update.sh"
cache_home="$tmpdir/cache"
remote_file="$tmpdir/remote-version"
version="$(tr -d '[:space:]' < "$ROOT/VERSION")"

run_checker() {
  XDG_CACHE_HOME="$cache_home" WAZA_UPDATE_URL="file://$remote_file" bash "$checker"
}

# Case 1: up to date -> silent; one marker stamped today; legacy files removed.
mkdir -p "$cache_home/waza"
touch "$cache_home/waza/update-checked-2020-01-01"
printf '%s' "$version" > "$remote_file"
out=$(run_checker)
if [ -n "$out" ]; then
  echo "update-check smoke: up-to-date run should be silent, got: $out"
  exit 1
fi
if [ "$(cat "$cache_home/waza/last-check" 2>/dev/null)" != "$(date +%F)" ]; then
  echo "update-check smoke: last-check should hold today's date"
  exit 1
fi
if ls "$cache_home/waza"/update-checked-* >/dev/null 2>&1; then
  echo "update-check smoke: legacy per-day markers should be removed"
  exit 1
fi

# Case 2: same-day rerun short-circuits before the fetch, even with a newer remote.
printf '%s' "99.0.0" > "$remote_file"
out=$(run_checker)
if [ -n "$out" ]; then
  echo "update-check smoke: same-day rerun should skip the fetch, got: $out"
  exit 1
fi

# Case 3: fresh cache with a newer remote prints the single update line.
rm -rf "$cache_home/waza"
out=$(run_checker)
case "$out" in
  "Waza 99.0.0 is available"*) ;;
  *)
    echo "update-check smoke: expected update line for newer remote, got: $out"
    exit 1
    ;;
esac

# Case 4: remote older than local stays silent.
rm -rf "$cache_home/waza"
printf '%s' "0.0.1" > "$remote_file"
out=$(run_checker)
if [ -n "$out" ]; then
  echo "update-check smoke: downgrade should be silent, got: $out"
  exit 1
fi

# Case 5: no curl on PATH -> silent no-op, exit 0.
rm -rf "$cache_home/waza"
printf '%s' "99.0.0" > "$remote_file"
bin_dir="$tmpdir/bin"
mkdir -p "$bin_dir"
for tool in bash date cat dirname mkdir rm sed grep sort tail tr head; do
  tool_path="$(command -v "$tool" 2>/dev/null)" || continue
  case "$tool_path" in
    /*) ln -s "$tool_path" "$bin_dir/$tool" ;;
  esac
done
out=$(XDG_CACHE_HOME="$cache_home" WAZA_UPDATE_URL="file://$remote_file" PATH="$bin_dir" bash "$checker")
if [ -n "$out" ]; then
  echo "update-check smoke: missing curl should be silent, got: $out"
  exit 1
fi

echo "update-check smoke: ok"
