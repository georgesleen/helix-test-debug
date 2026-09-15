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
# The cog stores breakpoints beside the crate it is debugging, so this one
# lands in the fixture and is removed on the way out.
breakpoint_store=$fixture/.helix/test-debug-breakpoints
adapter_log=$workdir/adapter.jsonl

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
  rm -rf "$fixture/.helix"
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
   "$cog_dir/test-debug-cpp.scm" "$cog_dir/test-debug-picker.scm" \
   "$config/helix/cogs/"
cp -r "$cog_dir/test-debug" "$config/helix/cogs/"
cat >"$config/helix/helix.scm" <<'EOF'
(require "cogs/test-debug.scm")
(provide test-debug
         test-run
         test-again
         test-pick
         test-doctor
         debug-breakpoint
         debug-breakpoints
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
# The adapter is wrapped so the breakpoints helix sends at session start can
# be read back. tee passes everything through untouched.
cat >"$workdir/adapter.sh" <<EOF
#!/usr/bin/env bash
tee -a "$adapter_log" | lldb-dap "\$@"
EOF
chmod +x "$workdir/adapter.sh"

cat >"$config/helix/languages.toml" <<EOF
[[language]]
name = "rust"

[language.debugger]
name = "lldb-dap"
transport = "stdio"
command = "$workdir/adapter.sh"

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

[[language.debugger.templates]]
name = "program at line"
request = "launch"
completion = [
  { name = "binary", completion = "filename" },
  { name = "source file" },
  { name = "line" },
]
args = { program = "{0}", preRunCommands = [ "breakpoint set --file {1} --line {2}" ] }
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

# Wait for a test binary stopped by a debugger, which is what a started
# session looks like from /proc. Sets $stopped, $tracer and $seen.
await_stopped() {
  local capture=$1
  local label=$2
  stopped=
  tracer=
  seen=
  local waited=0
  while [[ $waited -lt 60 ]]; do
    for pid in $(pgrep -f "$binaries" 2>/dev/null || true); do
      seen=$pid
      state=$(awk '$1 == "State:" { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
      tracer=$(awk '$1 == "TracerPid:" { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
      if [[ $state == t && -n ${tracer:-} && $tracer != 0 ]]; then
        stopped=$pid
        return 0
      fi
    done
    sleep 1
    waited=$((waited + 1))
  done

  local raised
  raised=$(engine_error "$capture")
  if [[ -n $raised ]]; then
    fail "$label raised: $raised" "$capture"
  fi
  if [[ -n $seen ]]; then
    fail "$label left $binaries* running but never stopped by a debugger" "$capture"
  fi
  fail "$label started no debug session in 60s" "$capture"
}

# :test-debug. A started session means the test binary is alive and stopped
# by the adapter, which is what /proc reports.
debug_capture=$workdir/debug.txt
rm -f "$ran_log"
LINGER=60 DEADLINE=90 start_session "$debug_capture" ":$declaration" ":test-debug"

await_stopped "$debug_capture" test-debug

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

# :test-pick. The overlay is driven by typing: session.sh ends every key
# with a carriage return, so one key sends the query and accepts it. The
# test picked is deliberately not the one under the cursor, which is what
# distinguishes this path from :test-debug.
pick_path=${test_path}_negative_values
pick_query=doubles_n
pick_capture=$workdir/pick.txt
rm -f "$ran_log"
LINGER=60 DEADLINE=90 start_session "$pick_capture" ":test-pick" "$pick_query"

await_stopped "$pick_capture" test-pick

command_line=$(tr '\0' ' ' <"/proc/$stopped/cmdline")
echo "integration-check: test-pick stopped pid $stopped running $command_line"

case " $command_line " in
  *" $pick_path "*) ;;
  *) fail "test-pick launched $command_line, not $pick_path" "$pick_capture" ;;
esac

kill -9 "$tracer" 2>/dev/null || true
kill -9 "$stopped" 2>/dev/null || true
stop_session

# :debug-breakpoint. A breakpoint set in one editor has to reach the adapter
# in the next one, which is the whole point of storing it. Asserting the
# store alone would pass even if nothing was ever placed in helix, so the
# evidence is what helix sent the debugger: the wrapped adapter's log.
rm -rf "$fixture/.helix"
breakpoint_line=$((declaration + 2))
bp_capture=$workdir/breakpoint.txt
LINGER=10 DEADLINE=40 start_session "$bp_capture" ":$breakpoint_line" ":debug-breakpoint"

waited=0
while [[ ! -s $breakpoint_store ]]; do
  sleep 1
  waited=$((waited + 1))
  if [[ $waited -gt 30 ]]; then
    stop_session
    fail "debug-breakpoint wrote no store in 30s" "$bp_capture"
  fi
done
stop_session

stored=$(cat "$breakpoint_store")
if [[ $stored != "src/lib.rs:$breakpoint_line" ]]; then
  fail "the store holds \"$stored\", not src/lib.rs:$breakpoint_line" "$bp_capture"
fi

echo "integration-check: debug-breakpoint remembered $stored"

# A fresh editor: nothing is toggled by hand, so a breakpoint reaching the
# adapter can only have come from the store.
: >"$adapter_log"
rm -f "$ran_log"
restore_capture=$workdir/restore.txt
LINGER=60 DEADLINE=90 start_session "$restore_capture" ":$declaration" ":test-debug"

await_stopped "$restore_capture" "test-debug after a restore"

sent=$(grep -o '"line":[0-9]*' "$adapter_log" | sort -u | tr '\n' ' ')
case " $sent " in
  *"\"line\":$breakpoint_line"*) ;;
  *) fail "helix sent the adapter breakpoints [$sent], not line $breakpoint_line" "$restore_capture" ;;
esac

echo "integration-check: the remembered breakpoint reached the adapter as $sent"

kill -9 "$tracer" 2>/dev/null || true
kill -9 "$stopped" 2>/dev/null || true
stop_session

# :test-debug on a line that is not in a test. The crate's own binary is
# what has to be stopped, not a test binary, so the assertion is on which
# executable the debugger is holding.
program_capture=$workdir/program.txt
program_binary=$fixture/target/debug/fixture
program_line=$(grep -n "let value" "$fixture/src/main.rs" | cut -d: -f1)
[[ -n $program_line ]] || fail "no let value line in src/main.rs"

(cd "$fixture" && cargo build --quiet) >"$workdir/prewarm-bin.txt" 2>&1 ||
  fail "the fixture binary does not build" "$workdir/prewarm-bin.txt"

# The session opens main.rs rather than lib.rs, and what counts as the
# process to wait for is the binary rather than a test binary.
export SOURCE_FILE=$fixture/src/main.rs
binaries=$program_binary
LINGER=60 DEADLINE=90 start_session "$program_capture" ":$program_line" ":test-debug"

await_stopped "$program_capture" "test-debug on a binary"

command_line=$(tr '\0' ' ' <"/proc/$stopped/cmdline")
echo "integration-check: test-debug on a non-test line stopped $command_line"

case " $command_line " in
  *" $program_binary "*) ;;
  *) fail "the stopped process is $command_line, not $program_binary" "$program_capture" ;;
esac

case " $command_line " in
  *--exact*) fail "the binary was launched with test arguments: $command_line" "$program_capture" ;;
  *) ;;
esac

kill -9 "$tracer" 2>/dev/null || true
kill -9 "$stopped" 2>/dev/null || true
stop_session

echo "integration-check: tests, the picker, breakpoints and the binary path work in helix"
