# Enumerating a binary's tests

## `(test-names-from-list output)`

`output` is what a libtest binary prints for `--list`:

```
analysis::signal::tests::settles_when_tail_in_band: test
analysis::frequency::tests::verify_basic_equality: test
2 tests, 0 benchmarks
```

Returns the qualified test names in the order printed, with the `: test`
suffix removed.

- A `: benchmark` suffix is excluded.
- A line with no recognised suffix is ignored, which covers the trailing
  summary and blank lines.
- The empty list for empty input and for input with no test lines.
- Names are returned verbatim: no sorting, no deduplication.
- Only the suffix decides what is a test line, so a name containing spaces
  is kept rather than rejected.
