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

;; test-outcome: the summary line libtest prints, shaped like real cargo
;; output with the blank lines it actually emits
(define one-target-output
  (string-append
   "running 2 tests\n"
   "test analysis::signal::tests::settles_when_tail_in_band ... ok\n"
   "test analysis::frequency::tests::verify_basic_equality ... ok\n"
   "\n"
   "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n"
   "\n"))

;; Two test targets ran, the first passed and the second failed, so the
;; last summary is the one that decides.
(define two-target-output
  (string-append
   "running 1 test\n"
   "test analysis::signal::tests::settles_when_tail_in_band ... ok\n"
   "\n"
   "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n"
   "\n"
   "running 1 test\n"
   "test divider::divides_by_two ... FAILED\n"
   "\n"
   "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s\n"
   "\n"))

(check-equal! "the only summary is returned"
              "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"
              (test-outcome one-target-output))
(check-equal! "the last summary wins when several targets ran"
              "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"
              (test-outcome two-target-output))
(check-false! "empty output has no summary" (test-outcome ""))
(check-false! "output without a summary" (test-outcome "warning: unused variable\nrunning 0 tests\n"))
(check-equal! "leading and trailing whitespace is removed"
              "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out"
              (test-outcome "    test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out   \n"))
(check-equal! "internal spacing is kept"
              "test result: ok.  2 passed;  0 failed"
              (test-outcome "test result: ok.  2 passed;  0 failed\n"))
(check-equal! "a summary on the final line without a newline still counts"
              "test result: ok. 1 passed; 0 failed"
              (test-outcome "running 1 test\ntest result: ok. 1 passed; 0 failed"))
(check-false! "a mention of the summary mid-line is not a summary"
              (test-outcome "note: the test result: ok. line is missing\n"))

;; outcome-failed?: the wording decides, never the counts
(check-false! "an absent summary is not a failure" (outcome-failed? #f))
(check-true! "a summary saying FAILED is a failure"
             (outcome-failed? "test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"))
(check-false! "a summary saying ok is not a failure"
              (outcome-failed? "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"))
(check-false! "zero passed while saying ok is not a failure"
              (outcome-failed? "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out; finished in 0.00s"))
(check-true! "zero failed while saying FAILED is still a failure"
             (outcome-failed? "test result: FAILED. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"))
;; Only an explicit failure counts as one, so neither word means no failure.
(check-false! "a summary with neither word is not a failure"
              (outcome-failed? "test result: interrupted. 1 passed"))
;; Chosen reading: FAILED outranks ok when a summary somehow carries both.
(check-true! "FAILED outranks ok in the same summary"
             (outcome-failed? "test result: FAILED. 1 passed; 1 failed; ok so far"))

;; panic-location: where to put the breakpoint after a failure, taken from
;; the panic libtest prints with its assertion on the following line
(define panic-output
  (string-append
   "running 1 test\n"
   "thread 'analysis::signal::tests::rejects_ringing_tail' panicked at crates/kitest/src/analysis/signal.rs:74:9:\n"
   "assertion failed: !s.settles_to(1.0, Tolerance::abs(0.05), 2.0)\n"
   "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n"
   "test analysis::signal::tests::rejects_ringing_tail ... FAILED\n"
   "\n"
   "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s\n"))

;; The harness unwinding panics again afterwards, so a later location must
;; not displace the one that failed the test.
(define two-panic-output
  (string-append
   "thread 'tests::first' panicked at src/analysis/signal.rs:74:9:\n"
   "assertion failed: settled\n"
   "thread 'tests::first' panicked at library/core/src/panicking.rs:221:5:\n"
   "panic in a destructor during cleanup\n"))

(check-equal! "the panic file and one-based line, column discarded"
              (list "crates/kitest/src/analysis/signal.rs" 74)
              (panic-location panic-output))
(check-equal! "the first panic wins"
              (list "src/analysis/signal.rs" 74)
              (panic-location two-panic-output))
(check-equal! "an absolute path is returned verbatim"
              (list "/w/crate/src/lib.rs" 12)
              (panic-location "thread 'main' panicked at /w/crate/src/lib.rs:12:5:\ncalled `Option::unwrap()` on a `None` value\n"))
(check-false! "empty output has no panic" (panic-location ""))
(check-false! "a passing run has no panic"
              (panic-location "test result: ok. 1 passed; 0 failed\n"))
(check-false! "a panic without a column is not a location"
              (panic-location "thread 'main' panicked at src/lib.rs:12:\n"))
(check-false! "a panic without a line is not a location"
              (panic-location "thread 'main' panicked at src/lib.rs\n"))
(check-false! "a non-numeric line is not a location"
              (panic-location "thread 'main' panicked at src/lib.rs:here:9:\n"))

;; test-names-from-list: the names `--list` prints, which is what --exact
;; has to match
(define list-output
  (string-append
   "analysis::signal::tests::settles_when_tail_in_band: test\n"
   "analysis::frequency::tests::verify_basic_equality: test\n"
   "\n"
   "2 tests, 0 benchmarks\n"))

(define mixed-list-output
  (string-append
   "analysis::signal::tests::settles_when_tail_in_band: test\n"
   "analysis::signal::benches::throughput: benchmark\n"
   "analysis::frequency::tests::verify_basic_equality: test\n"
   "\n"
   "2 tests, 1 benchmark\n"))

(check-equal! "names in the order printed, suffix removed"
              '("analysis::signal::tests::settles_when_tail_in_band"
                "analysis::frequency::tests::verify_basic_equality")
              (test-names-from-list list-output))
(check-equal! "benchmarks are excluded"
              '("analysis::signal::tests::settles_when_tail_in_band"
                "analysis::frequency::tests::verify_basic_equality")
              (test-names-from-list mixed-list-output))
