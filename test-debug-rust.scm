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

(provide base-name
         breakpoints->text
         check
         clamp-line
         crate-root
         debugger-command
         diagnosis
         diagnosis-ok?
         dirty-buffer-warning
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
         text-after
         breakpoint-line
         build-arguments
         declaration-name-at
         enclosing-modules
         executable-from-cargo-output
         function-name
         module-prefix
         outcome-failed?
         panic-location
         qualified-test-name
         run-arguments
         strip-rust-extension
         target-arguments
         test-at-line
         test-attribute?
         test-declaration-line
         test-name
         test-names-from-list
         test-outcome)
