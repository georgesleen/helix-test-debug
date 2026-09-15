;; helix-test-debug: the rust half, gathered for the editor half and the
;; tests. Each module carries its own spec reference; see docs/specs/.
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
         breakpoint-line
         breakpoints->text
         build-arguments
         check
         crate-root
         debugger-command
         declaration-name-at
         diagnosis
         diagnosis-ok?
         dirty-buffer-warning
         enclosing-modules
         executable-from-cargo-output
         function-name
         indentation
         join-path
         module-prefix
         outcome-failed?
         panic-location
         parent-directory
         path-within
         qualified-test-name
         run-arguments
         source-lines
         target-arguments
         template-present?
         test-at-line
         test-attribute?
         test-declaration-line
         test-names-from-list
         test-outcome
         text->breakpoints)
