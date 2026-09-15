# Finding the Unity test the cursor is in

Unity has no test attribute. A test is an ordinary function,
`void test_divider_halves(void)`, and what makes it a test is a
`RUN_TEST(test_divider_halves);` call in the runner's `main`. So the rule
that works for GoogleTest — match a macro invocation at the cursor — does
not apply here, and the authority for "is this a test" lives in a different
file from the cursor.

Detection is therefore two steps: name the function the cursor is in, then
confirm something runs it.

## `(unity-function-at-line lines line)`

The function the cursor is inside, as `(name declaration-line)` with a
zero-based declaration line, or `#f`.

- A definition is a line whose text, ignoring leading whitespace, matches a
  return type, a name, and a parenthesis: `void test_x(void) {`.
- `static` and `extern` before the return type are skipped, as are extra
  qualifiers, because a test may be `static void test_x(void)`.
- The cursor may be on the declaration line itself, inside the body, or on
  the closing brace.
- The nearest definition at or above the cursor wins. Nesting is not a
  concern in C, so there is no enclosing-scope search.
- A call is not a definition: `RUN_TEST(test_x);` names a function but
  declares none, so a cursor on that line finds whatever function encloses
  it, which is the runner's `main`.
- A prototype is not a definition: a line ending in `;` after the closing
  parenthesis declares nothing to stop in.
- `#f` for no lines, and for a cursor above the first definition.

## `(run-test-names lines)`

The names a source registers, in the order registered.

- One entry per `RUN_TEST(name)` invocation, with the name trimmed.
- `RUN_TEST_CASE`, `RUN_TEST_P` and any other longer spelling are not
  `RUN_TEST` and are ignored: the name must be exactly `RUN_TEST`, so
  `MY_RUN_TEST(x)` does not count either.
- Whitespace inside the invocation is allowed: `RUN_TEST ( x ) ;`.
- A commented-out registration is still reported. Distinguishing a real
  call from a comment needs a parser, and a false positive here is a test
  that fails to run rather than a wrong test being debugged.
- Several registrations on one line are all reported.
- The empty list when nothing registers anything.
- Names are returned verbatim, with duplicates kept, because a name
  registered twice is a fact about the file rather than something to tidy.

## `(unity-test-registered? name registrations)`

Whether a candidate is a test.

- `#t` when `name` appears in `registrations`.
- Comparison is exact: C is case-sensitive, and no prefix is stripped, so
  `test_x` does not match `test_x_again`.
- `#f` for an empty registration list, which is what an unbuilt or
  unregistered project looks like.

## `(unity-breakpoint-line declaration lines)`

The line to stop on, one-based: the first line of the body, so a breakpoint
does not land on the signature.

- The body starts after the line carrying the opening brace, which may be
  the declaration line or a line below it.
- A declaration whose body never opens yields the line after the
  declaration, clamped to the file, rather than a line past the end.
- This is the same rule the GoogleTest path uses, and deliberately so: the
  two differ in how a test is recognised, not in where to stop.
