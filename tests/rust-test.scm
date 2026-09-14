;; Tests for the rust half. Runs under a bare steel interpreter.
;;
;; Copyright (C) 2026 George Sleen
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require "harness.scm")
(require "../test-debug-rust.scm")

;; A test module shaped like the real thing: a plain function above, an
;; attribute block, a test, and a second test with a doc comment between
;; the attribute and the declaration.
(define source
  (string-append
   "mod tests {\n"                                  ; 0
   "    use super::*;\n"                             ; 1
   "\n"                                              ; 2
   "    fn helper(v: f64) -> f64 {\n"                 ; 3
   "        v * 2.0\n"                                ; 4
   "    }\n"                                          ; 5
   "\n"                                               ; 6
   "    #[test]\n"                                    ; 7
   "    fn settles_when_tail_in_band() {\n"           ; 8
   "        let values = [0.0, 1.0];\n"               ; 9
   "        assert!(check(values));\n"                 ; 10
   "    }\n"                                          ; 11
   "\n"                                               ; 12
   "    #[tokio::test]\n"                             ; 13
   "    // why this one is async\n"                   ; 14
   "    async fn reads_the_port() {\n"                ; 15
   "        assert!(true);\n"                          ; 16
   "    }\n"                                           ; 17
   "}\n"))                                            ; 18

(define lines (source-lines source))

;; function-name: what counts as a declaration
(check-equal! "plain declaration" "helper" (function-name "    fn helper(v: f64) -> f64 {"))
(check-equal! "pub declaration" "run" (function-name "pub fn run() {"))
(check-equal! "pub(crate) declaration" "run" (function-name "    pub(crate) fn run() {"))
(check-equal! "async declaration" "reads_the_port" (function-name "    async fn reads_the_port() {"))
(check-equal! "const unsafe declaration" "raw" (function-name "const unsafe fn raw() {"))
(check-equal! "extern abi declaration" "callback" (function-name "extern \"C\" fn callback() {"))
(check-equal! "generic declaration" "map" (function-name "fn map<T: Clone>(v: T) -> T {"))
(check-equal! "no space before paren" "compact" (function-name "fn compact(){"))
(check-false! "statement is not a declaration" (function-name "        let values = [0.0];"))
(check-false! "closing brace is not a declaration" (function-name "    }"))
(check-false! "struct is not a declaration" (function-name "struct Signal { time: f64 }"))
(check-false! "fn in a type position" (function-name "    let f: fn(f64) -> f64 = helper;"))

;; test-attribute?: which attributes mark a test
(check-true! "plain test attribute" (test-attribute? "    #[test]"))
(check-true! "async test attribute" (test-attribute? "    #[tokio::test]"))
(check-false! "derive is not a test" (test-attribute? "#[derive(Debug)]"))
(check-false! "declaration is not an attribute" (test-attribute? "    fn helper() {"))

;; test-at-line: the cursor-to-test mapping, which is the whole point
(check-equal! "cursor in a test body" (list "settles_when_tail_in_band" 8) (test-at-line lines 10))
(check-equal! "cursor on the declaration" (list "settles_when_tail_in_band" 8) (test-at-line lines 8))
(check-equal! "cursor on the attribute" (list "settles_when_tail_in_band" 8) (test-at-line lines 7))
(check-equal! "comment between attribute and declaration"
              (list "reads_the_port" 15)
              (test-at-line lines 16))
