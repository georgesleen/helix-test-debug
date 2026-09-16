;; helix-test-debug: the C and C++ half plus the shared modules, gathered for the
;; editor half and the tests. Each module names its own spec; see
;; docs/specs/.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require "test-debug/text.scm")
(require "test-debug/paths.scm")
(require "test-debug/breakpoints.scm")
(require "test-debug/diagnosis.scm")
(require "test-debug/messages.scm")
(require "test-debug/cpp/cursor.scm")
(require "test-debug/cpp/ctest.scm")
(require "test-debug/cpp/unity.scm")
(require "test-debug/cpp/pio.scm")
(require "test-debug/cpp/cmake.scm")

(provide base-name
         build-type-debuggable?
         cmake-build-type
         cmake-cross-system?
         cmake-toolchain-file
         codemodel-reply
         codemodel-targets
         sole-artifact
         target-artifact
         pio-build-arguments
         pio-debug-build
         pio-chip
         pio-environment
         pio-environment-platform
         pio-firmware-build
         pio-firmware-environment
         pio-firmware-path
         pio-environments
         pio-outcome
         pio-program-path
         pio-root
         pio-run-arguments
         pio-test-folder
         run-test-names
         unity-breakpoint-line
         unity-function-at-line
         unity-test-registered?
         unity-tests-in-file
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
         test-macros
         macro-invocation
         macro-invocation-macro
         macro-invocation-shape
         macro-invocation-arguments
         candidate-name
         cpp-test-at-line
         cpp-breakpoint-line
         ctest-tests
         ctest-test-name
         ctest-test-executable
         ctest-test-arguments
         ctest-test-directory
         matching-tests
         build-directory
         project-root)
