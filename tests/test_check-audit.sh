#!/usr/bin/env bash
# Smoke for skills/check/scripts/audit_signals.py.
# Builds a clean fixture (all PASS) and a dirty fixture (WARN/FAIL on the
# targeted blocks), runs the auditor against each, and greps for the
# expected status lines next to their headers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

AUDIT="$ROOT/skills/check/scripts/audit_signals.py"

# Helper: check that the line right after `=== <block> ===` (one or more
# lines down) has the expected status. Looks for `status: <expected>` within
# the block (until the next === header).
assert_block_status() {
  local out="$1" block="$2" expected="$3"
  awk -v block="=== ${block} ===" -v expected="status: ${expected}" '
    $0 == block { in_block = 1; next }
    in_block && /^=== / { in_block = 0 }
    in_block && $0 == expected { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$out" || {
    echo "FAIL: expected '$block' status=$expected; got:" >&2
    awk -v block="=== ${block} ===" '
      $0 == block { in_block = 1; print; next }
      in_block && /^=== / { exit }
      in_block { print }
    ' "$out" >&2
    return 1
  }
}

# Case 1: clean fixture -- everything PASS.
clean=$(make_tmpdir)
mkdir -p "$clean/.github/workflows" "$clean/tests" "$clean/src"
echo "1.0.0" > "$clean/VERSION"
cat > "$clean/.github/workflows/test.yml" <<'YAML'
name: test
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
echo "print('hi')" > "$clean/src/main.py"
echo "def test_one(): pass" > "$clean/tests/test_main.py"
echo "# project" > "$clean/AGENTS.md"

clean_out="$clean/audit.out"
python3 "$AUDIT" --root "$clean" > "$clean_out"

assert_block_status "$clean_out" "FILE SIZE HOTSPOTS" "PASS"
assert_block_status "$clean_out" "HEREDOC BLOAT" "PASS"
assert_block_status "$clean_out" "TEST AND CI SURFACE" "PASS"
assert_block_status "$clean_out" "VERSION SOURCE COUNT" "PASS"
assert_block_status "$clean_out" "INSTALL URL PINNING" "PASS"
assert_block_status "$clean_out" "AGENT DOC DEDUP" "PASS"
assert_block_status "$clean_out" "DRIFT MARKERS" "PASS"
# Surfaces absent in the clean fixture -> N/A (not PASS).
assert_block_status "$clean_out" "PACKAGING FILTER POSTURE" "N/A"
assert_block_status "$clean_out" "CLI CONTRACT SURFACE" "N/A"
assert_block_status "$clean_out" "DUPLICATE SETUP SCRIPTS" "N/A"
assert_block_status "$clean_out" "DENYLIST IN BUILD" "N/A"

# Case 2: dirty fixture -- targeted WARN/FAIL.
dirty=$(make_tmpdir)
mkdir -p "$dirty/src" "$dirty/scripts"

# Two version sources with conflicting values -> VERSION SOURCE WARN
echo "1.0.0" > "$dirty/VERSION"
cat > "$dirty/package.json" <<'JSON'
{ "name": "x", "version": "9.9.9" }
JSON

# README install URL pinned to main -> INSTALL URL PINNING WARN
cat > "$dirty/README.md" <<'MD'
# x
Install: curl https://raw.githubusercontent.com/u/r/main/setup.sh | bash
MD

# Both CLAUDE.md and AGENTS.md, non-symlink, identical content -> WARN
echo "# guide" > "$dirty/AGENTS.md"
echo "# guide" > "$dirty/CLAUDE.md"

# Two large source files (>500 lines) -> FILE SIZE HOTSPOTS WARN
python3 -c "print('# big', *['line_'+str(i) for i in range(700)], sep='\n')" \
  > "$dirty/src/big_one.py"
python3 -c "print('# big', *['line_'+str(i) for i in range(900)], sep='\n')" \
  > "$dirty/src/big_two.py"

