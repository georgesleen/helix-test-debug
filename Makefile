.PHONY: test fmt check

test:
	steel tests/rust-test.scm

fmt:
	nixfmt flake.nix

check: test
	nixfmt --check flake.nix
