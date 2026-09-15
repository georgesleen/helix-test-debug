#!/usr/bin/env bash
# Load the cog in a real Steel-enabled helix. This is the only check that
# sees helix's own engine, which rejects spellings the standalone steel
# interpreter accepts: `(void)` in tail position compiles under steel 0.8.2
# and under the exact revision helix pins, yet helix refuses it. Building a
# matching interpreter does not close that gap; only helix does.
#
# Skips when no Steel-enabled hx is on PATH, so CI and stock-helix machines
# stay green.
set -euo pipefail

if ! command -v hx >/dev/null; then
  echo "helix-check: no hx on PATH, skipping"
  exit 0
fi

# The Steel build embeds its cog sources, so this string is a precise marker.
# Stock helix has no engine and would ignore the cog, making the check
# vacuous rather than failing.
if ! LC_ALL=C grep -aq "helix/commands.scm" \
  "$(readlink -f "$(command -v hx)")" 2>/dev/null; then
  echo "helix-check: hx has no Steel support, skipping"
  exit 0
fi

if ! command -v script >/dev/null; then
  echo "helix-check: no script(1) to allocate a pty, skipping"
  exit 0
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$workdir/config/helix/cogs"
cp test-debug.scm test-debug-rust.scm "$workdir/config/helix/cogs/"
cp -r test-debug "$workdir/config/helix/cogs/"
cat >"$workdir/config/helix/helix.scm" <<'EOF'
(require "cogs/test-debug.scm")
(provide test-debug
         test-run
         test-again
         test-doctor
         test-debug-failure
         test-cancel
         debug-variables
         debug-step-over
         debug-step-in
         debug-step-out
         debug-continue)
EOF
: >"$workdir/config/helix/init.scm"
printf 'fn main() {}\n' >"$workdir/probe.rs"

# A cog that fails to compile puts its error on screen during startup. The
# deadline matters more than the quit: helix owns the pty, so if it ignores
# the queued :q the check must still end.
output=$(cd "$workdir" && XDG_CONFIG_HOME="$workdir/config" \
  timeout 20 script -qec "hx probe.rs" /dev/null <<<$':q\r' 2>&1 || true)

if grep -qE 'error\[E[0-9]+\]|FreeIdentifier|BadSyntax|TailCall' <<<"$output"; then
  echo "helix-check: the cog failed to load"
  tr -s ' ' <<<"$output" |
    grep -oE '(error\[E[0-9]+\][^|]{0,80}|Cannot reference an identifier[^|]{0,60}|not supported: [^ ]+)' |
    head -5
  exit 1
fi

echo "helix-check: cog loads in helix"
