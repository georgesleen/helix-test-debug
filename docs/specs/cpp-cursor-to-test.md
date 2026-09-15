# Finding the C or C++ test under the cursor

C and C++ have no universal test attribute the way Rust has `#[test]`. Each
framework spells a test as a macro, and large codebases wrap those macros in
their own. So detection is table driven: a macro name plus the shape of its
arguments.

Detection only has to produce a **candidate** name. The authority on what
tests exist is the build system, so a candidate is matched against ctest's
list rather than trusted outright. See ctest-discovery.md.

## Shapes

Two shapes cover every framework worth supporting.

`suite-name`: two identifier arguments, rendered `Suite.Name`.

```
TEST(MathTest, Doubles)        -> MathTest.Doubles
TEST_F(MathFixture, Doubles)   -> MathFixture.Doubles
BOOST_AUTO_TEST_CASE(Doubles)  -> Doubles
```

`string-name`: one string literal argument, rendered as its contents.

```
TEST_CASE("doubles a value")   -> doubles a value
SCENARIO("a full turn")        -> a full turn
```

## `(test-macros)`

The built-in table, as a list of `(macro shape)` pairs:

```
("TEST" suite-name)          ("TEST_F" suite-name)
("TEST_P" suite-name)        ("TYPED_TEST" suite-name)
("TYPED_TEST_P" suite-name)  ("BOOST_AUTO_TEST_CASE" suite-name)
("TEST_CASE" string-name)    ("SCENARIO" string-name)
("BOOST_FIXTURE_TEST_CASE" suite-name)
```

`BOOST_AUTO_TEST_CASE` takes one identifier, which the `suite-name` shape
renders without a suffix when the second argument is absent.

## `(macro-invocation line macros)`

The test macro invoked on `line` as `(macro shape arguments)`, or `#f`.

- `arguments` is the raw text between the outermost parentheses, untrimmed.
- The macro name must be the first token on the trimmed line. A macro
  mentioned inside a comment, a string, or a call argument is not an
  invocation.
- An invocation whose parentheses do not close on the same line still
  matches; the caller supplies the remaining lines.
- A macro not in `macros` yields `#f`, which is what makes the table the
  single point of extension.

## `(candidate-name macro-invocation)`

The candidate test name, or `#f` when the arguments do not fit the shape.

- `suite-name` with two arguments renders `Suite.Name`, trimming whitespace
  around each.
- `suite-name` with one argument renders that argument alone.
- `suite-name` with more than two arguments yields `#f`: that is a macro we
  have mis-tabled, and guessing would debug the wrong test.
- `string-name` renders the contents of the first string literal, with
  escapes left exactly as written. An escape is still recognised while
  scanning, so a quoted quote does not end the literal.
- `string-name` with no string literal yields `#f`.

## `(cpp-test-at-line lines line-index macros)`

The test enclosing a zero-based line as `(candidate declaration-line-index)`,
or `#f`. The rust half's `test-at-line` takes no macro table and this one does,
hence the prefix on both colliding names, and the dispatch in the editor half supplies it.

- Scans upward for the nearest macro invocation from the table.
- A cursor on the invocation line itself counts as inside it.
- Stops at a line that closes a previous test body at column zero, so a
  cursor between two tests does not report the one above.

## `(cpp-breakpoint-line declaration-line-index lines)`

The one-based line number of the first statement in the body.

Unlike Rust, the opening brace may sit on the macro line or on its own line,
so this scans forward from the declaration for the line after the first `{`
and returns the first line after it that is neither blank nor a comment.
Both comment styles count, including a continuation line of a block comment.

A declaration with no body yields `#f`. There is no first statement, and
naming a line past the end of the buffer would send the adapter somewhere
that does not exist.
