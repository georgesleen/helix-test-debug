# Changelog

Versions stay below 1.0.0 while the command surface and the Steel API it
depends on are still moving. Breaking changes may land in any 0.y bump.

## Unreleased

- `:debug-variables` is now a focus-preserving vertical split backed by a
  plain text file. `helix-dap-vars` proxies any stdio DAP adapter, refreshes
  locals on every stop, and removes the file when the session ends so the
  split closes itself. The proxy and Steel module are usable without this
  cog and are exported through the flake.
- The native coloured-output API now lives as normal commits in the
  `georgesleen/helix` Steel fork. The flake no longer patches a Helix
  package at build time.

- Failed runs and debug sessions open their output automatically. Helix
  now retains DAP output through session exit instead of replacing the
  status line once per event. ANSI SGR colours render as native styles in
  a searchable scratch buffer, with no escape codes in its text.
  `:debug-output` reopens the most recent run or session.
- Breakpoints can be toggled more than once in a workspace. Steel's
  `call-with-output-file` opens with `create_new` since 0.8.3, so every
  write after the one that created `.helix/test-debug-breakpoints` raised
  `File exists` and the toggle reported that it could not write. Files are
  now replaced rather than created, which the same fix applies to the CMake
  file API query.
- Background commands no longer paint over the editor. Cargo reports
  progress on stderr, which was inherited from Helix and drew `Finished
  ...` and `Running unittests ...` across the TUI; stdin, stdout and
  stderr are all piped now, so a `:run-here` shows only its statusline
  result. The integration check proves it against a real Helix.
- Every command's help text is one short line, so `<space>G` and the
  command palette list them the way Helix lists its own debug commands
  instead of wrapping and pushing entries off the panel.
- Verified on a second architecture: an ESP32-S3 over its built-in
  USB-JTAG, with a real ESP-IDF project. `make hardware-check` takes
  `HARDWARE_REQUEST=attach` for it, which is the only thing that works on
  that target -- a launching template's breakpoint is cleared by the
  bootloader's CPU reset on the way to the app. See docs/embedded.md.
- `make hardware-check` reports an adapter that refused to start, with the
  adapter's own message, instead of waiting out its timeout. The usual
  cause is a probe that cannot serve the requested chip, which `probe-rs
  list` finding *a* probe does not rule out.
- Ambiguity is refused rather than guessed at, everywhere it can arise. A
  PlatformIO project with two boards says so and points at `default_envs`;
  a cargo build with several binaries is resolved by which one's own source
  is under the cursor, and otherwise names them. Flashing or debugging the
  wrong artifact was the alternative.
- CMake build directories come from `CMakePresets.json` before any
  conventional name, so a project building in `out/build/default` is found.
- Multi-config generators work: configurations are asked one at a time,
  debuggable ones first, because Ninja Multi-Config and Visual Studio
  describe the same target once per configuration, and asking across all of
  them looked like a project with several images.
- PlatformIO's `build_dir` is read rather than assumed, and an environment
  inheriting its platform from `[env]` is understood.
- A cargo build whose profile carries no debug information is called out
  before the launch instead of producing a breakpoint that never binds.
- `:debug-doctor` checks every template's name *and* arity. Helix fills
  template arguments positionally, so a `firmware` template with one
  completion silently never receives the chip.
- Two debugger templates are exported for cases that needed no code:
  `probeRsFirmwareAttachTemplate` for a target flashed by its own tooling,
  and `probeRsFirmwareRttTemplate` for target output over RTT.
- PlatformIO and Unity: `:debug-here` builds a test folder's program and
  stops in the test under the cursor. A `RUN_TEST` call in the folder is
  what makes a function a test, since Unity marks nothing. `:run-here` runs
  the folder and reports PlatformIO's summary.
- Embedded C and C++: a cross-compiled CMake project debugs the line under
  the cursor on the target. The image is the non-imported executable that
  CMake's file API says compiles that source, or links whatever does, so
  Zephyr, ESP-IDF, the Pico SDK and CubeMX output work without the cog
  knowing any of them: an SDK's own tools and boot stages are not mistaken
  for firmware, and a project whose sources live in a library -- which is
  how ESP-IDF builds every project -- still finds its image. PlatformIO
  firmware environments too.
- Component-based CMake projects work: the project a file belongs to is the
  nearest ancestor that is *configured*, not the nearest with a
  CMakeLists.txt. ESP-IDF and Zephyr put one in every component directory,
  so the old rule stopped at `main/` and concluded the file was not part of
  a CMake project at all.
- A source in a subdirectory is matched against CMake's own spelling of it.
  The cursor file was compared by base name, which only ever worked because
  every fixture kept its sources at the top level.
- `make hardware-check` drives `:debug-here` against a real board through a
  real adapter and asserts the DAP exchange: the image was flashed, the
  breakpoint bound, the core stopped there, target memory was readable. The
  project, chip and adapter are inputs, so it is not specific to a board.
  It skips itself without hardware and stays outside `make check`.
- Nothing is tied to one chip, vendor, toolchain or probe: a cargo crate is
  firmware because it declares a runner, whatever that runner is, and which
  adapter to drive is the launch template's business.
- Verified on hardware, not only against a stub: a Pico 2 over a Raspberry
  Pi Debug Probe flashed from the launch, stopped on the requested source
  line, and showed target variables in Helix.
- Embedded targets: a crate with a runner launches through
  `probe-rs dap-server` with the chip its runner names, and the breakpoint
  is delivered by Helix rather than by the launch, because probe-rs takes
  none. Debugging a single embedded test is refused with its reason.
- `:test-pick` works in a PlatformIO project, listing the tests a RUN_TEST
  call names across every test folder.
- A workspace can declare a breakpoint budget, for targets with a fixed
  number of hardware breakpoints.
- The commands are renamed: `:test-debug` is `:debug-here` (alias `:dbgh`),
  `:test-run` is `:run-here`, and the other `test-` commands that are no
  longer test-specific take the `debug-` prefix. `:test-pick` keeps its
  name, being the one command that is only about tests.

- A line that is not in a test is debuggable: `:debug-here` builds the
  crate's binary and stops at the cursor. `:run-here` runs it and reports
  its last line, `:debug-failure` stops where it panicked. Needs the
  new `program at line` template.

- `:debug-breakpoint` remembers a breakpoint in
  `.helix/test-debug-breakpoints` under the workspace root, and it is placed
  again on the first launch after a restart. `:debug-breakpoints` and
  `:debug-breakpoints-clear` drive it by hand.

- `:test-pick` picks a test from anywhere in the crate and debugs it: type
  to filter by subsequence, up and down to move, enter to debug. Rust only.
- Removed the libtest `--list` parser. Discovery reads the sources instead,
  which needs no build and yields the line to stop on.

- C and C++ support for `:debug-here`, through CMake and ctest. Detection is
  a macro table covering GoogleTest, Catch2, doctest and Boost; ctest is the
  authority on which tests exist and how they are run.
- The pure half is split into one module per spec under `test-debug/`, with
  only `test-debug/rust/` and `test-debug/cpp/` knowing a language.

- Commands renamed for discoverability: `test-debug`, `test-run`,
  `test-again`, `test-doctor` act on the test under the cursor; `debug-*`
  act on a running session.
- `:debug-failure` runs the test and, when it fails, starts a session
  stopped at the line that panicked.
- `:debug-cancel` abandons the wait on a build in flight.
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
