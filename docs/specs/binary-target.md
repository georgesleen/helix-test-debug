# Debugging a line that is not in a test

A breakpoint does not care whether the line is in a test. When the cursor is
not in one, the thing to build is the crate's binary, and the thing to stop
at is the cursor itself rather than the first line of a body.

This is the fallback, so it never reports "no test here": every line of a
crate with a binary is debuggable.

## `(binary-target-arguments relative-path)`

Cargo arguments selecting the binary target a source file belongs to.

- `src/bin/tool.rs` selects `("--bin" "tool")`.
- `src/bin/tool/main.rs` selects `("--bin" "tool")`, the directory form of
  the same target.
- `src/bin/tool/helper.rs` also selects `("--bin" "tool")`: every file in a
  binary's directory is compiled into that binary, so the directory name is
  what decides, not the file name.
- `src/main.rs` selects nothing, because the package's own binary is named
  in `Cargo.toml` rather than by its path.
- Any other file under `src/` selects nothing: library code is compiled
  into whichever binary uses it, and cargo picks.
- `tests/` and `benches/` select nothing. A file there has no binary, and
  the caller is expected to have found a test first.
- The empty list for a path with no directory segment.

Selecting nothing means cargo builds every binary in the package, which is
the behaviour a single-binary crate wants. A package with several binaries
and a cursor in shared library code is therefore ambiguous; see
`bin-executable-from-cargo-output`.

## `(binary-build-arguments relative-path)`

The full invocation that builds, but does not run, that binary:
`("build" "--message-format=json")` followed by the target arguments.

- JSON is what names the built executable, exactly as for a test target.
- `--no-run` has no meaning for `cargo build` and is absent.

## `(binary-run-arguments relative-path)`

The full invocation that builds and runs it: `("run")` followed by the
target arguments.

- No `--` and no trailing arguments: there is no filter to pass.
- The message format is absent, because the point is to see the program's
  own output.

## `(bin-executable-from-cargo-output text)`

The executable of a binary artifact in cargo's JSON stream, or `#f`.

- An artifact qualifies when it has an `executable`, its `target.kind`
  contains `"bin"`, and its `profile.test` is not `#t`.
- A build script artifact is excluded: its kind is `custom-build`, even
  though it does have an executable.
- A test artifact is excluded, so this and
  `executable-from-cargo-output` cannot be confused for each other.
- The **first** qualifying artifact wins, so a package with several
  binaries resolves to whichever cargo reported first. That is the
  documented cost of a cursor in shared library code; naming the file under
  `src/bin/` removes the ambiguity.
- `#f` when no message qualifies, which is what a build failure looks like.
- A line that is not JSON, and a JSON line that is not an object, are
  skipped rather than failing the parse.

## `(binary-label relative-path)`

What the editor calls the thing it is about to run, for the status line.

- `"bin tool"` for `src/bin/tool.rs` and `src/bin/tool/main.rs`.
- `"the binary"` when the path selects no particular target, which covers
  `src/main.rs` and library code.
- The label is for reading, not parsing; nothing depends on its spelling.