(check-equal! "empty output lists nothing" '() (test-names-from-list ""))
(check-equal! "output with no test lines lists nothing"
              '()
              (test-names-from-list "\n0 tests, 0 benchmarks\n"))
(check-equal! "an unrecognised suffix is ignored"
              '("tests::kept")
              (test-names-from-list "tests::dropped: tests\ntests::kept: test\ntests::also_dropped\n"))
(check-equal! "neither sorted nor deduplicated"
              '("tests::zeta" "tests::alpha" "tests::zeta")
              (test-names-from-list "tests::zeta: test\ntests::alpha: test\ntests::zeta: test\n"))
;; Chosen reading: the suffix alone decides, so a name with spaces is kept.
(check-equal! "a name containing spaces is still a name"
              '("an integration case")
              (test-names-from-list "an integration case: test\n"))

;; breakpoints->text: the on-disk form of the breakpoint list
(check-equal! "the empty list writes nothing" "" (breakpoints->text '()))
(check-equal! "one entry is terminated by a newline"
              "src/analysis/signal.rs:74\n"
              (breakpoints->text (list (list "src/analysis/signal.rs" 74))))
(check-equal! "entries keep the order given, unsorted and undeduplicated"
              "src/zeta.rs:9\nsrc/alpha.rs:1\nsrc/zeta.rs:9\n"
              (breakpoints->text (list (list "src/zeta.rs" 9)
                                       (list "src/alpha.rs" 1)
                                       (list "src/zeta.rs" 9))))
;; Chosen reading: the line number is rendered as written, not rounded.
(check-equal! "a non-integer line number is rendered as written"
              "src/lib.rs:12.5\n"
              (breakpoints->text (list (list "src/lib.rs" 12.5))))

;; text->breakpoints: reading that form back, tolerating a corrupt file
(check-equal! "one entry parses with an integer line"
              (list (list "src/analysis/signal.rs" 74))
              (text->breakpoints "src/analysis/signal.rs:74\n"))
(check-equal! "nothing to parse" '() (text->breakpoints ""))
(check-equal! "blank lines are skipped"
              (list (list "src/a.rs" 1) (list "src/b.rs" 2))
              (text->breakpoints "\nsrc/a.rs:1\n\nsrc/b.rs:2\n\n"))
(check-equal! "a corrupt line is skipped, the rest still parse"
              (list (list "src/a.rs" 1) (list "src/b.rs" 2))
              (text->breakpoints "src/a.rs:1\nsrc/broken.rs:nowhere\nno-colon-at-all\nsrc/b.rs:2\n"))
(check-equal! "splitting happens at the last colon"
              (list (list "src/generated:v2/lib.rs" 300))
              (text->breakpoints "src/generated:v2/lib.rs:300\n"))

;; The round trip is the property that matters, so assert it rather than a
;; hand-written expectation.
(define breakpoints
  (list (list "crates/kitest/src/analysis/signal.rs" 74)
        (list "src/lib.rs" 1)
        (list "src/generated:v2/lib.rs" 300)))

(check-equal! "writing then reading returns the same pairs"
              breakpoints
              (text->breakpoints (breakpoints->text breakpoints)))
(check-equal! "the empty list round trips"
              '()
              (text->breakpoints (breakpoints->text '())))

;; dirty-buffer-warning: what the user is told after an automatic write
(check-equal! "the buffer name is reported unchanged"
              "saved src/analysis/signal.rs before building"
              (dirty-buffer-warning "src/analysis/signal.rs"))
(check-equal! "a name with spaces is not quoted or altered"
              "saved my crate/src/lib.rs before building"
              (dirty-buffer-warning "my crate/src/lib.rs"))

(finish!)
