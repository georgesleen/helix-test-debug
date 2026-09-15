# A budget for remembered breakpoints

Remembering breakpoints is unbounded, which is fine against lldb on a host
and wrong against hardware. An RP2040 has four breakpoint comparators per
core and probe-rs programs them directly with no software fallback, so the
fifth remembered breakpoint fails the session rather than degrading.

The cog cannot know the budget: it is a property of the target, not of the
workspace. So the workspace states it, in the file that already holds the
breakpoints, as an optional first line.

```
budget: 4
src/main.rs:41
src/driver.rs:88
```

No header means no limit, which is what a host workspace wants and keeps
every existing file valid.

## `(breakpoint-budget text)`

The budget a store declares, or `#f`.

- `#f` when no line declares one, which includes the empty string.
- The number from a `budget: N` line, with any spacing around the colon and
  around `N`, and with leading whitespace on the line allowed.
- `#f` for a non-integer, a negative number, or a missing value: a typo
  must not silently become a limit of zero.
- `0` is a valid budget, meaning place nothing. It is distinguishable from
  `#f` by type, so a caller must test for `#f` rather than for falsiness.
- Only the first declaration counts; a second `budget:` line is ignored.
- A malformed first declaration is still the declaration: `budget: x`
  followed by `budget: 4` is `#f`, not `4`. Reading past a typo to a later
  line would make the file's meaning depend on how far down a mistake sits.
- The header may appear anywhere in the file, not only first, because a
  hand-edited file is not ordered.

## `(text->breakpoints text)`

Unchanged in contract, with one addition: a `budget:` line is not a
breakpoint and is skipped, as any other unparseable line already is.

## `(breakpoints->text breakpoints budget)`

The store's text, with the budget preserved. `budget` is optional and
defaults to `#f`, so the one-argument form in `docs/specs/breakpoints.md`
remains exactly what it was.

- `budget` of `#f` writes only the breakpoints, byte for byte as the
  one-argument form did, so a host store never grows a header.
- A budget writes `budget: N` as the first line, then the breakpoints.
- `(text->breakpoints (breakpoints->text bs b))` is `bs`, and
  `(breakpoint-budget (breakpoints->text bs b))` is `b`, for any list and
  any budget including `0`.

## `(within-budget breakpoints budget)`

The breakpoints that fit.

- All of them when `budget` is `#f`.
- The first `budget` of them otherwise, in order, because the ones set
  first are the ones the user has been working with.
- The empty list for a budget of `0`.
- All of them when there are fewer than the budget; this never pads.

## `(budget-report placed total budget)`

What the editor says after placing.

- `#f` when `budget` is `#f` or when nothing was dropped, because a report
  that always fires is noise.
- `"placed 4 of 7, the budget in .helix/test-debug-breakpoints is 4"` when
  breakpoints were dropped, with `placed` and `total` written as numbers.
- The message names the file, since the budget is not something the editor
  was told: it has to be discoverable from the message alone.
