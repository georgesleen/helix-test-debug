#!/usr/bin/env python3
"""A stub debug adapter that records what the editor sends it.

Stands in for `probe-rs dap-server` when no probe and no board are attached.
It speaks the minimum Debug Adapter Protocol needed for helix to carry a
launch all the way through `configurationDone`, and appends every message it
receives to $DAP_STUB_LOG, one JSON object per line. That log is the whole
point: it is evidence of the launch arguments the cog built and of the
breakpoints helix delivered.

It flashes nothing and runs nothing. What it does inspect is canned: a
single stopped frame with a fixed set of scopes and variables, so the
variables proxy can be checked against an exact expected rendering. See
stubs/README-dap.md.
"""

import json
import os
import sys

# Requests that need a body. Everything else gets a bare success, so helix
# never waits on a response the stub forgot to implement.
THREADS = [{"id": 1, "name": "stub"}]

# The canned stop. One frame, one scope worth showing and one that must be
# skipped because it holds registers, one expandable variable. tests/
# proxy-check.sh asserts the exact text helix-dap-vars renders from this.
FRAMES = [
    {
        "id": 1000,
        "name": "kitest::run",
        "line": 42,
        "column": 1,
        "source": {"name": "lib.rs", "path": "/home/u/p/src/lib.rs"},
    }
]

SCOPES = [
    {"name": "Locals", "variablesReference": 2, "presentationHint": "locals"},
    {"name": "Registers", "variablesReference": 3, "presentationHint": "registers"},
]

VARIABLES = {
    2: [
        {"name": "count", "type": "usize", "value": "3", "variablesReference": 0},
        {
            "name": "cfg",
            "type": "Config",
            "value": 'Config { name: "a", retries: 2 }',
            "variablesReference": 5,
        },
    ],
    3: [{"name": "rax", "type": "u64", "value": "0", "variablesReference": 0}],
    5: [
        {"name": "name", "type": "String", "value": '"a"', "variablesReference": 0},
        {"name": "retries", "type": "u32", "value": "2", "variablesReference": 0},
    ],
}


def read_message(stream):
    """Read one `Content-Length`-framed message. None on EOF or a bad frame."""
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            if not headers:
                continue  # stray blank line between frames
            break
        name, sep, value = line.partition(b":")
        if sep:
            headers[name.strip().lower()] = value.strip()

    raw_length = headers.get(b"content-length")
    if raw_length is None:
        return None
    try:
        length = int(raw_length)
    except ValueError:
        return None

    body = b""
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def write_message(stream, message):
    body = json.dumps(message).encode("utf-8")
    stream.write(b"Content-Length: %d\r\n\r\n" % len(body))
    stream.write(body)
    stream.flush()


class Stub:
    def __init__(self, stdin, stdout, log):
        self.stdin = stdin
        self.stdout = stdout
        self.log = log
        self.seq = 0

    def next_seq(self):
        self.seq += 1
        return self.seq

    def record(self, message):
        if self.log is None:
            return
        self.log.write(json.dumps(message) + "\n")
        self.log.flush()  # a reader may assert on this while we are alive

    def respond(self, request, body=None):
        response = {
            "seq": self.next_seq(),
            "type": "response",
            "request_seq": request.get("seq"),
            "success": True,
            "command": request.get("command"),
        }
        if body is not None:
            response["body"] = body
        write_message(self.stdout, response)

    def event(self, name, body=None):
        message = {"seq": self.next_seq(), "type": "event", "event": name}
        if body is not None:
            message["body"] = body
        write_message(self.stdout, message)

    def handle(self, request):
        """Answer one request. True to keep going, False to exit."""
        command = request.get("command")

        if command == "initialize":
            self.respond(request, {"supportsConfigurationDoneRequest": True})
        elif command == "launch":
            # Order matters: helix replays its breakpoints as setBreakpoints
            # only once it has seen `initialized`.
            self.respond(request)
            self.event("initialized")
        elif command == "setBreakpoints":
            requested = (request.get("arguments") or {}).get("breakpoints") or []
            self.respond(
                request,
                {
                    "breakpoints": [
                        {"verified": True, "line": breakpoint.get("line")}
                        for breakpoint in requested
                    ]
                },
            )
        elif command == "threads":
            self.respond(request, {"threads": THREADS})
        elif command == "configurationDone":
            # A real adapter halts the target here, so this is where a stop
            # belongs. Without it nothing downstream of the editor -- the
            # variables proxy included -- has anything to react to.
            self.respond(request)
            self.event(
                "stopped",
                {"reason": "breakpoint", "threadId": 1, "allThreadsStopped": True},
            )
        elif command == "stackTrace":
            levels = (request.get("arguments") or {}).get("levels") or len(FRAMES)
            self.respond(
                request,
                {"stackFrames": FRAMES[:levels], "totalFrames": len(FRAMES)},
            )
        elif command == "scopes":
            self.respond(request, {"scopes": SCOPES})
        elif command == "variables":
            reference = (request.get("arguments") or {}).get("variablesReference")
            self.respond(request, {"variables": VARIABLES.get(reference, [])})
        elif command == "terminate":
            self.respond(request)
            self.event("terminated")
        elif command == "disconnect":
            self.respond(request)
            return False
        else:
            self.respond(request)
        return True

    def run(self):
        while True:
            message = read_message(self.stdin)
            if message is None:
                return  # EOF or an unreadable frame: never block forever
            self.record(message)
            if message.get("type") != "request":
                continue
            if not self.handle(message):
                return


def main():
    log_path = os.environ.get("DAP_STUB_LOG")
    log = open(log_path, "a", encoding="utf-8") if log_path else None
    try:
        Stub(sys.stdin.buffer, sys.stdout.buffer, log).run()
    finally:
        if log is not None:
            log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
