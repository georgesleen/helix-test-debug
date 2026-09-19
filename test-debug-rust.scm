;; helix-test-debug: the rust half plus the shared modules, gathered for the editor
;; half and the tests. Each module names its own spec; see docs/specs/.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require "test-debug/text.scm")
(require "test-debug/paths.scm")
(require "test-debug/breakpoints.scm")
(require "test-debug/diagnosis.scm")
(require "test-debug/messages.scm")
(require "test-debug/rust/cursor.scm")
(require "test-debug/rust/names.scm")
(require "test-debug/rust/cargo.scm")
(require "test-debug/rust/discover.scm")
(require "test-debug/rust/binary.scm")
(require "test-debug/rust/embedded.scm")

(provide base-name
         cargo-build-target
         embedded-run-arguments
         cargo-runner
         cross-target?
         remote-launch?
         probe-rs-runner?
         runner-chip
         breakpoint-budget
         breakpoints->text
         budget-report
         within-budget
         check
         clamp-line
         crate-root
         debugger-command
         diagnosis
         diagnosis-ok?
         template-arity
         template-present?
         dirty-buffer-warning
         output-report
         drop-trailing-colon
         identifier-prefix
         identifier-prefix-until
         indentation
         join-path
         member?
         parent-directory
         path-within
         source-lines
         template-present?
         text->breakpoints
         toggle-breakpoint
         text-after
         bin-executable-from-cargo-output
         bin-names-from-cargo-output
         cargo-artifact-debuggable?
         binary-build-arguments
         binary-label
         binary-run-arguments
         binary-target-arguments
         breakpoint-line
         compiled-source?
         discovered-line
         discovered-name
         discovered-path
         discovery-summary
         matching-tests-by-name
         tests-in-file
         build-arguments
         declaration-name-at
         enclosing-modules
         executable-from-cargo-output
         function-name
         failure-hit-count
         lldb-hit-count-arguments
         module-prefix
         outcome-failed?
         panic-location
         qualified-test-name
         run-arguments
         test-binary-arguments
         strip-rust-extension
         target-arguments
         test-at-line
         test-attribute?
         test-declaration-line
         test-name
         test-outcome)
