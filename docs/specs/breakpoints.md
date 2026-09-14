# Persisting breakpoints as text

A breakpoint is a `(file line-number)` pair, the same shape
`panic-location` returns.

## `(breakpoints->text breakpoints)`

One `file:line` per line, each terminated by a newline, in the order given.

- The empty list yields the empty string.
- No sorting, no deduplication, no header.
- A line number that is not an integer is rendered as written, so `12.5`
  yields `src/lib.rs:12.5`. Validation belongs to whoever built the pair,
  and `text->breakpoints` skips it on the way back in.

## `(text->breakpoints text)`

The inverse: `file:line` per line parsed into `(file line-number)` pairs
with an integer line number.

- Blank lines are skipped.
- A line whose last colon-separated field is not an integer is skipped
  rather than failing the whole parse. A corrupt file must not stop the
  editor from starting.
- Splitting happens at the **last** colon, so a path may contain colons even
  though `panic-location` will not produce one.
- `(text->breakpoints (breakpoints->text bs))` returns `bs` for any list of
  pairs whose files contain no newline.