(check-false! "cursor in an untested helper" (test-at-line lines 4))
(check-false! "cursor above every declaration" (test-at-line lines 1))
(check-false! "empty buffer" (test-at-line '() 0))
(check-equal! "cursor past the end clamps"
              (list "reads_the_port" 15)
              (test-at-line lines 400))

;; declaration-name-at: what the failure message reports
(check-equal! "names an untested helper" "helper" (declaration-name-at lines 4))
(check-false! "nothing above the cursor" (declaration-name-at lines 1))

;; module-prefix: the path a file contributes, as libtest spells it
(check-equal! "nested library module" '("analysis" "signal") (module-prefix "src/analysis/signal.rs"))
(check-equal! "directory module" '("analysis") (module-prefix "src/analysis/mod.rs"))
(check-equal! "crate root contributes nothing" '() (module-prefix "src/lib.rs"))
(check-equal! "binary root contributes nothing" '() (module-prefix "src/main.rs"))
(check-equal! "integration test is its own root" '() (module-prefix "tests/skeleton.rs"))

;; enclosing-modules: indentation decides what encloses what
(check-equal! "single module" '("tests") (enclosing-modules lines 8))
(check-equal! "nested modules, outermost first"
              '("outer" "inner")
              (enclosing-modules (source-lines (string-append
                                                "mod outer {\n"
                                                "    mod inner {\n"
                                                "        #[test]\n"
                                                "        fn deep() {\n"
                                                "        }\n"
                                                "    }\n"
                                                "    #[test]\n"
                                                "    fn shallow() {\n"
                                                "    }\n"
                                                "}\n"))
                                 3))
(check-equal! "a sibling module does not enclose"
              '("outer")
              (enclosing-modules (source-lines (string-append
                                                "mod outer {\n"
                                                "    mod inner {\n"
                                                "        fn deep() {\n"
                                                "        }\n"
                                                "    }\n"
                                                "    #[test]\n"
                                                "    fn shallow() {\n"
                                                "    }\n"
                                                "}\n"))
                                 6))
(check-equal! "a bodyless mod declaration encloses nothing"
              '()
              (enclosing-modules (source-lines (string-append
                                                "mod other;\n"
                                                "#[test]\n"
                                                "fn flat() {\n"
                                                "}\n"))
                                 2))
(check-equal! "tab indentation still nests"
              '("tests")
              (enclosing-modules (source-lines (string-append
                                                "#[cfg(test)]\n"
                                                "mod tests {\n"
                                                "\t#[test]\n"
                                                "\tfn tabbed() {\n"
                                                "\t}\n"
                                                "}\n"))
                                 3))

;; qualified-test-name: exactly what `<binary> --list` prints, so --exact
;; selects one test
(check-equal! "library unit test path"
              "analysis::signal::tests::settles_when_tail_in_band"
              (qualified-test-name "src/analysis/signal.rs" lines (test-at-line lines 10)))
(check-equal! "integration test path omits the file"
              "tests::settles_when_tail_in_band"
              (qualified-test-name "tests/skeleton.rs" lines (test-at-line lines 10)))

;; breakpoint-line: anchoring on the declaration resolves into the harness
;; closure, so the body's first line is what gets used
(check-equal! "body line is one past the declaration, one-based" 10 (breakpoint-line 8))

;; target-arguments: which cargo target holds the file
(check-equal! "unit test in the library" '("--lib") (target-arguments "src/analysis/signal.rs"))
(check-equal! "integration test file" '("--test" "skeleton") (target-arguments "tests/skeleton.rs"))
(check-equal! "integration test directory" '("--test" "skeleton") (target-arguments "tests/skeleton/main.rs"))
(check-equal! "benchmark" '("--bench" "throughput") (target-arguments "benches/throughput.rs"))
(check-equal! "examples select nothing" '() (target-arguments "examples/divider.rs"))
(check-equal! "bare file selects nothing" '() (target-arguments "build.rs"))

;; build-arguments: the target selector is appended to a fixed prefix, and
;; json output is what names the binary
(check-equal! "library build invocation"
              '("test" "--no-run" "--message-format=json" "--lib")
              (build-arguments "src/lib.rs"))
(check-equal! "unrecognised location still builds"
              '("test" "--no-run" "--message-format=json")
              (build-arguments "build.rs"))

;; run-arguments: the filter goes past `--` to the test binary, pinned to
;; one test
(check-equal! "run one library test"
              '("test" "--lib" "--" "analysis::signal::tests::settles" "--exact" "--include-ignored")
              (run-arguments "src/analysis/signal.rs" "analysis::signal::tests::settles"))
(check-equal! "run one integration test"
              '("test" "--test" "skeleton" "--" "divider_op" "--exact" "--include-ignored")
              (run-arguments "tests/skeleton.rs" "divider_op"))

;; path helpers
(check-equal! "parent of a nested file" "/home/g/crate/src" (parent-directory "/home/g/crate/src/lib.rs"))
(check-equal! "parent of a root file" "" (parent-directory "lib.rs"))
(check-equal! "base name of a nested file" "signal.rs" (base-name "/w/crate/src/analysis/signal.rs"))
(check-equal! "base name of a bare file" "lib.rs" (base-name "lib.rs"))
(check-equal! "join keeps one separator" "/tmp/Cargo.toml" (join-path "/tmp" "Cargo.toml"))
(check-equal! "join at the filesystem root" "/Cargo.toml" (join-path "/" "Cargo.toml"))
(check-equal! "path relative to a root" "src/lib.rs" (path-within "/w/crate" "/w/crate/src/lib.rs"))
(check-equal! "path outside the root is unchanged" "/other/lib.rs" (path-within "/w/crate" "/other/lib.rs"))

;; crate-root: filesystem access is injected
(define (manifest-at . roots)
  (lambda (candidate)
    (not (empty? (filter (lambda (root) (equal? candidate root)) roots)))))

(check-equal! "nearest manifest wins"
              "/w/crate"
              (crate-root "/w/crate/src/analysis/signal.rs"
                          (manifest-at "/w/Cargo.toml" "/w/crate/Cargo.toml")))
(check-equal! "workspace manifest when the member has none"
              "/w"
              (crate-root "/w/crate/src/lib.rs" (manifest-at "/w/Cargo.toml")))
(check-false! "no manifest anywhere"
              (crate-root "/w/crate/src/lib.rs" (manifest-at)))

;; executable-from-cargo-output: shaped like real `cargo test --no-run
;; --message-format=json` output, where the non-test build of the same
;; crate also appears and must not be picked
(define cargo-output
  (string-append
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"lib\"],\"name\":\"kitest\"},"
   "\"profile\":{\"test\":false},\"executable\":null}\n"
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"lib\"],\"name\":\"kitest\"},"
   "\"profile\":{\"test\":true},\"executable\":\"/w/target/debug/deps/kitest-54a5895930f6071f\"}\n"
   ;; A crate with a bin target also yields a non-test executable, after
   ;; the test artifact, so picking the last executable is not enough.
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"kitest-cli\"},"
   "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/kitest-cli\"}\n"
   "{\"reason\":\"build-finished\",\"success\":true}\n"))

(check-equal! "test artifact is selected"
              "/w/target/debug/deps/kitest-54a5895930f6071f"
              (executable-from-cargo-output cargo-output))
(check-false! "no artifact in the output"
              (executable-from-cargo-output "{\"reason\":\"build-finished\",\"success\":true}\n"))
(check-false! "compiler warnings on stdout do not derail parsing"
              (executable-from-cargo-output "warning: unused variable\nnot json at all\n"))


;; diagnosis: what the first-run check reports
(check-equal! "all checks passing reads as a count"
              "2 checks passed"
              (diagnosis (list (check "cargo" #t "install cargo")
                               (check "template" #t "add the template"))))
(check-equal! "failures carry their remedy"
              "template: add the template"
              (diagnosis (list (check "cargo" #t "install cargo")
                               (check "template" #f "add the template"))))
(check-equal! "several failures are joined"
              "cargo: install cargo; template: add the template"
              (diagnosis (list (check "cargo" #f "install cargo")
                               (check "template" #f "add the template"))))
(check-true! "ok when nothing failed"
             (diagnosis-ok? (list (check "cargo" #t "x"))))
(check-false! "not ok when something failed"
              (diagnosis-ok? (list (check "cargo" #f "x"))))

;; languages.toml inspection, shaped like the generated file
(define languages-toml
  (string-append
   "[[language]]\n"
   "name = \"rust\"\n"
   "\n"
   "[language-server.rust-analyzer]\n"
   "command = \"rust-analyzer\"\n"
   "\n"
   "[language.debugger]\n"
   "command = \"lldb-dap-rust\"\n"
   "name = \"lldb-dap\"\n"
   "transport = \"stdio\"\n"
   "\n"
   "[[language.debugger.templates]]\n"
   "name = \"cargo test at line\"\n"))

(check-true! "template is found by name"
             (template-present? languages-toml "cargo test at line"))
(check-false! "a template that is absent is reported absent"
              (template-present? languages-toml "cargo test at cursor"))
(check-equal! "adapter command comes from the debugger table, not a language server"
              "lldb-dap-rust"
              (debugger-command languages-toml))
(check-false! "no debugger table means no adapter"
              (debugger-command "[[language]]\nname = \"rust\"\n"))

(finish!)
