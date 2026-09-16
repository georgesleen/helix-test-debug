# Stub DAP adapter

`../stub-dap-adapter.py` stands in for `probe-rs dap-server` on a machine with
no probe and no board attached.

## What it is for

The embedded path gives the cog two jobs: build the nested probe-rs launch
arguments (`chip`, `coreConfigs[].programBinary`, `flashingConfig`) and get the
breakpoint into `editor.breakpoints` so helix delivers it as a DAP
`setBreakpoints` after the adapter's `initialized` event. Both are observable
from the adapter's side of the pipe, without hardware: put the stub where
probe-rs would be and read back exactly what the editor sent.

## What it does

Speaks `Content-Length`-framed DAP over stdin/stdout, enough for helix to carry
a launch through to `configurationDone`:

- `initialize` — success, body `{"supportsConfigurationDoneRequest": true}`
- `launch` — success response, *then* an `initialized` event. That order is the
  reason the stub exists: helix replays its breakpoints only after
  `initialized`, which is also when probe-rs has flashed and halted the core.
- `setBreakpoints` — success, echoing each requested line back as
  `{"verified": true, "line": <line>}`
- `threads` — one thread, `{"id": 1, "name": "stub"}`
- `configurationDone`, `terminate` (plus a `terminated` event), `disconnect`
- anything else — a bare success, so helix never hangs on a request the stub
  does not model

Exits 0 on `disconnect` or on stdin EOF. It never blocks waiting for more.

## What it does not do

It does not flash, does not reset or halt a core, does not execute or inspect a
program, and reports no stack frames, variables or stop events. Nothing it
answers is derived from a real target — `verified: true` means "recorded", not
"planted". A passing run proves only what the **editor** sent; whether probe-rs
accepts those arguments and whether the breakpoint actually binds on silicon
still has to be checked against hardware.

## The log

With `DAP_STUB_LOG` set, every message *received* is appended to that path, one
JSON object per line, flushed immediately — so a test can assert on the log
while the session is still alive. Unset, the stub logs nothing.

```sh
DAP_STUB_LOG=/tmp/dap.jsonl hx src/main.rs
jq -c 'select(.command == "launch") | .arguments' /tmp/dap.jsonl
jq -c 'select(.command == "setBreakpoints") | .arguments.breakpoints' /tmp/dap.jsonl
```

## Pointing helix at it

In the `languages.toml` of the config dir under test, replace the adapter
command and keep the template the cog builds for probe-rs:

```toml
[[language]]
name = "rust"

[language.debugger]
name = "stub"
transport = "stdio"
command = "/abs/path/to/tests/stub-dap-adapter.py"
args = []

[[language.debugger.templates]]
name = "firmware"
request = "launch"
completion = [ { name = "elf", completion = "filename" } ]
[language.debugger.templates.args]
chip = "RP2040"
flashingConfig = { flashingEnabled = true, haltAfterReset = true }
coreConfigs = [ { coreIndex = 0, programBinary = "{0}" } ]
```

The path must be absolute or on `PATH`, and the file must stay executable. A
`filename` completion is canonicalised by helix, so the ELF has to exist when
`:debug-start` runs even though the stub never opens it.
