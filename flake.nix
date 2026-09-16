{
  description = "Debug the test under the cursor in Helix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      # The debugger templates the cog drives. Splice them into the templates
      # list of your own language entry; a second [[language]] entry for the
      # same name would not merge.
      lib.rustDebuggerTemplate = {
        name = "cargo test at line";
        request = "launch";
        completion = [
          {
            name = "test binary";
            completion = "filename";
          }
          { name = "test filter"; }
          { name = "source file"; }
          { name = "line"; }
        ];
        args = {
          program = "{0}";
          args = [
            "{1}"
            "--exact"
            "--include-ignored"
            "--test-threads=1"
            "--nocapture"
          ];
          preRunCommands = [ "breakpoint set --file {2} --line {3}" ];
        };
      };

      # For an embedded target flashed by probe-rs, which takes no
      # breakpoint in its launch request: the cog places one in helix and
      # helix delivers it over setBreakpoints. Needs its own debugger block,
      # not just this template, since probe-rs is not lldb.
      lib.probeRsFirmwareTemplate = {
        name = "firmware";
        request = "launch";
        completion = [
          {
            name = "elf";
            completion = "filename";
          }
          { name = "chip"; }
        ];
        args = {
          chip = "{1}";
          flashingConfig = {
            flashingEnabled = true;
            haltAfterReset = true;
          };
          coreConfigs = [
            {
              coreIndex = 0;
              programBinary = "{0}";
            }
          ];
        };
      };

      # Firmware with the target's own output in the debug console. Embedded
      # projects log over RTT rather than stdout, so without this a
      # `:run-here` on hardware shows nothing. rttEnabled and
      # rttChannelFormats are flattened into each core's configuration, per
      # probe-rs's RttConfig.
      lib.probeRsFirmwareRttTemplate = {
        name = "firmware";
        request = "launch";
        completion = [
          {
            name = "elf";
            completion = "filename";
          }
          { name = "chip"; }
        ];
        args = {
          chip = "{1}";
          flashingConfig = {
            flashingEnabled = true;
            haltAfterReset = true;
          };
          coreConfigs = [
            {
              coreIndex = 0;
              programBinary = "{0}";
              rttEnabled = true;
            }
          ];
        };
      };

      # For a target somebody else flashed, or one whose image its own
      # tooling has to assemble: an ESP-IDF app needs a bootloader and a
      # partition table beside it, so `idf.py flash` puts it there and this
      # only attaches. The cog drives whichever template is named
      # `firmware`, so use this one *instead* of the launching template.
      #
      # No flashingConfig: probe-rs rejects an attach request carrying any
      # flashing option rather than ignoring it.
      lib.probeRsFirmwareAttachTemplate = {
        name = "firmware";
        request = "attach";
        completion = [
          {
            name = "elf";
            completion = "filename";
          }
          { name = "chip"; }
        ];
        args = {
          chip = "{1}";
          coreConfigs = [
            {
              coreIndex = 0;
              programBinary = "{0}";
            }
          ];
        };
      };

      # For the crate's own binary, stopped at the cursor: a line that is not
      # in a test. A template's arguments are positional, so one with no
      # filter has to be its own template.
      lib.programDebuggerTemplate = {
        name = "program at line";
        request = "launch";
        completion = [
          {
            name = "binary";
            completion = "filename";
          }
          { name = "source file"; }
          { name = "line"; }
        ];
        args = {
          program = "{0}";
          preRunCommands = [ "breakpoint set --file {1} --line {2}" ];
        };
      };

      # For a binary ctest already named, which needs no filter flag because
      # ctest reported the argument that selects the test.
      lib.binaryDebuggerTemplate = {
        name = "binary at line";
        request = "launch";
        completion = [
          {
            name = "binary";
            completion = "filename";
          }
          { name = "test argument"; }
          { name = "source file"; }
          { name = "line"; }
        ];
        args = {
          program = "{0}";
          args = [ "{1}" ];
          preRunCommands = [ "breakpoint set --file {2} --line {3}" ];
        };
      };

      # Installs both halves of the cog. The require line stays yours,
      # because helix.scm is where your own commands live and a module
      # cannot own that file without clobbering them.
      homeManagerModules.default =
        { config, lib, ... }:
        {
          options.programs.helix.testDebug.enable = lib.mkEnableOption "the helix-test-debug cog";

          config = lib.mkIf config.programs.helix.testDebug.enable {
            xdg.configFile."helix/cogs/test-debug.scm".source = "${self}/test-debug.scm";
            xdg.configFile."helix/cogs/test-debug-rust.scm".source = "${self}/test-debug-rust.scm";
            xdg.configFile."helix/cogs/test-debug-cpp.scm".source = "${self}/test-debug-cpp.scm";
            # The modules those two require, resolved relative to themselves.
            xdg.configFile."helix/cogs/test-debug" = {
              source = "${self}/test-debug";
              recursive = true;
            };
          };
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              gnumake
              nixfmt
              # Also provides steel-language-server, which is the tooling
              # this code has: there is no Scheme formatter here on purpose,
              # see README.md.
              steel
              # Drives the multi-config phase of the integration check,
              # which needs a generator that builds several configurations
              # out of one build directory.
              ninja
              # Drives tests/pio-fixture, which the integration check uses
              # for the Unity path. Its core directory needs the network
              # once, to install the native platform.
              platformio
              # The DAP adapter for an embedded target, and the one the
              # hardware check drives by default.
              probe-rs-tools
              # tests/pico-sdk-fixture builds against these. picotool is
              # here so the SDK finds an install of exactly its version
              # rather than fetching and building one, which is the only
              # step in that build that would need the network.
              pico-sdk
              picotool
            ];

            # The SDK is found through this variable, not through CMAKE
            # search paths, so tests/pico-sdk-fixture needs it set.
            PICO_SDK_PATH = "${pkgs.pico-sdk}/lib/pico-sdk";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          tests = pkgs.runCommand "helix-test-debug-tests" { nativeBuildInputs = [ pkgs.steel ]; } ''
            cd ${self}
            steel tests/rust-test.scm | tee $out
            steel tests/cpp-test.scm | tee -a $out
          '';

          compile-check =
            pkgs.runCommand "helix-test-debug-compile-check"
              {
                nativeBuildInputs = [
                  pkgs.gnumake
                  pkgs.steel
                ];
              }
              ''
                cp -r ${self} source
                chmod -R u+w source
                make -C source compile-check | tee $out
              '';

          format = pkgs.runCommand "helix-test-debug-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${self}/flake.nix | tee $out
          '';
        }
      );
    };
}
