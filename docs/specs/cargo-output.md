# Reading cargo's output

## `(executable-from-cargo-output text)`

The path of the test binary cargo built, or `#f` when it reported none.

Cargo emits one JSON message per line. The wanted message has
`reason` `compiler-artifact`, a string `executable`, and `profile.test`
true. A crate with a bin target also yields a non-test executable, so the
profile decides, not the position in the stream.

A line that is not JSON is skipped rather than failing the parse.

## `(test-outcome output)`

`output` is everything cargo printed. Returns the trimmed text of the
**last** line whose trimmed form starts with `test result:`, or `#f` when no
such line exists.

- Several summaries appear when several test targets ran; the last wins.
- `test result:` must begin the trimmed line. A mention of it mid-line is
  prose, not a summary.
- `#f` for empty input and for output containing no summary.
- The whole summary is kept, counts included, with interior spacing
  untouched. Only leading and trailing whitespace is removed.

## `(outcome-failed? outcome)`

`outcome` is a string from `test-outcome`, or `#f`.

- `#f` when `outcome` is `#f`. An absent summary is not a failure here; the
  caller decides what to do about it.
- `#t` when the summary contains `FAILED`.
- `#f` when the summary contains `ok`.
- The wording decides, not the counts: a summary saying `ok` with `0 passed`
  is not a failure.
- A summary containing neither word yields `#f`, on the same principle that
  only an explicit failure counts as one.
- A summary carrying both words is a failure: `FAILED` outranks `ok`, since
  cargo prints `ok` per test and its verdict last.
