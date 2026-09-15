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
              # Drives tests/pio-fixture, which the integration check uses
              # for the Unity path. Its core directory needs the network
              # once, to install the native platform.
              platformio
              # The DAP adapter for an embedded target. See docs/embedded.md;
              # nothing here drives it yet.
              probe-rs-tools
            ];
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
