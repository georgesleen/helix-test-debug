# The setup check

## `(check label ok remedy)`

One diagnosis entry: what was checked, whether it passed, and what to do
when it did not.

## `(diagnosis checks)`

The report as one statusline-sized string.

- All passing yields `<n> checks passed`.
- Otherwise only the failures appear, each as `<label>: <remedy>`, joined by
  `; `. Passing checks are silent, because a report a user must read past is
  a report they will not read.

## `(diagnosis-ok? checks)`

True when no check failed.

## `(template-arity text name)`

The number of completion entries a named debugger template declares, or
`#f` when `languages.toml` has no such template.

Arity matters as much as the name, because helix fills a template's
arguments positionally. A `firmware` template declaring one completion is
handed the image and never sees the chip; one declaring three is handed an
empty string where it expected a value. Both look like the adapter
misbehaving rather than like a configuration error.

- Completion entries are tables, counted whether the array is written on
  one line or spread over several.
- `0` for a template declaring no `completion`, which is a real arity and
  not an absence.
- Counts are per template: several in one file, with `args` tables between
  them, are not merged.

## `(template-present? text name)`

True when a `languages.toml` declares this debugger template at all.

## `(debugger-command text)`

The adapter command a `languages.toml` configures, or `#f`.

The first `command` after the `[language.debugger]` table is the adapter;
the language servers above it have their own, and a later table ends the
search.

## `(dirty-buffer-warning name)`

The message reported when the buffer holding the test had unsaved changes
and was written automatically before building: `saved <name> before
building`, with `<name>` unchanged.
