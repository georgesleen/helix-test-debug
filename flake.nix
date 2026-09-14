{
  description = "Debug the test under the cursor in Helix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
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
