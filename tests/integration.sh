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
(provide debug-here
         dbgh
         run-here
         debug-again
         test-pick
         debug-doctor
         debug-breakpoint
         debug-breakpoints
         debug-failure
         debug-cancel
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

[[language]]
name = "c"

[language.debugger]
name = "lldb-dap"
transport = "stdio"
command = "lldb-dap"

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

# :run-here. Two things have to happen: the right test runs, which the
# fixture records to $FIXTURE_TEST_LOG, and the command reports its result
# on the statusline, which is the only place a raised error would stop it.
run_capture=$workdir/run.txt
rm -f "$ran_log"
LINGER=40 DEADLINE=70 start_session "$run_capture" ":$declaration" ":run-here"

waited=0
while [[ ! -s $ran_log ]]; do
  sleep 1
  waited=$((waited + 1))
  if [[ $waited -gt 45 ]]; then
    stop_session
    fail "run-here ran no test in 45s" "$run_capture"
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
    fail "run-here raised: $raised" "$run_capture"
  fi
  fail "run-here put no test result on the statusline in 30s" "$run_capture"
fi

ran=$(sort "$ran_log")
if [[ $ran != "$test_path" ]]; then
  fail "run-here should have run exactly $test_path, ran:
$ran" "$run_capture"
fi

if [[ $outcome != "test result: ok. 1 passed;" ]]; then
  fail "run-here reported \"$outcome\", not one passing test" "$run_capture"
fi

echo "integration-check: run-here reported $outcome"

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

# :debug-here. A started session means the test binary is alive and stopped
# by the adapter, which is what /proc reports.
debug_capture=$workdir/debug.txt
rm -f "$ran_log"
LINGER=60 DEADLINE=90 start_session "$debug_capture" ":$declaration" ":debug-here"

await_stopped "$debug_capture" debug-here

command_line=$(tr '\0' ' ' <"/proc/$stopped/cmdline")
status_line=$(grep -E '^(State|TracerPid):' "/proc/$stopped/status" | tr -s ' \t' ' ' | tr '\n' ' ')
echo "integration-check: debug-here stopped pid $stopped ($status_line) running $command_line"

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
# distinguishes this path from :debug-here.
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
LINGER=60 DEADLINE=90 start_session "$restore_capture" ":$declaration" ":debug-here"

await_stopped "$restore_capture" "debug-here after a restore"

sent=$(grep -o '"line":[0-9]*' "$adapter_log" | sort -u | tr '\n' ' ')
case " $sent " in
  *"\"line\":$breakpoint_line"*) ;;
  *) fail "helix sent the adapter breakpoints [$sent], not line $breakpoint_line" "$restore_capture" ;;
esac

echo "integration-check: the remembered breakpoint reached the adapter as $sent"

kill -9 "$tracer" 2>/dev/null || true
kill -9 "$stopped" 2>/dev/null || true
stop_session

# :debug-here on a line that is not in a test. The crate's own binary is
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
LINGER=60 DEADLINE=90 start_session "$program_capture" ":$program_line" ":debug-here"

await_stopped "$program_capture" "debug-here on a binary"

command_line=$(tr '\0' ' ' <"/proc/$stopped/cmdline")
echo "integration-check: debug-here on a non-test line stopped $command_line"

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

# :debug-here in a PlatformIO project. Unity marks nothing, so this proves
# the whole chain: the cursor names a function, a RUN_TEST call in the
# folder is what makes it a test, pio builds that folder's program with
# debug info forced on, and the breakpoint stops it. Skipped when pio is
# missing or its core directory has no native platform, because a cold one
# needs the network.
if ! command -v pio >/dev/null; then
  echo "integration-check: no pio on PATH, skipping the PlatformIO phase"
elif [[ ! -d ${PLATFORMIO_CORE_DIR:-$HOME/.platformio}/platforms/native ]]; then
  echo "integration-check: PlatformIO has no native platform installed, skipping"
