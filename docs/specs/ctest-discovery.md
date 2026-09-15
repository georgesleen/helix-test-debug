# Discovering tests from ctest

`ctest --show-only=json-v1`, run in a configured build directory, reports
every registered test with the exact command that runs it:

```json
{ "kind": "ctestInfo",
  "tests": [ { "name": "MathTest.Doubles",
               "command": ["/w/build/suite", "--gtest_filter=MathTest.Doubles"],
               "properties": [ { "name": "WORKING_DIRECTORY", "value": "/w/build" } ] } ] }
```

This is why the C and C++ half needs no per-framework filter flags: ctest
already encodes them. The `command` key is absent until the target is built,
so a discovery that returns nothing means "build first", not "no tests".

## `(ctest-tests text)`

The tests ctest reported, as a list of
`(name executable arguments working-directory)`.

- `arguments` is the command's tail as a list of strings, and may be empty.
- `working-directory` is the `WORKING_DIRECTORY` property, or `#f` when
  absent.
- A test whose `command` is absent is returned with `#f` for the executable
  and an empty argument list, since its name is still real and still worth
  offering.
- Malformed JSON yields the empty list rather than failing: a build directory
  can be half configured.
- The empty list for input with no `tests` key.
- Order is ctest's order, unsorted.

## `(ctest-test-name test)`, `(ctest-test-executable test)`, `(ctest-test-arguments test)`, `(ctest-test-directory test)`

Accessors for that tuple.

## `(matching-tests candidate tests)`

The tests a cursor candidate refers to, in ctest's order.

- An exact name match, when one exists, is returned alone.
- Otherwise every test whose name starts with `candidate` followed by `/`,
  which is how a parameterized or typed test registers: `Suite.Name/0`.
- The empty list when nothing matches, which is the signal to fall back to
  the picker rather than to report an error.
- A candidate of `#f` yields the empty list.

## `(build-directory root exists?)`

The build directory under a project root, or `#f`.

Tried in order: `build`, `cmake-build-debug`, `cmake-build-release`. The
first whose `CMakeCache.txt` exists wins, so a configured directory is
preferred over a merely present one. `exists?` is injected.

## `(project-root path exists?)`

The nearest ancestor directory of `path` holding a `CMakeLists.txt`, or `#f`.

A file may sit under a subdirectory with its own `CMakeLists.txt`, so the
nearest one wins and the caller looks for a build directory from there
upward if it finds none.
