# helix-test-debug

Debug or run the Rust test under the cursor, in one keystroke.

Put the cursor anywhere inside a `#[test]` function and run `:debug-here`. The
cog works out which cargo test target holds the file, builds it without running
it, finds the binary cargo produced, and starts a Helix debug session stopped
on the test's first line. Nothing is typed: no binary path, no hashed filename,
no test filter.

| command | what it does |
| --- | --- |
| `:debug-here`, `:dbgh` | debug the line under the cursor: its test, or the crate's binary when the line is not in a test |
| `:run-here` | run it without a debugger and report the result |
| `:debug-failure` | run it, and if it fails debug it stopped where it panicked |
| `:test-pick` | pick a test from anywhere in the project and debug it |
| `:debug-again` | repeat the last one from any buffer |
| `:debug-cancel` | stop waiting on a build in flight |
| `:debug-breakpoint` | toggle a breakpoint and remember it for this workspace |
| `:debug-breakpoints` | place this workspace's remembered breakpoints |
| `:debug-breakpoints-clear` | forget them |
| `:debug-doctor` | check everything it needs is in place, and say what to fix |
| `:debug-variables` | show the variables popup and keep it fresh |
| `:debug-step-over` `:debug-step-in` `:debug-step-out` `:debug-continue` | step, then refresh that popup |

Commands acting on the test under the cursor are prefixed `test-`, and those
acting on a running session `debug-`, so typing either prefix in the command
palette reveals that whole half of the feature.

The test is selected by its full path with `--exact`, so a name that is a
prefix of another does not drag it along, and the build runs off the editor
thread with the elapsed time on the statusline. A buffer with unsaved
changes is written first, because cargo would otherwise compile code that
does not match the lines the breakpoint was computed from.

Helix's own variables popup is built from a snapshot taken when you open it
and never updates, so it goes stale the moment you step. It is installed
under a fixed layer id, which means re-running it replaces that popup in
place, so the stepping commands here rebuild it after the adapter reports
the new stop location. Bind them over `<space>G n i o c` to get a variables
view that follows the program.