else
  pio_fixture=$root/tests/pio-fixture
  pio_program=$pio_fixture/.pio/build/native/program
  pio_source=$pio_fixture/test/test_divider/test_divider.c
  pio_line=$(grep -n "^void test_halves(void)" "$pio_source" | cut -d: -f1)
  [[ -n $pio_line ]] || fail "no test_halves definition in $pio_source"

  pio_capture=$workdir/pio.txt
  export SOURCE_FILE=$pio_source
  binaries=$pio_program
  fixture=$pio_fixture
  LINGER=60 DEADLINE=90 start_session "$pio_capture" ":$pio_line" ":debug-here"

  await_stopped "$pio_capture" "debug-here in a PlatformIO project"

  command_line=$(tr '\0' ' ' <"/proc/$stopped/cmdline")
  echo "integration-check: debug-here stopped the Unity program $command_line"

  case " $command_line " in
    *" $pio_program "*) ;;
    *) fail "the stopped process is $command_line, not $pio_program" "$pio_capture" ;;
  esac

  kill -9 "$tracer" 2>/dev/null || true
  kill -9 "$stopped" 2>/dev/null || true
  stop_session

  # :test-pick in the same project. Registration is the authority, so the
  # overlay must list exactly the three tests a RUN_TEST call names and
  # leave the unregistered function out. The query selects the one test the
  # cursor is not in, which is what separates the pick from the cursor.
  pick_query=odd
  pick_name=test_halves_odd_rounds_toward_zero
  pio_pick_capture=$workdir/pio-pick.txt
  LINGER=60 DEADLINE=90 start_session "$pio_pick_capture" ":1" ":test-pick" "$pick_query"

  await_stopped "$pio_pick_capture" "test-pick in a PlatformIO project"

  listed=$(screen "$pio_pick_capture" | grep -o "[0-9]* tests" | head -1 || true)
  if [[ $listed != "3 tests" ]]; then
    fail "the overlay listed \"$listed\", not the three registered tests" "$pio_pick_capture"
  fi

  if ! screen "$pio_pick_capture" | grep -q "$pick_name"; then
    fail "the overlay never showed $pick_name" "$pio_pick_capture"
  fi

  echo "integration-check: test-pick listed $listed and launched $pick_name"

  kill -9 "$tracer" 2>/dev/null || true
  kill -9 "$stopped" 2>/dev/null || true
  stop_session
fi

# :debug-here in an embedded crate. There is no probe attached, so the
# adapter is the stub in tests/stub-dap-adapter.py: it answers enough DAP for
# helix to complete a launch and logs every message it receives. That proves
# what the cog controls -- the launch it builds and the breakpoint helix
# delivers -- and nothing about flashing, which is probe-rs's job.
#
# The fixture declares a probe-rs runner but no [build] target, so it still
# compiles for the host and the ELF the launch names really exists.
firmware_fixture=$root/tests/firmware-fixture
firmware_source=$firmware_fixture/src/main.rs
firmware_line=$(grep -n "ticks += 1" "$firmware_source" | cut -d: -f1)
[[ -n $firmware_line ]] || fail "no ticks line in $firmware_source"

# Both languages point at the stub here: an embedded rust crate is a .rs
# buffer and a cross CMake project is a .c one, and helix picks the adapter
# per language.
firmware_languages() {
  local language=$1
  cat <<EOF
[[language]]
name = "$language"

[language.debugger]
name = "stub"
transport = "stdio"
command = "$root/tests/stub-dap-adapter.py"

[[language.debugger.templates]]
name = "firmware"
request = "launch"
completion = [
  { name = "elf", completion = "filename" },
  { name = "chip" },
]
[language.debugger.templates.args]
chip = "{1}"
flashingConfig = { flashingEnabled = true, haltAfterReset = true }
coreConfigs = [ { coreIndex = 0, programBinary = "{0}" } ]
EOF
}

{
  firmware_languages rust
  echo
  firmware_languages c
} >"$config/helix/languages.toml.firmware"
cp "$config/helix/languages.toml" "$workdir/languages.toml.host"
cp "$config/helix/languages.toml.firmware" "$config/helix/languages.toml"

export DAP_STUB_LOG=$workdir/dap-stub.jsonl
: >"$DAP_STUB_LOG"
(cd "$firmware_fixture" && cargo build --quiet) >"$workdir/prewarm-firmware.txt" 2>&1 ||
  fail "the firmware fixture does not build" "$workdir/prewarm-firmware.txt"

