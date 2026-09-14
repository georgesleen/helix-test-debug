# Changelog

Versions stay below 1.0.0 while the command surface and the Steel API it
depends on are still moving. Breaking changes may land in any 0.y bump.

## 0.1.0

- `:debug-test` builds the cargo test target holding the cursor and starts a
  debug session stopped on the test's first line.
- `:run-test` runs that test without a debugger and reports its result.
- `:debug-test-again` repeats the last request from any buffer.
- `:debug-variables` shows the variables popup and keeps it fresh, which
  Helix's own snapshot popup does not do.
- `:debug-step-over`, `:debug-step-in`, `:debug-step-out` and
  `:debug-continue` step and then refresh that popup.
- Tests are selected by full module path with `--exact`, so exactly one runs.
- Builds run off the editor thread, with elapsed time on the statusline.
