# Finding every test in a crate

The cursor path answers "what test am I in". This answers "what tests are
there", so one can be picked without navigating to it first. Both paths end
in the same place: a qualified name for `--exact` and a line to stop on.

Discovery reads the source rather than asking cargo. A libtest binary can
list its tests, but only after it is built, and a picker that waits for a
build is not a picker. The source also carries what `--list` does not: the
file and line the launch template needs.

## `(compiled-source? relative-path)`

Whether a path relative to the crate root is rust cargo compiles.

- `#t` for a `.rs` file whose first segment is `src`, `tests` or `benches`.
- `#f` for any other first segment, which excludes `target/` and the
  generated sources under it.
- `#f` for a path that does not end in `.rs`.
- `#f` for a bare file name with no directory segment, since `Cargo.toml`
  sits beside the crate root and nothing there is compiled as a module.
- Comparison is exact: `Src/lib.rs` is not `src/lib.rs`, matching a
  case-sensitive filesystem.

## `(tests-in-file relative-path lines)`

Every test declared in one file, in the order declared. An entry is
`(name relative-path line)`, read with `discovered-name`,
`discovered-path` and `discovered-line`.

- `name` is the qualified name from `docs/specs/qualified-names.md`, so a
  test inside `mod tests` in `src/analysis/signal.rs` is
  `analysis::signal::tests::settles`.
- `line` is the breakpoint line from `docs/specs/breakpoints.md`: the first
  line of the body, one-based.
- A function with no `#[test]` attribute is not an entry.
- `#[test]` separated from its `fn` by other attributes, comments or blank
  lines still counts, exactly as the cursor path treats it.
- `#[tokio::test]` and other attribute paths ending in `test` count, again
  as the cursor path treats them.
- The empty list for a file with no tests and for no lines at all.
- Two tests of the same name in different modules are distinct entries;
  neither is dropped, because their qualified names differ.

## `(matching-tests-by-name query entries)`

The entries a query selects, in their original order.

- The empty query selects every entry.
- A query matches when its characters appear in the entry's name in order,
  not necessarily adjacent: `anig` matches `analysis::signal::tests::x`.
- Matching ignores case in both directions.
- `::` in a query is matched literally against the name, so a module path
  pasted in still selects its tests.
- A query no name contains selects nothing.
- Order is the order of `entries`; matching never sorts, so the list stays
  in declaration order per file and in the order files were discovered.

## `(discovery-summary query entries total)`

The line shown above the list, naming what is on screen.

- `"no tests found in this crate"` when `total` is zero, whatever the
  query, because there is nothing to filter.
- `"<total> tests"` when the query is empty.
- `"<shown> of <total> tests matching <query>"` when a query is filtering,
  where `shown` is the length of `entries`.
- `"nothing matches <query>"` when a query selects none of a non-empty
  crate.
- Counts are written as numbers; `1 tests` is accepted rather than
  special-cased, so the line never has to be parsed to be read.
