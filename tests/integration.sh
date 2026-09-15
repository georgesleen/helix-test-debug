#!/usr/bin/env bash
# Run the cog's commands in a real Steel-enabled helix against the fixture
# crate. Steel compiles a function body lazily, so an error inside a command
# surfaces only when that command runs: neither the unit suite, the stub
# compile check, nor the load check in helix-check.sh reaches it.
#
# Skips when anything it drives is missing, so CI and stock-helix machines
# stay green.
#
# TEST_DEBUG_COG_DIR overrides where the two cog files are copied from,
# which is how a sabotaged copy is fed in without touching the repo.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cog_dir=${TEST_DEBUG_COG_DIR:-$root}
fixture=$root/tests/fixture
source_file=$fixture/src/lib.rs
binaries=$fixture/target/debug/deps/fixture-

# The test driven through the editor, and the sibling whose name extends it
# so a filter that is not --exact drags it along.
test_path=inner::tests::doubles

skip() {
  echo "integration-check: $1, skipping"
  exit 0
}

if ! command -v hx >/dev/null; then
  skip "no hx on PATH"
fi

# The Steel build embeds its cog sources, so this string is a precise marker.
# Stock helix has no engine and would ignore the cog, making this vacuous.
if ! LC_ALL=C grep -aq "helix/commands.scm" \
  "$(readlink -f "$(command -v hx)")" 2>/dev/null; then
  skip "hx has no Steel support"
fi

for tool in cargo lldb-dap script setsid; do
  command -v "$tool" >/dev/null || skip "no $tool on PATH"
done

workdir=$(mktemp -d)
config=$workdir/config
ran_log=$workdir/ran.log
session_pid_file=$workdir/session.pid

# Pids under a process, deepest first. timeout(1) puts itself in its own
# process group and script(1) gives helix its own session, so the pty tree
# cannot be killed as one group; walking it also keeps this off any helix
# the user is running.
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    descendants "$child"
    echo "$child"
  done
}

# Kill the pty tree of the session in flight, deepest process first.
stop_session() {
  [[ -s $session_pid_file ]] || return 0
  local leader pid
  leader=$(cat "$session_pid_file")
  : >"$session_pid_file"
  for pid in $(descendants "$leader") "$leader"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 1
}

# Everything this check started: the pty tree, which holds the adapter and
# the test binary, then any test binary the adapter left detached.
cleanup() {
  local pid tracer
  stop_session
  for pid in $(pgrep -f "$binaries" 2>/dev/null || true); do
    tracer=$(awk '$1 == "TracerPid:" { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
    if [[ -n ${tracer:-} && $tracer != 0 ]]; then
      kill -9 "$tracer" 2>/dev/null || true
    fi
    kill -9 "$pid" 2>/dev/null || true
  done
  rm -rf "$workdir"
}
trap cleanup EXIT

# Screen capture with the escape sequences and carriage returns taken out.
# The pty redraws over itself, so this is readable but not tidy.
screen() {
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][A-B0-9]//g' -e 'y/\r/\n/' "$1" |
    tr -s ' \n'
}

fail() {
  local message=$1
  shift
  echo "integration-check: $message" >&2
  local capture
  for capture in "$@"; do
    [[ -s $capture ]] || continue
    echo "--- $(basename "$capture")" >&2
    screen "$capture" | tail -40 >&2
  done
  exit 1
}

# An engine error raised inside a command body, as it lands on screen.
engine_error() {
  screen "$1" |
    grep -oE 'error\[E[0-9]+\][^|]{0,60}|TailCall[^|]{0,40}|FreeIdentifier[^|]{0,40}|not supported: [^ ]+' |
    head -1 || true
}

mkdir -p "$config/helix/cogs"
cp "$cog_dir/test-debug.scm" "$cog_dir/test-debug-rust.scm" \
   "$cog_dir/test-debug-cpp.scm" "$config/helix/cogs/"
cp -r "$cog_dir/test-debug" "$config/helix/cogs/"
cat >"$config/helix/helix.scm" <<'EOF'
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
: >"$config/helix/init.scm"

# The template the cog drives, as documented in README.md.
cat >"$config/helix/languages.toml" <<'EOF'
[[language]]
name = "rust"

[language.debugger]
name = "lldb-dap"
transport = "stdio"
command = "lldb-dap"

[[language.debugger.templates]]
name = "cargo test at line"
request = "launch"
completion = [
  { name = "test binary", completion = "filename" },
  { name = "test filter" },
  { name = "source file" },
  { name = "line" },
]
args = { program = "{0}", args = [ "{1}", "--exact", "--include-ignored", "--test-threads=1", "--nocapture" ], preRunCommands = [ "breakpoint set --file {2} --line {3}" ] }
EOF

# The line the cursor goes to: the test's declaration, which is what a user
# would be looking at.
declaration=$(grep -n "fn ${test_path##*::}()" "$source_file" | cut -d: -f1)
[[ -n $declaration ]] || fail "no ${test_path##*::} declaration in $source_file"

export CARGO_NET_OFFLINE=1
export XDG_CONFIG_HOME=$config
export FIXTURE_TEST_LOG=$ran_log

