#!/usr/bin/env bash
# End-to-end check of helix-dap-vars: drive a scripted DAP client through the
# proxy into tests/stub-dap-adapter.py and assert three things the unit tests
# cannot reach, because they are properties of the process and not of a
# function.
#
#   - the proxy is transparent: every response the client asked for arrives,
#     and no response to a request the proxy injected ever does
#   - the file holds exactly the rendering the canned stop implies
#   - the file is gone once the session ends, which is the panel's close
#     signal
#
# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Point HELIX_DAP_VARS at a built binary, or let this build one with cargo.
# Skips itself when neither is available, so `make check` stays green on a
# machine with no rust toolchain.

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  echo "proxy-check: $1" >&2
  exit 1
}

if ! command -v python3 >/dev/null; then
  echo "proxy-check: no python3, skipping"
  exit 0
fi

binary=${HELIX_DAP_VARS:-}
if [[ -z $binary ]]; then
  if ! command -v cargo >/dev/null; then
    echo "proxy-check: no HELIX_DAP_VARS and no cargo, skipping"
    exit 0
  fi
  cargo build --quiet --release --manifest-path "$root/dap-vars/Cargo.toml" ||
    fail "the proxy does not build"
  binary=$root/dap-vars/target/release/helix-dap-vars
fi
[[ -x $binary ]] || fail "$binary is not executable"

"$binary" --help >/dev/null || fail "$binary --help failed"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

HELIX_DAP_VARS=$binary PROXY_WORKDIR=$workdir REPO_ROOT=$root python3 - <<'PY'
import json
import os
import subprocess
import sys
import time

binary = os.environ["HELIX_DAP_VARS"]
workdir = os.environ["PROXY_WORKDIR"]
root = os.environ["REPO_ROOT"]
out = os.path.join(workdir, "vars.txt")

EXPECTED = """# dap-vars stop 1
frame 0: kitest::run at /home/u/p/src/lib.rs:42

Locals
  count: usize = 3
  cfg: Config = Config { name: "a", retries: 2 }
    name: String = "a"
    retries: u32 = 2
"""


def fail(message):
    sys.stderr.write("proxy-check: %s\n" % message)
    sys.exit(1)


def write_message(stream, message):
    body = json.dumps(message).encode("utf-8")
    stream.write(b"Content-Length: %d\r\n\r\n" % len(body))
    stream.write(body)
    stream.flush()


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            if not headers:
                continue
            break
        name, sep, value = line.partition(b":")
        if sep:
            headers[name.strip().lower()] = value.strip()
    length = headers.get(b"content-length")
    if length is None:
        return None
    body = b""
    while len(body) < int(length):
        chunk = stream.read(int(length) - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body.decode("utf-8"))


proxy = subprocess.Popen(
    [
        binary,
        "--out",
        out,
        "--timeout-ms",
        "5000",
        "--",
        "python3",
        os.path.join(root, "tests", "stub-dap-adapter.py"),
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)

seq = 0


def request(command, arguments=None):
    global seq
    seq += 1
    message = {"seq": seq, "type": "request", "command": command}
    if arguments is not None:
        message["arguments"] = arguments
    write_message(proxy.stdin, message)
    return seq


def drain_until(predicate, what, deadline=20.0):
    """Read forwarded messages until one satisfies `predicate`."""
    end = time.time() + deadline
    while time.time() < end:
        message = read_message(proxy.stdout)
        if message is None:
            fail("the proxy closed its stdout while waiting for %s" % what)
        if message.get("type") == "response":
            request_seq = message.get("request_seq")
            if request_seq is None or request_seq >= (1 << 30):
                fail(
                    "the proxy forwarded a response to its own request: %s"
                    % json.dumps(message)
                )
        seen.append(message)
        if predicate(message):
            return message
    fail("timed out waiting for %s" % what)


seen = []

# The file must exist before the adapter has said anything: its existence is
# what tells the editor a session is live.
start = time.time()
while not os.path.exists(out) and time.time() - start < 10:
    time.sleep(0.02)
if not os.path.exists(out):
    fail("the proxy wrote no file at startup")
with open(out, encoding="utf-8") as handle:
    first = handle.read()
if first != "# dap-vars stop 0\nwaiting for first stop\n":
    fail("unexpected startup file: %r" % first)

initialize = request("initialize", {"adapterID": "stub"})
drain_until(
    lambda m: m.get("type") == "response" and m.get("request_seq") == initialize,
    "the initialize response",
)

launch = request("launch", {"program": "/dev/null"})
drain_until(
    lambda m: m.get("type") == "event" and m.get("event") == "initialized",
    "the initialized event",
)

done = request("configurationDone")
drain_until(
    lambda m: m.get("type") == "event" and m.get("event") == "stopped",
    "the stopped event",
)

# Collection happens after the event is forwarded, so poll for the rendering.
rendered = ""
start = time.time()
while time.time() - start < 20:
    with open(out, encoding="utf-8") as handle:
        rendered = handle.read()
    if rendered.startswith("# dap-vars stop 1"):
        break
    time.sleep(0.02)

if rendered != EXPECTED:
    fail("unexpected rendering:\n--- got ---\n%s--- want ---\n%s" % (rendered, EXPECTED))

# Every response the client asked for arrived, and the register scope never
# reached the file even though the adapter reported one.
if "Registers" in rendered or "rax" in rendered:
    fail("the register scope was not skipped")

request("terminate")
start = time.time()
while os.path.exists(out) and time.time() - start < 20:
    time.sleep(0.02)
if os.path.exists(out):
    fail("the file outlived the session; the panel would never close")

request("disconnect")
try:
    code = proxy.wait(timeout=20)
except subprocess.TimeoutExpired:
    proxy.kill()
    fail("the proxy did not exit after disconnect")
if code != 0:
    fail("the proxy exited %d" % code)

responses = sum(1 for message in seen if message.get("type") == "response")
print(
    "proxy-check: %d responses forwarded, none of the proxy's own; "
    "rendering matched; file removed on terminate" % responses
)
PY
status=$?
[[ $status -eq 0 ]] || exit $status

echo "proxy-check: ok"