Rust is complete. C and C++ debug the test under the cursor through CMake and
ctest: see [C and C++](#c-and-c) below for what works and what does not yet.

Requires [Helix with the Steel plugin
system](https://github.com/mattwparas/helix/tree/steel-event-system), a DAP
adapter (`lldb-dap`), and `cargo` or `cmake` and `ctest`.

## Install

Copy the cog into your Helix configuration directory:

```
cp test-debug.scm test-debug-rust.scm test-debug-cpp.scm ~/.config/helix/cogs/
cp -r test-debug ~/.config/helix/cogs/
```

`test-debug.scm` is the editor half, `test-debug-rust.scm` gathers the rust
half, and `test-debug/` holds one module per concern. The requires between
them are relative, so the three have to land together.

Then pull the commands into global scope from `~/.config/helix/helix.scm`,
which is what makes them dispatchable:

```scheme
(require "cogs/test-debug.scm")
(provide debug-here dbgh run-here test-pick debug-again debug-breakpoint)
```

### With nix

The flake ships a home-manager module that installs both halves, and the
debugger template as a value you splice into your own rust language entry:

```nix
imports = [ inputs.helix-test-debug.homeManagerModules.default ];
programs.helix.testDebug.enable = true;
programs.helix.languages.language = [
  {
    name = "rust";
    debugger.templates = [ inputs.helix-test-debug.lib.rustDebuggerTemplate ];
  }
];
```

The `require` line stays yours either way: `helix.scm` is where your own
commands live, and a module cannot own that file without clobbering them.

A keybinding is optional. Helix's debug commands live under `<space>G`, and `d`
is free there. `add-global-keybinding` merges through Helix's own keymap merge,
so the rest of the submenu survives. In `init.scm`:

```scheme
(require "helix/keymaps.scm")

(add-global-keybinding
 (hash "normal" (hash "space" (hash "G" (hash "d" ":debug-here")))))
```

## The debugger template

The cog starts a session through Helix's own debugger configuration rather than
talking to the adapter itself, so `languages.toml` needs a template it can
drive. It passes four parameters in this order: the test binary, the test
filter, the source file, and the line to stop on.

```toml
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

[[language.debugger.templates]]
name = "program at line"
request = "launch"
completion = [
  { name = "binary", completion = "filename" },
  { name = "source file" },
  { name = "line" },
]
args = { program = "{0}", preRunCommands = [ "breakpoint set --file {1} --line {2}" ] }
```

Four parts of that are load-bearing.

`--exact` makes the filter a whole-path match, so the cog has to pass the test's
full path (`analysis::signal::tests::settles_when_tail_in_band`) and exactly one
test runs. `--include-ignored` costs nothing for an ordinary test while making
an `#[ignore]`d one debuggable, so neither flag needs to be conditional, which
a static template could not express anyway.

`--test-threads=1` keeps stepping sequential, so a breakpoint hit is the only
thread that moves. `--nocapture` stops the harness swallowing the test's own
output, which then appears in Helix's debug console alongside the adapter's
own chatter, prefixed `(stdout):`. Without it a `println!` in the test you
are debugging goes nowhere you can see.

The breakpoint arrives as an adapter command in `preRunCommands`, which lldb
runs after the target exists and before the process launches. Helix's Steel API
can toggle a breakpoint only at the cursor in the current buffer, so there is no
way to set one at a computed line from a cog; going through the adapter is what
makes the stop location a parameter.

The breakpoint lands on the first line of the body, not the `fn` line. A
breakpoint on the declaration resolves to two locations and stops in the closure
the test harness wraps around the test, which is confusing and several frames
away from the code you meant to look at.

### Rust values in the debugger

Without help, `lldb` renders Rust values as their raw layout: an enum shows up
as `$variants$` and `$discr$` fields. Load rustc's own formatters by wrapping
the adapter:

```sh
#!/bin/sh
etc="$(rustc --print sysroot)/lib/rustlib/etc"
exec lldb-dap \
  --pre-init-command "command script import $etc/lldb_lookup.py" \
  --pre-init-command "command source -s true $etc/lldb_commands" \
  "$@"
```

Point `command` at that wrapper. The sysroot is resolved when the debugger
starts because it has to match the toolchain that built the binary, which is not
necessarily the `rustc` first on your `PATH`.

## C and C++

`:debug-here` works in a `.c`, `.cc`, `.cpp`, `.cxx` or header buffer whose
project is CMake based, with a configured build directory (`build`,
`cmake-build-debug` or `cmake-build-release`).

C and C++ have no universal test attribute, so detection is table driven:
`TEST`, `TEST_F`, `TEST_P`, `TYPED_TEST`, `TYPED_TEST_P`,
`BOOST_AUTO_TEST_CASE`, `BOOST_FIXTURE_TEST_CASE`, `TEST_CASE` and `SCENARIO`.
A codebase wrapping one of those in its own macro adds a pair to
`test-macros` in `test-debug/cpp/cursor.scm`.

The cursor only has to produce a **candidate**. The authority on what tests
exist is `ctest --show-only=json-v1`, which once the target is built reports
each test's name, executable and exact arguments:

```json
{ "name": "MathTest.Doubles",
  "command": ["/w/build/suite", "--gtest_filter=MathTest.Doubles"] }
```

Two consequences. The cog never needs to know GoogleTest's filter flag
versus Catch2's or doctest's, because ctest already encodes it. And a
candidate is *matched* rather than compared, so a parameterized test
registered as `Suite.Name/0` still resolves.

That needs the second template from `languages.toml`, `binary at line`; the
flake exposes it as `lib.binaryDebuggerTemplate`.

Not yet: `:run-here` and `:debug-failure` are Rust only, since they read
libtest's summary and panic line. Both say so rather than misreporting. A
ctest command with more than one argument is refused, because a static
template cannot take a variable argument list.

## Lines that are not tests

A breakpoint does not care whether the line is in a test, so when the cursor
is not in one `:debug-here` builds the crate's binary and stops at the
cursor itself rather than at the first line of a body. Nothing has to be
marked; every line of a crate with a binary is debuggable.

`:run-here` runs that binary and reports the last line it printed, and
`:debug-failure` runs it and, if it panics, stops where it panicked.
The launch needs the `program at line` template, which takes no filter.

`src/bin/tool.rs` resolves to `--bin tool`; a cursor in library code or in
`src/main.rs` leaves the target to cargo, so a package with several binaries
resolves to whichever cargo reports first. C and C++ have no fallback: ctest
knows tests, not programs, and the command says so rather than guessing.

## PlatformIO and Unity

`:debug-here` works in a PlatformIO project's `test/<folder>/` tree. Unity
has no test attribute, so the cursor only names a candidate: a
`RUN_TEST(name)` call anywhere in the same folder is what makes it a test,
and the message says so when nothing does.

`:test-pick` lists the whole project's Unity tests, gathering each folder's
registrations first, since the runner that names a test is conventionally a
different file from the one defining it.

PlatformIO's unit of execution is the folder, not the function, so there is
no filter to pass. The folder's program is built, the breakpoint on the
test's first line is what isolates it, and `:run-here` runs the whole folder
and reports PlatformIO's summary.

The environment comes from `platformio.ini`: one named `native` when there
is one, since that is the build a local debugger can attach to, otherwise
the first declared. The build is forced to carry debug info, because a
`native` build has no `-g` and a breakpoint on it resolves to nothing while
the program runs to completion. PlatformIO takes those flags only from the
environment, so the build runs under `sh`, with values reaching it through
`"$@"` rather than the script text.

## Remembered breakpoints

`:debug-breakpoint` toggles a breakpoint the way Helix's own
`dap_toggle_breakpoint` does, and additionally writes it to
`.helix/test-debug-breakpoints` under the workspace root, one `file:line`
per line with the path relative to the root. Helix keeps breakpoints for the
session only; this survives a restart, and being relative it survives the
checkout moving.

They are placed again on the first launch in a workspace, before the adapter
is asked to launch, because Helix hands over the breakpoints it holds at
session start. `:debug-breakpoints` does it on demand. Placing them means
visiting each file, since Helix can only toggle at the cursor, so the
command opens those buffers and then returns to where you were.

A workspace can cap how many are placed, which matters against hardware: an
RP2040 has four breakpoint comparators per core and probe-rs programs them
directly, so the fifth breakpoint fails the session rather than degrading.
The cap belongs to the target rather than to the cog, so the store declares
it as an optional line, and no line means no cap.

```
budget: 4
src/main.rs:41
```

When the budget drops breakpoints the status line names the file that set
the limit, because nothing else would tell you.

Toggling is done once per workspace per session. A second pass would toggle
the same lines back off, and there is no way to ask Helix what breakpoints
it already holds.

## Structure

Every decision lives in `test-debug/`, one module per spec in `docs/specs/`,
all of it pure: filesystem access arrives as an injected predicate, so the
whole half runs under a bare `steel` interpreter, which is where its tests
run. `test-debug-rust.scm` gathers those modules for the editor half and the
tests.

```
test-debug/text.scm          strings and lines
test-debug/paths.scm         path arithmetic, the crate root
test-debug/breakpoints.scm   the breakpoint text format
test-debug/diagnosis.scm     the setup check
test-debug/messages.scm      what the editor reports
test-debug/rust/cursor.scm   finding the test under the cursor
test-debug/rust/names.scm    the path libtest matches
test-debug/rust/cargo.scm    invoking cargo, reading its output
test-debug/rust/discover.scm every test in the crate
test-debug/rust/binary.scm   building and running the crate's binary
test-debug/cpp/cursor.scm    finding the C or C++ test under the cursor
test-debug/cpp/ctest.scm     what ctest says a test is
test-debug/cpp/unity.scm     finding the Unity test under the cursor
test-debug/cpp/pio.scm       driving a PlatformIO project
```

Dependencies run one way: `text` and `paths` depend on nothing, `cursor` on
`text`, `names` on `cursor`, `cargo` and `discover` on `names`. Only the
modules under `rust/` and `cpp/` know anything about a language, so a third
one adds a sibling directory and one dispatch, rather than an archaeology
pass over a flat file.

`test-debug.scm` is the editor half: it reads the cursor, runs cargo on a
spawned thread so the build does not freeze the editor, and polls from the
editor thread to start the session. The polling is not just progress
reporting: a callback queued from a worker thread is drained only when
Helix's event loop wakes, so without a timer the session would not start
until the next keypress.

`test-debug-picker.scm` is the other editor-side file: the overlay
`:test-pick` shows. It draws a list, reads keys, and hands the chosen test
to a callback, so it knows nothing about building or launching.

Picking reads the crate's sources rather than asking cargo what tests exist.
A libtest binary can list its own tests, but only once it is built, and a
picker that waits for a build is not a picker; the source also carries the
line to stop on, which `--list` does not report.

## Tests

```sh
make check
```

`make test` runs the unit suite over the pure half: the cursor-to-test
mapping, declaration parsing, module paths, target selection, the breakpoint
line, and cargo's JSON output.

`make compile-check` loads the editor half against the stub modules in
`tests/stubs/`, forcing every identifier it uses to resolve. Helix registers
`helix/commands.scm` and friends inside its own engine, so without the stubs
a name taken from a module the cog forgot to require cannot fail until Helix
loads it and reports `FreeIdentifier`.

`make helix-check` loads the cog in a real Steel-enabled Helix, and skips
itself when one is not on `PATH`. It exists because the standalone
interpreter is not a faithful stand-in: `(void)` in tail position compiles
under steel 0.8.2 *and* under the exact revision Helix pins, yet Helix's own
engine rejects it. Building a matching interpreter does not close that gap.

`make integration-check` closes that gap: Steel compiles a function body
lazily, so an error inside a command surfaces only when it runs. It drives
`:run-here`, `:debug-here` and `:test-pick` in a real Helix against
`tests/fixture`, and asserts what actually happened rather than what the
screen said — the test the fixture recorded to a log, and a test binary
stopped by a debugger in `/proc`. The picked test is deliberately not the
one under the cursor, so the pick cannot be satisfied by the cursor path.

## Tooling

`nix develop` provides `steel`, which carries `steel-language-server`, and
`nixfmt`. Point Helix's `scheme` language at `steel-language-server` and set
`STEEL_LSP_HOME` somewhere writable: its default is `$STEEL_HOME/lsp`, which
on Nix is a read-only store path, and the server panics creating it.

There is deliberately no Scheme formatter. `schemat`, the only one packaged,
reindents continuation arguments to a fixed two spaces, while this code
aligns them under the first argument as Scheme and Racket conventionally do.
Adopting it would reformat every file for no correctness gain, so `make fmt`
covers `flake.nix` only and the Scheme is formatted by hand.

## Limitations

Test discovery reads the buffer as text rather than querying the syntax tree.
It finds the nearest function declaration at or above the cursor, then looks
upward past attributes and comments for an attribute containing `test`, which
covers `#[test]` and the async variants such as `#[tokio::test]`. A cursor
inside a nested function reports the nested one.

Module paths are read from indentation, so a `mod` block whose brace sits on
its own line, or source formatted with tabs, can produce a path `--exact`
then fails to match.

A file outside `src/`, `tests/` and `benches/` selects no cargo target, so every
test target gets built and the last test binary cargo reports is the one used.

## License

LGPL-3.0-or-later. See `COPYING.LESSER`.
