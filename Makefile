.PHONY: test compile-check fmt check clean

CHECK_DIR = .compile-check

test:
	steel tests/rust-test.scm

# Load the editor half against stub helix modules, so every identifier it
# uses has to resolve. Helix's helix/core/text is a Rust module with no
# scheme form, so that one require is swapped for a stub module.
compile-check:
	rm -rf $(CHECK_DIR)
	mkdir -p $(CHECK_DIR)
	cp test-debug-rust.scm $(CHECK_DIR)/
	cp -r tests/stubs/helix $(CHECK_DIR)/helix
	sed 's|(require-builtin helix/core/text as text.)|(require (prefix-in text. "helix/text.scm"))|' \
		test-debug.scm > $(CHECK_DIR)/test-debug.scm
	printf '(require "test-debug.scm")\n(displayln "editor half compiles")\n' > $(CHECK_DIR)/driver.scm
	steel $(CHECK_DIR)/driver.scm
	rm -rf $(CHECK_DIR)

fmt:
	nixfmt flake.nix

check: test compile-check
	nixfmt --check flake.nix

clean:
	rm -rf $(CHECK_DIR)
