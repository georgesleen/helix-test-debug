# Changelog

Versions stay below 1.0.0 while the command surface and the Steel API it
depends on are still moving. Breaking changes may land in any 0.y bump.

## Unreleased

- Commands renamed for discoverability: `test-debug`, `test-run`,
  `test-again`, `test-doctor` act on the test under the cursor; `debug-*`
  act on a running session.
- `:test-debug-failure` runs the test and, when it fails, starts a session
  stopped at the line that panicked.
- `:test-cancel` abandons the wait on a build in flight.
- A dirty buffer is written before building.
- `docs/specs/` holds one behavioural spec per concern. The tests for this
  round were written from those specs by an author who could not see the
  implementation.

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
