# Where a failing test panicked

## `(panic-location output)`

`output` is everything the test binary printed. libtest prints, on failure:

```
thread 'analysis::signal::tests::rejects_ringing_tail' panicked at crates/kitest/src/analysis/signal.rs:74:9:
assertion failed: !s.settles_to(1.0, Tolerance::abs(0.05), 2.0)
```

Returns `(file line-number)`, where `file` is the path exactly as printed
and `line-number` is the one-based line as an integer, or `#f`.

- The column is discarded.
- The path is returned verbatim, neither resolved nor reduced to a base
  name. The caller decides what the debugger needs.
- When several panics appear the **first** wins: it is the one that failed
  the test, later ones are usually the harness unwinding.
- `#f` for empty input, for output with no panic line, and when the text
  after `panicked at` does not match `<path>:<integer>:<integer>`.
- A path containing a colon is out of scope, as are Windows paths.
