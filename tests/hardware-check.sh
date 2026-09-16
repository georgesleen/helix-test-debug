#!/usr/bin/env bash
# Drive :debug-here against a real MCU, through a real DAP adapter, in a
# real helix. The integration check proves what the editor *sent* to a stub;
# this proves the rest: the image is selected, flashed, the breakpoint binds
# in silicon, and target memory is readable.
#
# Nothing here is specific to a board. The chip and the adapter are the
# launch template's business, and the project is an input:
#
#   HARDWARE_CHIP     probe-rs target name            (default RP235x)
#   HARDWARE_ADAPTER  adapter argv                    (default "probe-rs dap-server")
#   HARDWARE_PROJECT  CMake source directory          (default tests/pico-sdk-fixture)
#   HARDWARE_SOURCE   file to stop in, under it       (default main.c)
#   HARDWARE_MARKER   line to stop on, a grep pattern (default "ticks += 1")
#   HARDWARE_CMAKE    extra configure arguments
#
# So an ESP32, an STM32 or anything else needs no code here: point these at
# your project and name your chip. The defaults build a Pico SDK project for
# a Pico 2 over a Raspberry Pi Debug Probe.
#
# Not part of `make check`: it needs a probe and a board physically
# attached. It skips itself when anything it drives is missing, so running
# it without hardware is harmless.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
default_project=$root/tests/pico-sdk-fixture

chip=${HARDWARE_CHIP:-RP235x}
adapter=${HARDWARE_ADAPTER:-probe-rs dap-server}
project=${HARDWARE_PROJECT:-$default_project}
source_name=${HARDWARE_SOURCE:-main.c}
marker=${HARDWARE_MARKER:-ticks += 1}
extra_cmake=${HARDWARE_CMAKE:-}

project=$(cd "$project" && pwd)
source_file=$project/$source_name
build=$project/build
read -r -a adapter_argv <<<"$adapter"

skip() {
  echo "hardware-check: $1, skipping"
  exit 0
}

for tool in hx cmake script setsid python3 "${adapter_argv[0]}"; do
  command -v "$tool" >/dev/null || skip "no $tool on PATH"
done

# Stock helix has no Steel engine and would ignore the cog, making every
# assertion below vacuous rather than failing.
if ! LC_ALL=C grep -aq "helix/commands.scm" \
  "$(readlink -f "$(command -v hx)")" 2>/dev/null; then
  skip "hx has no Steel support"
fi

[[ -f $project/CMakeLists.txt ]] || skip "$project is not a CMake project"
[[ -f $source_file ]] || skip "$source_file does not exist"

# probe-rs is the default adapter and can say whether a probe is there at
# all. Another adapter gets no such interrogation: if it cannot reach the
# board, its own launch failure is the report.
if [[ ${adapter_argv[0]} == probe-rs ]]; then
  grep -q "^\[0\]" <<<"$(probe-rs list 2>&1 || true)" || skip "no debug probe attached"
fi

# The defaults build the bundled Pico fixture, which needs the SDK and the
# cross compiler. A project supplied by the caller brings its own.
if [[ $project == "$default_project" ]]; then
  command -v arm-none-eabi-gcc >/dev/null || skip "no arm-none-eabi-gcc on PATH"
  [[ -d ${PICO_SDK_PATH:-} ]] || skip "PICO_SDK_PATH is unset or missing; run inside nix develop"

  # The SDK fetches and builds picotool unless an install of exactly its
  # version is findable, which is the only step that would need the
  # network. The packaged one matches, so it is pointed at explicitly.
  picotool_cmake=
  if command -v picotool >/dev/null; then
    candidate=$(dirname "$(dirname "$(readlink -f "$(command -v picotool)")")")/lib/cmake/picotool
    [[ -d $candidate ]] && picotool_cmake=$candidate
  fi
  [[ -n $picotool_cmake ]] || skip "no packaged picotool with cmake files; the SDK would fetch one"

  # PICO_DEOPTIMIZED_DEBUG is the SDK's own switch. Without it a Debug build
  # is -Og and the stop lands on whichever header was inlined at that
  # address: a real stop, but not one assertable against a source line.
  extra_cmake="-DPICO_BOARD=pico2 -DPICO_DEOPTIMIZED_DEBUG=1 -Dpicotool_DIR=$picotool_cmake $extra_cmake"
fi

workdir=$(mktemp -d)
config=$workdir/config
requests=$workdir/dap-requests
responses=$workdir/dap-responses
session_pid_file=$workdir/session.pid

descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    descendants "$child"
    echo "$child"
  done
}

