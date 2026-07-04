#!/usr/bin/env bash
# Shared helpers for tests/test_*.sh. Source this file from each test:
#
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     source "$SCRIPT_DIR/test_helpers.sh"
#
# Sets ROOT to the repo root and provides:
#   make_tmpdir   - mktemp -d that auto-cleans on EXIT
#   copy_repo     - clone working tree (sans .git) into a target dir
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

_WAZA_TEST_TMPDIRS=()

_cleanup_tmpdirs() {
  # Trap runs at EXIT so the final command's status becomes the script's exit
  # status. Empty-array iteration under `set -e` would otherwise leak a non-zero
  # status from `[ -n "" ]`; the explicit `return 0` guards against that.
  local dir
  for dir in ${_WAZA_TEST_TMPDIRS[@]+"${_WAZA_TEST_TMPDIRS[@]}"}; do
    [ -n "$dir" ] && [ -d "$dir" ] && rm -rf "$dir"
  done
  return 0
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
  local dir
  dir=$(mktemp -d)
  _WAZA_TEST_TMPDIRS+=("$dir")
  printf '%s\n' "$dir"
}

copy_repo() {
  local dest="$1"
  mkdir -p "$dest"
  # Mirror the packager's file set (tracked + untracked-unignored): smokes test
  # the current worktree, but gitignored junk (dist/, __pycache__, local caches)
  # must not leak into the copy and diverge it from what actually ships.
  ( cd "$ROOT" && git ls-files --cached --others --exclude-standard -z | tar --null -cf - -T - ) | ( cd "$dest" && tar -xf - )
}

# Stub curl that drops a fixed payload at the -o output path. Used by installer
# smokes so they can verify download-then-write logic without hitting the
# network. First arg is the literal payload to emit (newlines via \n).
write_stub_curl() {
  local bin_dir="$1"
  local payload="$2"
  cat >"$bin_dir/curl" <<CURL
#!/bin/bash
outfile=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-o" ]; then outfile="\$2"; shift 2; else shift; fi
done
printf '%s' "${payload}" > "\$outfile"
CURL
  chmod +x "$bin_dir/curl"
}

# Build a stub PATH bin dir with the tools setup-rule.sh needs (python3,
# mkdir, mktemp, rm, plus tr/awk for the Title Case marker fallback) symlinked
# from the real environment. Returns the bin_dir path.
prepare_codex_installer_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  ln -s "$(command -v python3)" "$bin_dir/python3"
  ln -s /bin/mkdir "$bin_dir/mkdir"
  ln -s "$(command -v mktemp)" "$bin_dir/mktemp"
  ln -s /bin/rm "$bin_dir/rm"
  ln -s "$(command -v tr)" "$bin_dir/tr"
  ln -s "$(command -v awk)" "$bin_dir/awk"
}