firmware_capture=$workdir/firmware.txt
export SOURCE_FILE=$firmware_source
fixture=$firmware_fixture
LINGER=30 DEADLINE=60 start_session "$firmware_capture" ":$firmware_line" ":debug-here"

waited=0
while ! grep -q '"command": *"setBreakpoints"' "$DAP_STUB_LOG" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
  if [[ $waited -gt 45 ]]; then
    stop_session
    fail "helix sent the adapter no setBreakpoints in 45s" "$firmware_capture"
  fi
done
stop_session
cp "$workdir/languages.toml.host" "$config/helix/languages.toml"

launch=$(grep '"command": *"launch"' "$DAP_STUB_LOG" | tail -1)
[[ -n $launch ]] || fail "the adapter received no launch request" "$firmware_capture"

for expected in '"chip": *"RP235x"' 'firmware-fixture/target/debug/firmware-fixture' '"flashingEnabled": *true'; do
  grep -qE "$expected" <<<"$launch" ||
    fail "the launch is missing $expected: $launch" "$firmware_capture"
done

breakpoints=$(grep '"command": *"setBreakpoints"' "$DAP_STUB_LOG" | tail -1)
grep -qE "\"line\": *$firmware_line" <<<"$breakpoints" ||
  fail "helix sent no breakpoint on line $firmware_line: $breakpoints" "$firmware_capture"

echo "integration-check: the embedded launch named RP235x and helix sent a breakpoint on line $firmware_line"

# :debug-here in a cross-compiled CMake project, which is how most firmware
# is actually built: Zephyr, ESP-IDF, the Pico SDK and CubeMX output are all
# CMake underneath. The image is found through CMake's own file API and by
# the target that owns the cursor source. The fixture also builds a static
# library and an SDK-like executable tool; neither may be picked.
if ! command -v arm-none-eabi-gcc >/dev/null; then
  echo "integration-check: no arm-none-eabi-gcc, skipping the CMake firmware phase"
else
  cmake_fixture=$root/tests/cmake-firmware-fixture
  cmake_source=$cmake_fixture/blinky.c
  cmake_line=$(grep -n "ticks += halve" "$cmake_source" | cut -d: -f1)
  [[ -n $cmake_line ]] || fail "no ticks line in $cmake_source"

  rm -rf "$cmake_fixture/build"
  (cd "$cmake_fixture" && cmake -S . -B build \
    -DCMAKE_TOOLCHAIN_FILE=toolchain-arm.cmake -DCMAKE_BUILD_TYPE=Debug) \
    >"$workdir/cmake-configure.txt" 2>&1 ||
    fail "the CMake firmware fixture does not configure" "$workdir/cmake-configure.txt"

  cp "$config/helix/languages.toml.firmware" "$config/helix/languages.toml"
  : >"$DAP_STUB_LOG"
  cmake_capture=$workdir/cmake-firmware.txt
  export SOURCE_FILE=$cmake_source
  fixture=$cmake_fixture
  LINGER=40 DEADLINE=70 start_session "$cmake_capture" ":$cmake_line" ":debug-here"

  waited=0
  while ! grep -q '"command": *"setBreakpoints"' "$DAP_STUB_LOG" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [[ $waited -gt 50 ]]; then
      stop_session
      fail "no setBreakpoints for the CMake firmware in 50s" "$cmake_capture"
    fi
  done
  stop_session
  cp "$workdir/languages.toml.host" "$config/helix/languages.toml"

  cmake_launch=$(grep '"command": *"launch"' "$DAP_STUB_LOG" | tail -1)
  grep -q "build/blinky.elf" <<<"$cmake_launch" ||
    fail "the launch does not name the executable the file API reported: $cmake_launch" \
      "$cmake_capture"
  if grep -qE "libsupport|sdk_tool" <<<"$cmake_launch"; then
    fail "the launch named an executable that does not own blinky.c: $cmake_launch" \
      "$cmake_capture"
  fi
  grep -qE "\"line\": *$cmake_line" <<<"$(grep '"command": *"setBreakpoints"' "$DAP_STUB_LOG" | tail -1)" ||
    fail "no breakpoint on line $cmake_line" "$cmake_capture"

  echo "integration-check: CMake selected blinky.c's image among two executables and sent a breakpoint on line $cmake_line"
fi

echo "integration-check: rust, C and C++, host and firmware, all work in helix"
