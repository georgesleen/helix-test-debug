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

Whether a runner flashes through probe-rs. This is not what decides that a
crate is firmware — see `cross-target?` — it only decides whether a chip
name can be read out of the runner.

- `#t` when the runner's first word is `probe-rs`, or ends in `/probe-rs`
  so an absolute path still counts.
- `#f` for `#f`, for the empty string, and for any other runner.

## `(cross-target? triple host)`

Whether a crate builds for something other than the machine it is built
on, which is what makes a launch remote rather than local.

- `#f` when `triple` is `#f`: no declared target means the host.
- `#f` when `triple` equals `host`, since naming your own triple is not
  cross-compiling.
- `#t` otherwise, for any triple at all. The cog has no list of embedded
  targets and should not have one: `thumbv6m-none-eabi`,
  `riscv32imc-unknown-none-elf`, `xtensa-esp32s3-none-elf` and anything
  released next year are all simply not the host.

## `(remote-launch? runner)`

Whether the crate's binary needs something else to run it.

A declared runner *is* that statement: cargo will not execute the artifact
directly, so neither should the cog. That single fact is the rule, and it
is why no list of targets or tools appears anywhere here.

- `#t` for any non-empty runner: `probe-rs run --chip …`,
  `cargo-embed`, `probe-run`, `espflash flash`, `pyocd`, `qemu-system-arm`,
  an openocd wrapper script, `ssh deploy.sh`, anything.
- `#f` for `#f`, for the empty string, and for whitespace only.
- The runner's identity is never consulted, and neither is the target
  triple. Which adapter to drive, and what to tell it, is what the launch
  template says, and that belongs to the user's `languages.toml`.
- `cross-target?` is kept for what it is actually good for: naming the
  target on the status line and finding the artifact directory.

## `(runner-chip runner)`

The chip a probe-rs runner names, or `#f`.

- The argument after `--chip`, so `probe-rs run --chip RP2040 --protocol
  swd` is `"RP2040"`. Any chip name works: the value is whatever the
  project wrote, not something matched against a list.
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
