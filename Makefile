.PHONY: test compile-check helix-check integration-check fmt check clean

CHECK_DIR = .compile-check

test:
	steel tests/rust-test.scm
	steel tests/cpp-test.scm

# Load the editor half against stub helix modules, so every identifier it
# uses has to resolve. Helix's helix/core/text is a Rust module with no
# scheme form, so that one require is swapped for a stub module.
compile-check:
	rm -rf $(CHECK_DIR)
	mkdir -p $(CHECK_DIR)
	cp test-debug-rust.scm test-debug-cpp.scm test-debug-picker.scm $(CHECK_DIR)/
	cp -r test-debug $(CHECK_DIR)/
	cp -r tests/stubs/helix $(CHECK_DIR)/helix
	sed 's|(require-builtin helix/core/text as text.)|(require (prefix-in text. "helix/text.scm"))|' \
		test-debug.scm > $(CHECK_DIR)/test-debug.scm
	printf '(require "test-debug.scm")\n(displayln "editor half compiles")\n' > $(CHECK_DIR)/driver.scm
	steel $(CHECK_DIR)/driver.scm
	rm -rf $(CHECK_DIR)

# Load the cog in a real Steel-enabled helix. Skips itself when one is not
# on PATH, so CI stays green.
helix-check:
	bash tests/helix-check.sh

# Run the commands in a real Steel-enabled helix against tests/fixture,
# which is the only check that executes a command body. Skips itself when
# helix, cargo or the adapter is missing.
integration-check:
	bash tests/integration.sh

fmt:
	nixfmt flake.nix

check: test compile-check helix-check integration-check
	nixfmt --check flake.nix

clean:
	rm -rf $(CHECK_DIR)
