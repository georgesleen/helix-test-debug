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

## `(template-present? text name)`

True when a `languages.toml` names this debugger template.

## `(debugger-command text)`

The adapter command a `languages.toml` configures, or `#f`.

The first `command` after the `[language.debugger]` table is the adapter;
the language servers above it have their own, and a later table ends the
search.

## `(dirty-buffer-warning name)`

The message reported when the buffer holding the test had unsaved changes
and was written automatically before building: `saved <name> before
building`, with `<name>` unchanged.
