# helix-test-debug

Debug or run the Rust test under the cursor, in one keystroke.

Put the cursor anywhere inside a `#[test]` function and run `:test-debug`. The
cog works out which cargo test target holds the file, builds it without running
it, finds the binary cargo produced, and starts a Helix debug session stopped
on the test's first line. Nothing is typed: no binary path, no hashed filename,
no test filter.

| command | what it does |
| --- | --- |
| `:test-debug` | build and debug the test under the cursor |
| `:test-run` | run it without a debugger and report the result |
| `:test-debug-failure` | run it, and if it fails debug it stopped where it panicked |
| `:test-again` | repeat the last one from any buffer |
| `:test-cancel` | stop waiting on a build in flight |
| `:test-doctor` | check everything it needs is in place, and say what to fix |
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

Requires [Helix with the Steel plugin
system](https://github.com/mattwparas/helix/tree/steel-event-system), `cargo`,
and a DAP adapter for Rust (`lldb-dap`).

## Install

Copy the cog into your Helix configuration directory:

```
cp test-debug.scm test-debug-rust.scm ~/.config/helix/cogs/
cp -r test-debug ~/.config/helix/cogs/
```

`test-debug.scm` is the editor half, `test-debug-rust.scm` gathers the rust
half, and `test-debug/` holds one module per concern. The requires between
them are relative, so the three have to land together.

Then pull the commands into global scope from `~/.config/helix/helix.scm`,
which is what makes them dispatchable:

```scheme
(require "cogs/test-debug.scm")
(provide test-debug test-run test-again)
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
 (hash "normal" (hash "space" (hash "G" (hash "d" ":test-debug")))))
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
```

Dependencies run one way: `text` and `paths` depend on nothing, `cursor` on
`text`, `names` on `cursor`, `cargo` on `names`. Only the three modules under
`rust/` know anything about Rust, so a second language adds a sibling
directory and one dispatch, rather than an archaeology pass over a flat
file.

`test-debug.scm` is the editor half: it reads the cursor, runs cargo on a
spawned thread so the build does not freeze the editor, and polls from the
editor thread to start the session. The polling is not just progress
reporting: a callback queued from a worker thread is drained only when
Helix's event loop wakes, so without a timer the session would not start
until the next keypress.

A second language would add its own pure half and one dispatch on file type.

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

One gap remains. Steel compiles a function body lazily, so an error of that
kind surfaces only when the path executes, which no load-time check reaches.
Closing it needs a fixture crate and a debugger, driven through a real
editor.

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
