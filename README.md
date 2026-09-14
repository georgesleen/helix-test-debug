# helix-test-debug

Debug the Rust test under the cursor in one keystroke.

Put the cursor anywhere inside a `#[test]` function and run `:debug-test`.
The cog works out which cargo test target holds the file, builds it without
running it, finds the test binary cargo produced, and starts a Helix debug
session stopped on the test's first line.

Nothing is typed: no binary path, no hashed filename, no test filter.

Requires [Helix with the Steel plugin
system](https://github.com/mattwparas/helix/tree/steel-event-system), `cargo`,
and a DAP adapter for Rust (`lldb-dap`).

## Install

Copy both files into your Helix configuration directory:

```
cp test-debug.scm test-debug-rust.scm ~/.config/helix/cogs/
```

`test-debug.scm` requires `test-debug-rust.scm` from the same directory, so
they must stay together.

Then pull the command into global scope from `~/.config/helix/helix.scm`, which
is what makes it dispatchable as `:debug-test`:

```scheme
(require "cogs/test-debug.scm")
(provide debug-test)
```

A keybinding is optional. Helix's debug commands live under `<space>G`, and `d`
is free there. `add-global-keybinding` merges through Helix's own keymap merge,
so the rest of the submenu survives. In `init.scm`:

```scheme
(require "helix/keymaps.scm")

(add-global-keybinding
 (hash "normal" (hash "space" (hash "G" (hash "d" ":debug-test")))))
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
args = { program = "{0}", args = [ "{1}", "--test-threads=1", "--nocapture" ], preRunCommands = [ "breakpoint set --file {2} --line {3}" ] }
```

Three parts of that are load-bearing.

`--test-threads=1` keeps stepping sequential, so a breakpoint hit is the only
thread that moves. `--nocapture` lets the test's own output reach the terminal
instead of being swallowed by the harness.

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

`test-debug-rust.scm` holds every decision: which test the cursor is in, which
cargo target to build, where the breakpoint goes, and which artifact in cargo's
JSON output is the test binary. It is pure, filesystem access arrives as an
injected predicate, and it runs under a bare `steel` interpreter, which is where
its tests run.

`test-debug.scm` is the editor half: it reads the cursor, runs cargo on a
spawned thread so the build does not freeze the editor, and returns to the
editor thread to start the session.

A second language would add its own pure half and one dispatch on file type.

## Tests

```sh
make check
```

`make test` runs the unit suite over the pure half: the cursor-to-test mapping,
declaration parsing, target selection, the breakpoint line, and cargo's JSON
output.

`make compile-check` loads the editor half against the stub modules in
`tests/stubs/`, which forces every identifier it uses to resolve. Helix
registers `helix/commands.scm` and friends inside its own engine, so without
the stubs a name taken from a module the cog forgot to require cannot fail
until Helix loads the cog and reports `FreeIdentifier`.

## Limitations

Test discovery reads the buffer as text rather than querying the syntax tree.
It finds the nearest function declaration at or above the cursor, then looks
upward past attributes and comments for an attribute containing `test`, which
covers `#[test]` and the async variants such as `#[tokio::test]`. A cursor
inside a nested function reports the nested one.

The test filter is a substring, not `--exact`, so a test whose name is a prefix
of another runs both. The debugger stops in whichever one hits the breakpoint
first.

A file outside `src/`, `tests/` and `benches/` selects no cargo target, so every
test target gets built and the last test binary cargo reports is the one used.

## License

LGPL-3.0-or-later. See `COPYING.LESSER`.
