# Recognising an embedded cargo project

A crate that runs on a microcontroller says so in `.cargo/config.toml`: it
names a runner that flashes, and a default target triple. Both matter here.
The runner tells the cog that a local launch is wrong, and names the chip.
The triple tells it where cargo left the artifact.

```toml
[target.'cfg(all(target_arch = "arm", target_os = "none"))']
runner = "probe-rs run --chip RP2040 --protocol swd"

[build]
target = "thumbv6m-none-eabi"
```

## `(cargo-runner text)`

The runner command a config declares, or `#f`.

- The value of the first `runner = "..."` assignment, with the quotes
  removed and the contents kept verbatim.
- Spacing around the `=` is tolerated, as is leading whitespace.
- A commented-out assignment is ignored: unlike a `RUN_TEST` call, where a
  false positive costs a test that fails to run, a false positive here
  sends every launch to a debug probe that is not there.
- `#f` when nothing assigns one, which includes the empty string.
- Single quotes are not TOML string quotes for this purpose; only `"` is
  recognised.

## `(probe-rs-runner? runner)`

Whether a runner flashes through probe-rs.

- `#t` when the runner's first word is `probe-rs`, or ends in `/probe-rs`
  so an absolute path still counts.
- `#f` for `#f`, for the empty string, and for any other runner such as
  `qemu-system-arm` or `cargo run`: recognising a runner the cog cannot
  drive would be worse than not recognising it, because the launch would
  be built for the wrong tool.

## `(runner-chip runner)`

The chip a probe-rs runner names, or `#f`.

- The argument after `--chip`, so `probe-rs run --chip RP2040 --protocol
  swd` is `"RP2040"`.
- `--chip=RP2040` is the same chip.
- `#f` when no `--chip` appears, and when it appears with no value after
  it. probe-rs can detect a chip itself, so this is missing information
  rather than an error, and the caller decides what to do.
- The value is returned verbatim, including case: probe-rs matches case
  insensitively but reports the canonical spelling, and echoing what the
  project wrote is what makes a status line recognisable.

## `(cargo-build-target text)`

The default target triple a config declares, or `#f`.

- The value of `target = "..."` under `[build]`.
- `#f` when no `[build]` section declares one, which is the host case.
- A `target` assignment outside `[build]` is not the default target: a
  `[target.'cfg(...)']` section header contains the word and must not be
  mistaken for it.

## `(artifact-directory triple profile)`

Where cargo leaves artifacts, relative to the crate root.

- `target/thumbv6m-none-eabi/debug` for a triple and `"debug"`.
- `target/debug` when `triple` is `#f`, which is the host layout.
- The profile is appended verbatim, so `"release"` works without a second
  function.