# script(1) gives helix its own session and timeout(1) its own process
# group, so the pty tree cannot be killed as one group.
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

cleanup() {
  stop_session
  rm -rf "$workdir"
}
trap cleanup EXIT

screen() {
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][A-B0-9]//g' -e 'y/\r/\n/' "$1" |
    tr -s ' \n'
}

fail() {
  echo "hardware-check: $1" >&2
  local capture
  for capture in "${@:2}"; do
    [[ -s $capture ]] || continue
    echo "--- $(basename "$capture")" >&2
    screen "$capture" | tail -40 >&2
  done
  exit 1
}

line=$(grep -n "$marker" "$source_file" | head -1 | cut -d: -f1)
[[ -n $line ]] || fail "no line matching '$marker' in $source_file"

# Configured here rather than left to the cog so a failure to configure is
# reported as itself. The cog reconfigures the same directory on launch.
rm -rf "$build"
# shellcheck disable=SC2086
cmake -S "$project" -B "$build" -DCMAKE_BUILD_TYPE=Debug $extra_cmake \
  >"$workdir/configure.txt" 2>&1 ||
  fail "$project does not configure" "$workdir/configure.txt"

mkdir -p "$config/helix/cogs"
cp "$root/test-debug.scm" "$root/test-debug-rust.scm" "$root/test-debug-cpp.scm" \
  "$root/test-debug-picker.scm" "$config/helix/cogs/"
cp -r "$root/test-debug" "$config/helix/cogs/"
cat >"$config/helix/helix.scm" <<'EOF'
(require "cogs/test-debug.scm")
(provide debug-here debug-continue debug-variables)
EOF
# This Steel build loads helix.scm only once init.scm exists. Without it the
# commands are simply absent, which reads as a cog error and is not one.
: >"$config/helix/init.scm"

# The adapter is driven through tee so the DAP exchange can be read back.
# The breakpoint never appears in the launch: probe-rs takes none, so helix
# sends it separately, which is the ordering this check exists to prove.
cat >"$workdir/adapter.sh" <<EOF
#!/usr/bin/env bash
tee "$requests" | $adapter "\$@" | tee "$responses"
EOF
chmod +x "$workdir/adapter.sh"

# haltAfterReset is what makes the core stop before main, so the breakpoint
# is programmed while it is halted rather than raced against a running one.
# A template for another adapter may name its target differently; the cog
# passes the image and the chip and does not care.
cat >"$config/helix/languages.toml" <<EOF
[[language]]
name = "c"

[language.debugger]
name = "hardware-check-adapter"
transport = "stdio"
command = "$workdir/adapter.sh"

[[language.debugger.templates]]
name = "firmware"
request = "launch"
completion = [
  { name = "elf", completion = "filename" },
  { name = "chip" },
]
[language.debugger.templates.args]
chip = "$chip"
flashingConfig = { flashingEnabled = true, haltAfterReset = true }
coreConfigs = [ { coreIndex = 0, programBinary = "{0}" } ]
EOF

cat >"$workdir/session.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo $$ >"$SESSION_PID_FILE"
{
  # Helix swallows keys sent before its first paint settles.
  sleep 4
  printf ':%s\r' "$LINE"
  sleep 2
  printf ':debug-here\r'
  # Building and flashing both happen inside this wait.
  sleep 30
  printf ':debug-continue\r'
  sleep 6
  printf ':debug-variables\r'
  sleep 8
  printf ':q!\r'
  sleep 2
} | timeout -k 5 90 script -qec "hx $SOURCE_FILE" /dev/null
EOF

export XDG_CONFIG_HOME=$config
export SESSION_PID_FILE=$session_pid_file
export SOURCE_FILE=$source_file
export LINE=$line

capture=$workdir/session.txt
: >"$session_pid_file"
(cd "$project" && setsid --fork bash "$workdir/session.sh" >"$capture" 2>&1 </dev/null)
waited=0
while [[ ! -s $session_pid_file ]]; do
  sleep 0.2
  waited=$((waited + 1))
  [[ $waited -gt 50 ]] && fail "the pty session did not start" "$capture"
done

# Wait for the stop that matters. The first stopped event is the reset halt,
# so this waits for the breakpoint one specifically.
waited=0
while ! grep -aq '"reason":"breakpoint"' "$responses" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
  if [[ $waited -gt 70 ]]; then
    stop_session
    fail "no breakpoint stop from the target in 70s" "$capture"
  fi
done
sleep 6
stop_session

python3 "$root/tests/hardware-assert.py" \
  "$requests" "$responses" "$build" "$source_file" "$line" ||
  fail "the hardware exchange is not what it should be" "$capture"
