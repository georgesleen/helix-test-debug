# Specs

One file per behaviour. Each is the contract for a group of functions in the
rust half: the tests are written from it, and the implementation is written
against it.

Every function specified here is pure. No filesystem, no process, no editor
state; filesystem access arrives as an injected predicate.

## Terminology

A **line index** is zero-based, matching the editor's cursor. A **line
number** is one-based, matching what a debugger and a panic message use.
Confusing the two is the likeliest bug in this code, so every signature says
which it takes and which it returns.

## Contents

| spec | covers |
| --- | --- |
| [cursor-to-test.md](cursor-to-test.md) | finding the test the cursor is in |
| [qualified-names.md](qualified-names.md) | the path libtest matches with `--exact` |
| [cargo-invocation.md](cargo-invocation.md) | which target to build, and how |
| [cargo-output.md](cargo-output.md) | reading cargo's JSON and its summaries |
| [panic-location.md](panic-location.md) | where a failing test panicked |
| [test-listing.md](test-listing.md) | enumerating a binary's tests |
| [breakpoints.md](breakpoints.md) | persisting breakpoints as text |
| [paths.md](paths.md) | path arithmetic and the crate root |
| [diagnosis.md](diagnosis.md) | the setup check and its report |
