# Choosing and invoking a cargo target

## `(target-arguments relative-path)`

The cargo arguments selecting the target holding a source file.

- `src/...` yields `("--lib")`.
- `tests/foo.rs` and `tests/foo/main.rs` both yield `("--test" "foo")`.
- `benches/foo.rs` yields `("--bench" "foo")`.
- Anywhere else yields the empty list, which leaves cargo to build every
  test target.

## `(build-arguments relative-path)`

`("test" "--no-run" "--message-format=json")` followed by the target
arguments. The JSON is what names the built binary.

## `(run-arguments relative-path filter)`

`("test")`, the target arguments, then `("--" filter)` and the filter flags.

The filter flags are `--exact` and `--include-ignored`. `--exact` makes the
filter a whole-path match; `--include-ignored` costs nothing for an ordinary
test while making an `#[ignore]`d one runnable, so neither flag needs to be
conditional, which a static debugger template could not express anyway.