# Build up front so the editor's own build is a no-op: this check is about
# the command paths, not about cargo's cold cache.
(cd "$fixture" && cargo test --lib --no-run --quiet) >"$workdir/prewarm.txt" 2>&1 ||
  fail "the fixture crate does not build" "$workdir/prewarm.txt"

# The pty session. Keys are fed with pauses because helix reads stdin as it
# comes, and the deadline matters more than the quit: helix owns the pty, so
# if it ignores the queued :q! the session must still end.
cat >"$workdir/session.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo $$ >"$SESSION_PID_FILE"
{
  # Helix needs longer than its first paint before it reads reliably: a
  # keystroke sent too early is swallowed, which showed up as the cursor
  # still being on line 1 when the command ran.
  sleep 4
  for key in "$@"; do
    printf '%s\r' "$key"
    sleep 2
  done
  sleep "$LINGER"
  printf ':q!\r'
  sleep 1
} | timeout -k 5 "$DEADLINE" script -qec "hx $SOURCE_FILE" /dev/null
EOF

export SESSION_PID_FILE=$session_pid_file
export SOURCE_FILE=$source_file

start_session() {
  local capture=$1
  shift
  : >"$session_pid_file"
  # setsid --fork returns at once and leaves the session parented to init,
  # so this shell has no job to report on when cleanup kills it. The pid
  # file, not $!, names the tree.
  (cd "$fixture" && setsid --fork bash "$workdir/session.sh" "$@" \
    >"$capture" 2>&1 </dev/null)
  local waited=0
  while [[ ! -s $session_pid_file ]]; do
    sleep 0.2
    waited=$((waited + 1))
    if [[ $waited -gt 50 ]]; then
      fail "the pty session did not start" "$capture"
    fi
  done
}

# :test-run. Two things have to happen: the right test runs, which the
# fixture records to $FIXTURE_TEST_LOG, and the command reports its result
# on the statusline, which is the only place a raised error would stop it.
run_capture=$workdir/run.txt
rm -f "$ran_log"
LINGER=40 DEADLINE=70 start_session "$run_capture" ":$declaration" ":test-run"

waited=0
while [[ ! -s $ran_log ]]; do
  sleep 1
  waited=$((waited + 1))
  if [[ $waited -gt 45 ]]; then
    stop_session
    fail "test-run ran no test in 45s" "$run_capture"
  fi
done

outcome=
waited=0
while [[ $waited -lt 30 ]]; do
  outcome=$(screen "$run_capture" | grep -o "test result:[^;]*;" | tail -1 || true)
  if [[ -n $outcome ]]; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
stop_session

if [[ -z $outcome ]]; then
  raised=$(engine_error "$run_capture")
  if [[ -n $raised ]]; then
    fail "test-run raised: $raised" "$run_capture"
  fi
  fail "test-run put no test result on the statusline in 30s" "$run_capture"
fi

ran=$(sort "$ran_log")
if [[ $ran != "$test_path" ]]; then
  fail "test-run should have run exactly $test_path, ran:
$ran" "$run_capture"
fi

if [[ $outcome != "test result: ok. 1 passed;" ]]; then
  fail "test-run reported \"$outcome\", not one passing test" "$run_capture"
fi

echo "integration-check: test-run reported $outcome"

# :test-debug. A started session means the test binary is alive and stopped
# by the adapter, which is what /proc reports.
debug_capture=$workdir/debug.txt
rm -f "$ran_log"
LINGER=60 DEADLINE=90 start_session "$debug_capture" ":$declaration" ":test-debug"

stopped=
tracer=
seen=
waited=0
while [[ $waited -lt 60 ]]; do
  for pid in $(pgrep -f "$binaries" 2>/dev/null || true); do
    seen=$pid
    state=$(awk '$1 == "State:" { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
    tracer=$(awk '$1 == "TracerPid:" { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
    if [[ $state == t && -n ${tracer:-} && $tracer != 0 ]]; then
      stopped=$pid
      break 2
    fi
  done
  sleep 1
  waited=$((waited + 1))
done

if [[ -z $stopped ]]; then
  raised=$(engine_error "$debug_capture")
  if [[ -n $raised ]]; then
    fail "test-debug raised: $raised" "$debug_capture"
  fi
  if [[ -n $seen ]]; then
    fail "test-debug left $binaries* running but never stopped by a debugger" "$debug_capture"
  fi
  fail "test-debug started no debug session in 60s" "$debug_capture"
fi

command_line=$(tr '\0' ' ' <"/proc/$stopped/cmdline")
status_line=$(grep -E '^(State|TracerPid):' "/proc/$stopped/status" | tr -s ' \t' ' ' | tr '\n' ' ')
echo "integration-check: test-debug stopped pid $stopped ($status_line) running $command_line"

for expected in "$test_path" --exact --include-ignored; do
  case " $command_line " in
    *" $expected "*) ;;
    *) fail "the stopped process was launched without $expected: $command_line" "$debug_capture" ;;
  esac
done

if [[ -s $ran_log ]]; then
  fail "the test ran past the breakpoint: $(tr '\n' ' ' <"$ran_log")" "$debug_capture"
fi

kill -9 "$tracer" 2>/dev/null || true
kill -9 "$stopped" 2>/dev/null || true
stop_session

echo "integration-check: test-run and test-debug work in helix"
