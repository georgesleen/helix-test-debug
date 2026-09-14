# The path libtest matches

## `(module-prefix relative-path)`

The module path a source file contributes, as a list of names, given its
path relative to the crate root.

- A file under `src/` contributes its directory path plus its own stem.
- `lib.rs`, `main.rs` and `mod.rs` contribute their directory path only.
- A file under `tests/` or `benches/` is its own crate root and contributes
  nothing.

## `(enclosing-modules lines declaration-line-index)`

The modules enclosing a declaration, outermost first.

- A module encloses the declaration when it is declared above it and
  indented less. Indentation counts spaces and tabs alike, since only the
  ordering of depths matters.
- A sibling module, indented the same or more, encloses nothing.
- `mod foo;` has no body and encloses nothing.

## `(qualified-test-name relative-path lines test)`

The file's module path, then the enclosing modules, then the test name,
joined with `::`. This is exactly what the test binary prints for `--list`,
so `--exact` selects one test.
