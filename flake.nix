{
  description = "Debug the test under the cursor in Helix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      # The debugger template :debug-test drives. Splice it into the
      # templates list of your own rust language entry; a second [[language]]
      # entry for the same name would not merge.
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
              steel
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
