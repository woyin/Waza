#!/usr/bin/env bash
# End-to-end smoke for `npx skills add`. Catches packaging / frontmatter / path
# bugs that only surface on a real install, not on internal verify_skills.py
# runs. The marketplace v2.1.136+ regression in README.md is the exact class
# of bug this guards against.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

# Opt out when offline or for fast iteration loops:
#   WAZA_SMOKE_OFFLINE=1 make smoke-skills-add-e2e
if [ "${WAZA_SMOKE_OFFLINE:-0}" = "1" ]; then
  echo "skills add e2e smoke: skipped (WAZA_SMOKE_OFFLINE=1)"
  exit 0
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "skills add e2e smoke: skipped (npx not available)"
  exit 0
fi

tmpdir=$(make_tmpdir)
copy_repo "$tmpdir/repo"
test_home="$tmpdir/home"
mkdir -p "$test_home"

# Install all 8 skills into an isolated HOME against the local repo copy.
# One retry absorbs transient npm-registry hiccups without hiding real breakage.
if ! HOME="$test_home" npx --yes skills add "$tmpdir/repo" -a claude-code -g -y \
  >"$tmpdir/install.out" 2>&1; then
  sleep 5
  if ! HOME="$test_home" npx --yes skills add "$tmpdir/repo" -a claude-code -g -y \
    >"$tmpdir/install.out" 2>&1; then
    echo "skills add e2e smoke: install failed after retry"
    cat "$tmpdir/install.out" >&2
    exit 1
  fi
fi

# All 8 SKILL.md files landed under ~/.claude/skills/.
expected=(check health hunt learn read think ui write)
for skill in "${expected[@]}"; do
  target="$test_home/.claude/skills/$skill/SKILL.md"
  if [ ! -f "$target" ]; then
    echo "skills add e2e smoke: missing $target after install"
    cat "$tmpdir/install.out" >&2
    exit 1
  fi
  checker="$test_home/.claude/skills/$skill/scripts/check-update.sh"
  if [ ! -f "$checker" ]; then
    echo "skills add e2e smoke: missing $checker after install"
    cat "$tmpdir/install.out" >&2
    exit 1
  fi
done

# The installed checker consolidates the daily marker into one last-check file,
# cleans up legacy per-day markers, and stays quiet when up to date.
checker="$test_home/.claude/skills/think/scripts/check-update.sh"
cache_home="$tmpdir/cache"
remote_file="$tmpdir/remote-version"
local_version="$(tr -d '[:space:]' < "$tmpdir/repo/VERSION")"

mkdir -p "$cache_home/waza"
touch "$cache_home/waza/update-checked-2020-01-01"
printf '%s' "$local_version" > "$remote_file"
out=$(XDG_CACHE_HOME="$cache_home" WAZA_UPDATE_URL="file://$remote_file" bash "$checker")
if [ -n "$out" ]; then
  echo "skills add e2e smoke: up-to-date check should print nothing, got: $out"
  exit 1
fi
if [ "$(cat "$cache_home/waza/last-check" 2>/dev/null)" != "$(date +%F)" ]; then
  echo "skills add e2e smoke: expected last-check marker stamped with today"
  exit 1
fi
if ls "$cache_home/waza"/update-checked-* >/dev/null 2>&1; then
  echo "skills add e2e smoke: legacy per-day markers should be cleaned up"
  exit 1
fi

# Same-day rerun short-circuits on the marker: even a newer remote prints nothing.
printf '%s' "99.0.0" > "$remote_file"
out=$(XDG_CACHE_HOME="$cache_home" WAZA_UPDATE_URL="file://$remote_file" bash "$checker")
if [ -n "$out" ]; then
  echo "skills add e2e smoke: same-day rerun should skip the fetch, got: $out"
  exit 1
fi

# Fresh cache with a newer remote prints the single update line.
rm -rf "$cache_home/waza"
out=$(XDG_CACHE_HOME="$cache_home" WAZA_UPDATE_URL="file://$remote_file" bash "$checker")
case "$out" in
  "Waza 99.0.0 is available"*) ;;
  *)
    echo "skills add e2e smoke: expected update line for newer remote, got: $out"
    exit 1
    ;;
esac

# Frontmatter survived the copy: re-run verify_skills.py against the installed
# skill root and confirm the same name/description/version contract holds.
python3 "$ROOT/scripts/verify_skills.py" --root "$test_home/.claude" --skills-only \
  >"$tmpdir/verify.out" 2>&1 || {
    echo "skills add e2e smoke: verify_skills failed against installed skills"
    cat "$tmpdir/verify.out" >&2
    exit 1
  }

echo "skills add e2e smoke: ok"
