# Embedded targets: what transfers, what does not

Implementation rationale for embedded debugging: what carries over from the
host path, what must change for a remote adapter, and which apparent
generalisations fail against real hardware.

The source research was done on 2026-09-15. The resulting path was exercised
end to end on 2026-09-16 with probe-rs 0.32.0, a Raspberry Pi Debug Probe and
a Pico 2: CMake selected the firmware target, Helix sent a verified source
breakpoint, probe-rs flashed the ELF, and continuing from reset stopped on
that breakpoint with target variables readable.

## The hardware this was checked against

A Raspberry Pi Debug Probe and a Pico 2. Two corrections to the research
above, both found by plugging them in:

- A Pico 2 is **RP2350**, not RP2040, and probe-rs 0.32.0 calls it
  `RP235x`, with `RP235x_riscv` for its Hazard3 cores. `RP2350` is not a
  name in the registry. Its cores are Cortex-M33 rather than M0+, so the
  four-breakpoint figure below is an RP2040 fact and does not carry over;
  probe-rs reads the count from `BP_CTRL.NUM_CODE` on the target rather
  than assuming, which is the answer that stays true either way.
- The retail Debug Probe shipped firmware older than probe-rs accepts:
  `probe-rs info` found the probe (`2e8a:000c-0:<serial>`) and then refused
  with *"The firmware on the probe is outdated, and not supported by
  probe-rs. The minimum supported firmware version is 2.2.0."* Updating it
  to Debug Probe 2.3.1 removed that failure. `probe-rs list` then identified
  it as CMSIS-DAP, and `probe-rs info --verbose --protocol swd` enumerated
  both Cortex-M33 cores and the RP235x CoreSight ROM.
- Plain `probe-rs info` still cannot autodetect RP235x, and its `--chip`
  option is explicitly ignored for that subcommand. This is not a connection
  failure: verbose discovery works, while operational commands such as
  `download` and the DAP launch take `--chip RP235x` successfully.
- A real DAP trace confirmed the ordering this cog depends on. The adapter
  verified `main.c:11`, flashed the image, stopped at reset because the
  template requested `haltAfterReset`, accepted `continue`, then reported
  a breakpoint stop at the exact verified address. Helix read `ticks = 0`
  from target RAM.

## The shape of the problem

The cog does four things. Only one of them breaks.

| | on the host | on an RP2040 |
| --- | --- | --- |
| cursor to test name | reads `#[test]` as text | **unchanged**, see below |
| build, find the executable | `cargo test --no-run --message-format=json` | **unchanged**, only the path gains a triple segment |
| deliver the breakpoint | lldb `preRunCommands` in the template | **broken**, no equivalent exists |
| select the test | `--exact` in the template's `args` | **broken** for debugging, fine for running |

### Detection transfers for free

`embedded-test` declares tests with a bare `#[test]` inside a module marked
`#[embedded_test::tests]`, and its macro matches on the bare ident, so
`#[embedded_test::test]` is *not* a test. The attribute this cog already
looks for is exactly the one that counts, and the names probe-rs reports
(`tests::it_works`) follow libtest's convention, which
`qualified-test-name` already produces.

`defmt-test` is a different story and not worth supporting: it has no
filtering and no listing, its entrypoint runs every test unconditionally,
and it prints defmt frames rather than a libtest summary. Per-test
debugging is impossible there by construction.

### The build half transfers, with one path caveat

`cargo test --no-run --message-format=json` does not invoke the runner, so
no probe and no board are needed to build a test ELF and learn its path;
`harness = false` still produces a `deps/<name>-<hash>` executable. The one
change is that with `[build] target = "thumbv6m-none-eabi"` the artifact is
under `target/thumbv6m-none-eabi/debug/deps/`, so anything assuming the host
layout needs the triple segment.

Unverified: the exact `profile.test` and `target.kind` values cargo emits
for a `harness = false` `[[test]]` target. `bin-executable-from-cargo-output`
and `executable-from-cargo-output` both key on those, so this needs one
empirical check before either is trusted on an embedded project.

## What breaks: the breakpoint

probe-rs's DAP server deserializes launch arguments into a fixed
`SessionConfig` struct. There is no `preRunCommands`, no `initCommands`, no
`stopOnEntry`, and no breakpoint field. Worse, none of those structs use
`deny_unknown_fields`, so a `preRunCommands` key copied across from the lldb
template is **silently dropped**: it will look like it worked.

The breakpoint has to arrive as a DAP `setBreakpoints` request, which means
it has to be a real Helix breakpoint in `editor.breakpoints` before the
session starts. Helix replays those when the adapter sends `initialized`,
and probe-rs sends `initialized` after it has flashed *and halted* the core,
so the ordering is right: the core is halted and the breakpoint unit is
programmable exactly when Helix delivers them.

That mechanism already exists here, built for remembered breakpoints:
`replay-breakpoint!` places a breakpoint in Helix by visiting the line and
toggling. The embedded path would place one breakpoint the same way instead
of writing a `preRunCommands` string.

Budget: RP2040 has **4 hardware breakpoints per core** and probe-rs does not
fall back to software `BKPT` patching, so an unbounded remembered set is a
hazard there in a way it is not on the host.

## What is blocked: debugging one embedded test

Selecting a test is not a launch argument. The target reads the test to run
over semihosting at startup, and under a DAP session probe-rs answers that
with the *address* of the test entrypoint. The mechanism is a Debug Console
REPL command, `test run <name>`, which is a DAP `evaluate` request with
`context: "repl"` issued after the session is up.