# Python heredoc >100 lines in a shell script -> HEREDOC BLOAT WARN
{
  echo '#!/bin/bash'
  echo "python3 - <<'PY'"
  for _ in $(seq 1 130); do echo "x = 1"; done
  echo 'PY'
} > "$dirty/scripts/run.sh"

# Packaging script using denylist patterns + no allowlist -> PACKAGING WARN
cat > "$dirty/scripts/package.sh" <<'SH'
#!/bin/bash
tar --exclude=*.log -czf out.tgz src/
grep -v node_modules manifest.txt > manifest.filtered
SH

# No CI workflows, no tests -> TEST AND CI SURFACE FAIL
# (we intentionally do NOT create .github/workflows or tests/)

# Two near-duplicate setup scripts -> DUPLICATE SETUP SCRIPTS WARN
cat > "$dirty/scripts/setup-foo.sh" <<'SH'
#!/bin/bash
set -e
echo "setting up foo"
mkdir -p ~/.foo
touch ~/.foo/installed
SH
cp "$dirty/scripts/setup-foo.sh" "$dirty/scripts/setup-bar.sh"

dirty_out="$dirty/audit.out"
python3 "$AUDIT" --root "$dirty" > "$dirty_out"

assert_block_status "$dirty_out" "FILE SIZE HOTSPOTS" "WARN"
assert_block_status "$dirty_out" "HEREDOC BLOAT" "WARN"
assert_block_status "$dirty_out" "TEST AND CI SURFACE" "FAIL"
assert_block_status "$dirty_out" "VERSION SOURCE COUNT" "WARN"
assert_block_status "$dirty_out" "PACKAGING FILTER POSTURE" "WARN"
assert_block_status "$dirty_out" "CLI CONTRACT SURFACE" "N/A"
assert_block_status "$dirty_out" "INSTALL URL PINNING" "WARN"
assert_block_status "$dirty_out" "AGENT DOC DEDUP" "WARN"
assert_block_status "$dirty_out" "DUPLICATE SETUP SCRIPTS" "WARN"

# Case 3: CLI entrypoint without contract coverage -> WARN.
cli_warn=$(make_tmpdir)
mkdir -p "$cli_warn/bin" "$cli_warn/src"
cat > "$cli_warn/bin/examplecli" <<'SH'
#!/usr/bin/env bash
echo run
SH
chmod +x "$cli_warn/bin/examplecli"
echo "print('lib')" > "$cli_warn/src/lib.py"

cli_warn_out="$cli_warn/audit.out"
python3 "$AUDIT" --root "$cli_warn" > "$cli_warn_out"
assert_block_status "$cli_warn_out" "CLI CONTRACT SURFACE" "WARN"

# Case 4: CLI entrypoint with help/version/stream/exit evidence -> PASS.
cli_pass=$(make_tmpdir)
mkdir -p "$cli_pass/bin" "$cli_pass/tests" "$cli_pass/.github/workflows"
cat > "$cli_pass/bin/examplecli" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "usage: examplecli";;
  --version) echo "examplecli 1.0.0";;
  *) echo "run";;
esac
SH
chmod +x "$cli_pass/bin/examplecli"
cat > "$cli_pass/tests/test_cli.sh" <<'SH'
#!/usr/bin/env bash
examplecli --help
examplecli --version
# Contract checks cover exit code, stdout, stderr, and non-interactive mode.
SH
cat > "$cli_pass/.github/workflows/test.yml" <<'YAML'
name: test
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/test_cli.sh
YAML

cli_pass_out="$cli_pass/audit.out"
python3 "$AUDIT" --root "$cli_pass" > "$cli_pass_out"
assert_block_status "$cli_pass_out" "CLI CONTRACT SURFACE" "PASS"

# Script exits 0 even when findings surface (it's a reporter, not a gate).
python3 "$AUDIT" --root "$dirty" >/dev/null

echo "check audit smoke: ok"
