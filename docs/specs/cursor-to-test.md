# Finding the test under the cursor

## `(source-lines text)`

Splits `text` on newline into a list of strings.

## `(function-name line)`

The name of the function declared on `line`, or `#f` when it declares none.

- Accepts `pub`, `pub(crate)`, `pub(super)`, `pub(self)`, `async`, `const`,
  `unsafe`, `extern "ABI"` and `default` before `fn`.
- The name ends at the first `(` or `<`, so `foo()` and `foo<T>(` both yield
  `foo`.
- A line using `fn` in a type position, such as a `let` binding of a
  function pointer, declares nothing.

## `(test-attribute? line)`

True when the trimmed line starts with `#[` and contains `test`. This
accepts `#[test]` and the async variants such as `#[tokio::test]`.

## `(test-at-line lines line-index)`

The test enclosing `line-index` as `(name declaration-line-index)`, or `#f`.

- The cursor may be in the body, on the declaration, or on the attribute
  block above it.
- Attributes, comments and blank lines may sit between the attribute and the
  declaration.
- A declaration without a test attribute yields `#f`.
- An empty `lines` yields `#f`, and a `line-index` past the end is clamped to
  the last line.

## `(test-name test)` and `(test-declaration-line test)`

Accessors for the pair `test-at-line` returns. The second is a line index.

## `(declaration-name-at lines line-index)`

The nearest declaration name at or above `line-index` regardless of
attributes, or `#f`. This is what the failure message names when the cursor
is not in a test.

## `(breakpoint-line declaration-line-index)`

The one-based line number of the declaration's first body line.

A breakpoint on the declaration itself resolves to two locations and stops in
the closure the test harness wraps around the test, several frames from the
code the user meant, which is why the body's first line is used instead.