Helix has no command that issues an `evaluate` request, and the Steel API
exposes none either: the `dap_*` statics are launch, restart, toggle
breakpoint, continue, pause, step in/out/over, variables and terminate.

So this is blocked, and it fails badly rather than harmlessly: launching an
embedded-test ELF without the REPL command leaves the core halted forever on
the unanswered `GetCommandLine`, which reads as a hang.

Two ways out, both real work outside this repo:

1. Add an `evaluate` command to the Steel API in the fork already being run,
   then `:debug-here` on embedded is a launch followed by one `evaluate`.
   This is the honest fix and is upstreamable.
2. Have the cog own the semihosting handshake, which means not using
   probe-rs's DAP server. Much larger, and duplicates probe-rs.

## What is not blocked, and is worth doing first

**Debug embedded firmware at the cursor.** No tests involved: build the
binary, flash it, stop at the line under the cursor. This is precisely the
fallback added for host binaries, with two differences — the launch template
carries probe-rs's nested shape, and the breakpoint goes through Helix
rather than the template. Nothing here is blocked.

```toml
[language.debugger]
name = "probe-rs"
transport = "stdio"            # probe-rs >= 0.32.0; stdio implies single session
command = "probe-rs"
args = ["dap-server"]

[[language.debugger.templates]]
name = "firmware"
request = "launch"
completion = [ { name = "elf", completion = "filename" } ]
[language.debugger.templates.args]
chip = "RP2040"
flashingConfig = { flashingEnabled = true, haltAfterReset = true }
coreConfigs = [ { coreIndex = 0, programBinary = "{0}" } ]
```

Helix substitutes `{0}` inside nested arrays and objects, so the shape is
expressible. Two traps: a substituted value that parses as an integer
becomes a JSON number, and a parameter whose completion is `filename` is
canonicalised, so it must exist when `:debug-start` runs.

With `transport = "tcp"` instead, `port-arg = "--port {}"` is required and
so is `--single-session`: Helix does not kill a TCP adapter child, so
without it every launch leaks a `probe-rs` process holding the probe.

`connectUnderReset` must stay false. The retail Debug Probe has no reset
pin; the firmware's reset routine is a no-op.

**Run one embedded test.** `:run-here` needs no debugger and no new
mechanism: `probe-rs run --chip RP2040 <elf> --exact tests::name` flashes,
runs exactly that test, and prints a genuine libtest summary, because
probe-rs feeds `libtest_mimic::run`. `test-outcome` parses that output
already, unchanged.

One hard incompatibility: **probe-rs rejects `--test-threads`**. It is not
in probe-rs's clap struct, which is not libtest-mimic's, and the flag is a
hard error rather than an ignored one. This cog passes `--test-threads=1`
in `*filter-flags*` on every run, so the embedded run path must drop it.
probe-rs hard-codes single-threaded anyway. `--nocapture` is accepted and
ignored, `--exact` and `--include-ignored` work, `--skip` is `--skip-test`.

Also: `probe-rs run --list` attaches and flashes the board before listing,
so it is useless for a picker. Discovery would have to read the ELF's
`.embedded_test` section, where each symbol *name* is the test's JSON
metadata. Or keep reading the source, which is what `discover.scm` does and
needs no hardware at all.

## PlatformIO and Unity

A separate problem that shares only the launch conclusion.

Unity has no test attribute. A test is a plain `void test_name(void)`, and
what makes it a test is a `RUN_TEST(test_name);` call in the runner's
`main`. So detection cannot be another row in the `test-macros` table the
GoogleTest path uses: it needs a second rule, find the enclosing function
then confirm a `RUN_TEST` names it somewhere in the test directory.

Discovery has no ctest equivalent either. `pio test --list-tests` enumerates
test environments and directories, because PlatformIO's unit of execution is
a test folder rather than one function. The authority has to be the source,
as it is for Rust.

And `pio debug` drives GDB against a debug server rather than launching a
local executable, so the `program` plus `preRunCommands` template does not
transfer — the same wall as probe-rs, for the same reason.

## Order of work

1. Firmware at the cursor, through probe-rs, breakpoint via Helix. Needs no
   upstream change. Needs hardware to verify.
2. `:run-here` for embedded tests, dropping `--test-threads`.
3. An `evaluate` command in the Steel API, then single-test debugging.
4. PlatformIO, which needs its own detection rule before any of its launch
   story matters.

## Sources

- probe-rs DAP argument schema:
  `probe-rs-tools/src/bin/probe-rs/cmd/dap_server/server/configuration.rs`
  and <https://probe.rs/docs/tools/debugger/>
- No `preRunCommands`, and unknown keys dropped: `get_arguments` in
  `debug_adapter/dap/adapter.rs`
- `setBreakpoints` implementation: `set_breakpoints` in the same file
- Helix replays breakpoints on `initialized`:
  `helix-view/src/handlers/dap.rs`
- Helix transports and `{}` port substitution: `helix-dap/src/client.rs`
- RP2040 4 breakpoints: RP2040 datasheet section 2.4.2.4
- Debug Probe is `2e8a:000c` with no reset pin: `raspberrypi/debugprobe`,
  `src/usb_descriptors.c` and `include/board_debug_probe_config.h`
- probe-rs test flags: `TestOptions` in
  `probe-rs-tools/src/bin/probe-rs/cmd/run.rs`
- embedded-test attributes:
  `macros/src/attributes/tests/parse/function_attributes.rs`
- The `test run` REPL command:
  `cmd/dap_server/debug_adapter/dap/repl_commands/embedded_test.rs`
- Semihosting handshake and the `.embedded_test` section:
  `embedded-test/src/export.rs`
