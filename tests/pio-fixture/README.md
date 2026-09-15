# PlatformIO fixture

A PlatformIO project for the cog's PlatformIO/Unity support, built with
`platform = native` so `pio test` compiles and runs the Unity tests with the
host toolchain. No microcontroller, no probe, no serial port.

`test/test_divider/test_divider.c` is shaped for detection, not for coverage:
Unity marks nothing, so a `void test_*(void)` is a test only because `main`
calls `RUN_TEST` on it. The file therefore carries an unregistered
`test_unregistered_is_never_run`, and `test_halves` is a prefix of
`test_halves_negative`.

## Running it

PlatformIO is not in the devshell:

    nix shell nixpkgs#platformio --command bash -c \
      'cd tests/pio-fixture && pio test -e native'

The test executable lands at `.pio/build/native/program` and runs standalone,
which is what a debugger needs:

    ./.pio/build/native/program

## Network

**The first run needs network.** PlatformIO downloads the `native` platform,
`tool-scons` and `throwtheswitch/Unity` into `PLATFORMIO_CORE_DIR`
(`~/.platformio` by default, ~4.6 MB here). With an empty core dir and no
network it fails at `Platform Manager: Installing native` with
`HTTPClientError`.

**After that it is fully offline.** Verified under `unshare -rn`: a repeat run
passes, and so does a run after `rm -rf .pio`, because the downloads are cached
in the core dir. A sandboxed check must either inherit a warm
`PLATFORMIO_CORE_DIR` or pre-populate one; it cannot start cold.

## Two things worth knowing

`pio test --list-tests` reports the test *folder* (`native / test_divider`),
never the individual functions — discovery has to read the source.

The built runner takes no filter arguments. Unity only parses `-n`/`-f` when
compiled with `UNITY_USE_COMMAND_LINE_ARGS`, so `program -n test_halves` here
runs all three tests and exits 0.
