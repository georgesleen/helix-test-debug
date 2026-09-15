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

;; toggle-breakpoint: what the editor does to the set it just read
(check-equal! "a new breakpoint is appended, keeping the order set"
              (list (list "src/a.rs" 1) (list "src/b.rs" 2))
              (toggle-breakpoint (list (list "src/a.rs" 1)) "src/b.rs" 2))
(check-equal! "toggling the same pair again removes it"
              (list (list "src/a.rs" 1))
              (toggle-breakpoint (list (list "src/a.rs" 1) (list "src/b.rs" 2)) "src/b.rs" 2))
(check-equal! "removal leaves every other entry in place"
              (list (list "src/a.rs" 1) (list "src/c.rs" 3))
              (toggle-breakpoint (list (list "src/a.rs" 1) (list "src/b.rs" 2) (list "src/c.rs" 3))
                                 "src/b.rs"
                                 2))
(check-equal! "the same line in another file is a different breakpoint"
              (list (list "src/a.rs" 1) (list "src/b.rs" 1))
              (toggle-breakpoint (list (list "src/a.rs" 1)) "src/b.rs" 1))
(check-equal! "another line in the same file is a different breakpoint"
              (list (list "src/a.rs" 1) (list "src/a.rs" 2))
              (toggle-breakpoint (list (list "src/a.rs" 1)) "src/a.rs" 2))
(check-equal! "a duplicate left by a hand edit clears in one toggle"
              (list (list "src/b.rs" 2))
              (toggle-breakpoint (list (list "src/a.rs" 1) (list "src/b.rs" 2) (list "src/a.rs" 1))
                                 "src/a.rs"
                                 1))
(check-equal! "the first breakpoint in a workspace starts the list"
              (list (list "src/a.rs" 1))
              (toggle-breakpoint '() "src/a.rs" 1))

;; breakpoint-budget: the limit a store declares, which the cog cannot know
(check-false! "no header means no limit" (breakpoint-budget "src/a.rs:1\nsrc/b.rs:2\n"))
(check-false! "an empty store declares nothing" (breakpoint-budget ""))
(check-equal! "a header on its own line is the budget" 4 (breakpoint-budget "budget: 4\n"))
(check-equal! "no space after the colon" 4 (breakpoint-budget "budget:4\n"))
(check-equal! "spacing around the colon and the number is tolerated"
              4
              (breakpoint-budget "budget  :   4   \n"))
(check-equal! "leading whitespace on the line is tolerated"
              4
              (breakpoint-budget "    budget: 4\n"))
(check-false! "a word is not a budget" (breakpoint-budget "budget: four\n"))
(check-false! "a fraction is not a budget" (breakpoint-budget "budget: 4.5\n"))
(check-false! "a negative budget is a typo, not a limit" (breakpoint-budget "budget: -1\n"))
(check-false! "a missing value is a typo, not a limit of zero"
              (breakpoint-budget "budget:\n"))
;; Zero is a limit, so a caller has to test for #f and not for falsiness.
(check-equal! "zero is a valid budget" 0 (breakpoint-budget "budget: 0\n"))
(check-true! "a budget of zero is distinguishable from no budget"
             (not (equal? #f (breakpoint-budget "budget: 0\n"))))
(check-equal! "only the first declaration counts"
              2
              (breakpoint-budget "budget: 2\nsrc/a.rs:1\nbudget: 5\n"))
(check-equal! "a hand-edited file may declare it anywhere"
              3
              (breakpoint-budget "src/a.rs:1\nbudget: 3\nsrc/b.rs:2\n"))
(check-false! "a malformed first declaration is still the declaration"
              (breakpoint-budget "budget: x\nbudget: 4\nsrc/a.rs:1\n"))

;; text->breakpoints: the header is not a breakpoint
(check-equal! "a budget line is skipped and the rest still parse"
              (list (list "src/a.rs" 1) (list "src/b.rs" 2))
              (text->breakpoints "budget: 4\nsrc/a.rs:1\nsrc/b.rs:2\n"))
(check-equal! "a budget line between breakpoints is skipped too"
              (list (list "src/a.rs" 1) (list "src/b.rs" 2))
              (text->breakpoints "src/a.rs:1\nbudget: 4\nsrc/b.rs:2\n"))

;; breakpoints->text with a budget: a host store never grows a header
(check-equal! "no budget writes what the one-argument form wrote"
              "src/zeta.rs:9\nsrc/alpha.rs:1\n"
              (breakpoints->text (list (list "src/zeta.rs" 9) (list "src/alpha.rs" 1)) #f))
(check-equal! "no budget and no breakpoints writes nothing"
              ""
              (breakpoints->text '() #f))
(check-equal! "a budget is written first, then the breakpoints"
              "budget: 4\nsrc/zeta.rs:9\nsrc/alpha.rs:1\n"
              (breakpoints->text (list (list "src/zeta.rs" 9) (list "src/alpha.rs" 1)) 4))
(check-equal! "a budget of zero is still written"
              "budget: 0\n"
              (breakpoints->text '() 0))

;; Both halves of the round trip, since the store is read back by two
;; different functions.
(check-equal! "writing with a budget still returns the same pairs"
              breakpoints
              (text->breakpoints (breakpoints->text breakpoints 4)))
(check-equal! "the budget survives the round trip"
              4
              (breakpoint-budget (breakpoints->text breakpoints 4)))
(check-equal! "a budget of zero survives the round trip"
              0
              (breakpoint-budget (breakpoints->text breakpoints 0)))
(check-equal! "the pairs survive a budget of zero"
              breakpoints
              (text->breakpoints (breakpoints->text breakpoints 0)))
(check-false! "no budget round trips as no budget"
              (breakpoint-budget (breakpoints->text breakpoints #f)))
(check-equal! "the empty list round trips with a budget"
              '()
              (text->breakpoints (breakpoints->text '() 4)))

;; within-budget: which breakpoints the editor gets to place
(check-equal! "no budget places all of them"
              breakpoints
              (within-budget breakpoints #f))
(check-equal! "the first of them, in the order they were set"
              (list (list "src/a.rs" 1) (list "src/b.rs" 2))
              (within-budget (list (list "src/a.rs" 1) (list "src/b.rs" 2) (list "src/c.rs" 3)) 2))
(check-equal! "a budget of zero places nothing"
              '()
              (within-budget (list (list "src/a.rs" 1)) 0))
(check-equal! "fewer than the budget is not padded"
              (list (list "src/a.rs" 1))
              (within-budget (list (list "src/a.rs" 1)) 4))
(check-equal! "nothing to place fits any budget" '() (within-budget '() 4))

;; budget-report: a report that always fires is noise
(check-false! "no budget, no report" (budget-report 7 7 #f))
(check-false! "nothing dropped, no report" (budget-report 4 4 4))
(check-equal! "the report names the count and the file that set the limit"
              "placed 4 of 7, the budget in .helix/test-debug-breakpoints is 4"
              (budget-report 4 7 4))
(check-equal! "a budget of zero drops everything and says so"
              "placed 0 of 3, the budget in .helix/test-debug-breakpoints is 0"
              (budget-report 0 3 0))

;; dirty-buffer-warning: what the user is told after an automatic write
(check-equal! "the buffer name is reported unchanged"
              "saved src/analysis/signal.rs before building"
              (dirty-buffer-warning "src/analysis/signal.rs"))
(check-equal! "a name with spaces is not quoted or altered"
              "saved my crate/src/lib.rs before building"
              (dirty-buffer-warning "my crate/src/lib.rs"))

;; compiled-source?: the paths under the crate root cargo compiles, which
;; is what the picker is allowed to read
(check-true! "library root" (compiled-source? "src/lib.rs"))
(check-true! "nested library module" (compiled-source? "src/analysis/signal.rs"))
(check-true! "integration test file" (compiled-source? "tests/skeleton.rs"))
(check-true! "integration test directory" (compiled-source? "tests/skeleton/main.rs"))
(check-true! "benchmark" (compiled-source? "benches/throughput.rs"))
(check-false! "generated sources under target are not compiled"
              (compiled-source? "target/debug/build/kitest-1a2b3c/out/generated.rs"))
(check-false! "examples are not a compiled first segment"
              (compiled-source? "examples/divider.rs"))
(check-false! "a segment that merely starts with src" (compiled-source? "srcs/lib.rs"))
(check-false! "src below another directory" (compiled-source? "crates/kitest/src/lib.rs"))
(check-false! "a non-rust file beside the sources" (compiled-source? "src/notes.txt"))
(check-false! "a file with no extension at all" (compiled-source? "src/Makefile"))
(check-false! "the manifest beside the crate root" (compiled-source? "Cargo.toml"))
(check-false! "a bare rust file has no module path" (compiled-source? "build.rs"))
(check-false! "the first segment is case-sensitive" (compiled-source? "Src/lib.rs"))
(check-false! "an upper-case test directory is a different directory"
              (compiled-source? "TESTS/skeleton.rs"))
;; Chosen reading: "comparison is exact" governs the extension as well, so
;; a name a case-sensitive filesystem spells differently is not rust.
(check-false! "the extension is case-sensitive" (compiled-source? "src/lib.RS"))

;; tests-in-file: every test in one file, in declaration order. Entries are
;; read through their accessors, so the checks do not depend on the shape
;; an entry happens to have.
(define (entry-fields entry)
  (list (discovered-name entry) (discovered-path entry) (discovered-line entry)))

(define (entry-names entries)
  (map discovered-name entries))

(define signal-tests (tests-in-file "src/analysis/signal.rs" lines))

(check-equal! "the helper is not a test" 2 (length signal-tests))
(check-equal! "the qualified name, the file, and the one-based body line"
              (list "analysis::signal::tests::settles_when_tail_in_band"
                    "src/analysis/signal.rs"
                    10)
              (entry-fields (list-ref signal-tests 0)))
(check-equal! "an async test with a comment before its declaration still counts"
              (list "analysis::signal::tests::reads_the_port" "src/analysis/signal.rs" 17)
              (entry-fields (list-ref signal-tests 1)))
(check-equal! "an integration file contributes no module prefix"
              '("tests::settles_when_tail_in_band" "tests::reads_the_port")
              (entry-names (tests-in-file "tests/skeleton.rs" lines)))
(check-equal! "another attribute path ending in test counts"
              '("cases::runs_on_the_runtime")
              (entry-names
               (tests-in-file "src/cases.rs"
                              (source-lines (string-append
                                             "#[async_std::test]\n"
                                             "async fn runs_on_the_runtime() {\n"
                                             "}\n")))))

;; Two modules declaring the same test name, the second with an attribute,
;; a blank line and a comment between `#[test]` and its declaration, and an
;; untested function below it.
(define two-module-source
  (string-append
   "mod alpha {\n"                                  ; 0
   "    #[test]\n"                                  ; 1
   "    fn shared() {\n"                            ; 2
   "        assert!(true);\n"                       ; 3
   "    }\n"                                        ; 4
   "}\n"                                            ; 5
   "\n"                                             ; 6
   "mod beta {\n"                                   ; 7
   "    #[test]\n"                                  ; 8
   "    #[ignore]\n"                                ; 9
   "\n"                                             ; 10
   "    // the same name, a different module\n"     ; 11
   "    fn shared() {\n"                            ; 12
   "        assert!(true);\n"                       ; 13
   "    }\n"                                        ; 14
   "\n"                                             ; 15
   "    fn untested() {\n"                          ; 16
   "    }\n"                                        ; 17
   "}\n"))                                          ; 18

(check-equal! "same name in two modules, neither dropped"
              (list (list "alpha::shared" "src/lib.rs" 4)
                    (list "beta::shared" "src/lib.rs" 14))
              (map entry-fields (tests-in-file "src/lib.rs" (source-lines two-module-source))))
(check-equal! "no lines at all" '() (tests-in-file "src/lib.rs" '()))
(check-equal! "a file whose functions are all untested"
              '()
              (tests-in-file "src/lib.rs" (source-lines "pub fn run() {\n}\n")))

;; A test at the top of an integration file, whose name carries no `::`
(define flat-source
  (string-append
   "#[test]\n"                                      ; 0
   "fn divides_by_two() {\n"                        ; 1
   "    assert!(true);\n"                           ; 2
   "}\n"))                                          ; 3

(define flat-tests (tests-in-file "tests/skeleton.rs" (source-lines flat-source)))

(check-equal! "a test with no enclosing module is named by itself"
              (list (list "divides_by_two" "tests/skeleton.rs" 3))
              (map entry-fields flat-tests))

(define mixed-case-tests
  (tests-in-file "src/lib.rs"
                 (source-lines (string-append
                                "mod Cases {\n"
                                "    #[test]\n"
                                "    fn Settles() {\n"
                                "    }\n"
                                "}\n"))))

;; matching-tests-by-name: the picker's filter, a subsequence match that
;; leaves the order alone
(check-equal! "the empty query selects every entry"
              '("analysis::signal::tests::settles_when_tail_in_band"
                "analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "" signal-tests)))
(check-equal! "characters in order, not necessarily adjacent"
              '("analysis::signal::tests::settles_when_tail_in_band"
                "analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "anig" signal-tests)))
(check-equal! "a subsequence no name contains as a substring"
              '("analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "sport" signal-tests)))
(check-equal! "a query that selects one of the two"
              '("analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "port" signal-tests)))
(check-equal! "an upper-case query against a lower-case name"
              '("analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "PORT" signal-tests)))
(check-equal! "a lower-case query against an upper-case name"
              '("Cases::Settles")
              (entry-names (matching-tests-by-name "cases" mixed-case-tests)))
(check-equal! "a pasted module path selects its tests"
              '("analysis::signal::tests::settles_when_tail_in_band"
                "analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "signal::tests" signal-tests)))
(check-equal! "colons are matched literally, not skipped"
              '()
              (entry-names (matching-tests-by-name "::" flat-tests)))
(check-equal! "a query no name contains selects nothing"
              '()
              (entry-names (matching-tests-by-name "zzz" signal-tests)))
;; The fixture declares its tests out of alphabetical order, so a filter
;; that sorted would show up here.
(check-equal! "order is the order of the entries"
              '("analysis::signal::tests::settles_when_tail_in_band"
                "analysis::signal::tests::reads_the_port")
              (entry-names (matching-tests-by-name "s" signal-tests)))

;; discovery-summary: the line above the list, worded so it reads without
;; being parsed
(check-equal! "an empty crate has nothing to filter"
              "no tests found in this crate"
              (discovery-summary "" '() 0))
(check-equal! "zero total outranks a query"
              "no tests found in this crate"
              (discovery-summary "signal" '() 0))
(check-equal! "no query is a plain count" "2 tests" (discovery-summary "" signal-tests 2))
;; Deliberately not special-cased, so the line never has to be parsed.
(check-equal! "one test is still tests" "1 tests" (discovery-summary "" flat-tests 1))
(check-equal! "a filtering query names what is on screen"
              "1 of 12 tests matching port"
              (discovery-summary "port" (matching-tests-by-name "port" signal-tests) 12))
;; Chosen reading: the plain count is for the empty query, so a query that
;; happens to select everything is still filtering.
(check-equal! "a query that filters nothing out still says which query"
              "2 of 2 tests matching anig"
              (discovery-summary "anig" (matching-tests-by-name "anig" signal-tests) 2))
(check-equal! "a query that selects none of a non-empty crate"
              "nothing matches zzz"
              (discovery-summary "zzz" '() 12))

;; binary-target-arguments: which binary target holds the file, for a
;; cursor that is not in a test
(check-equal! "a file under src/bin names its binary"
              '("--bin" "tool")
              (binary-target-arguments "src/bin/tool.rs"))
(check-equal! "the directory form of the same target"
              '("--bin" "tool")
              (binary-target-arguments "src/bin/tool/main.rs"))
(check-equal! "a module beside that main belongs to the same binary"
              '("--bin" "tool")
              (binary-target-arguments "src/bin/tool/helper.rs"))
;; The package's own binary is named in Cargo.toml, not by its path.
(check-equal! "the crate's own binary root selects nothing"
              '()
              (binary-target-arguments "src/main.rs"))
(check-equal! "the library root selects nothing"
              '()
              (binary-target-arguments "src/lib.rs"))
(check-equal! "library code selects nothing, cargo picks"
              '()
              (binary-target-arguments "src/analysis/signal.rs"))
(check-equal! "an integration test file has no binary"
              '()
              (binary-target-arguments "tests/skeleton.rs"))
(check-equal! "an integration test directory has no binary"
              '()
              (binary-target-arguments "tests/skeleton/main.rs"))
(check-equal! "a benchmark has no binary"
              '()
              (binary-target-arguments "benches/throughput.rs"))
(check-equal! "a path with no directory segment selects nothing"
              '()
              (binary-target-arguments "build.rs"))

;; binary-build-arguments: the fixed prefix builds without running, and
;; json is what names the executable
(check-equal! "build one binary"
              '("build" "--message-format=json" "--bin" "tool")
              (binary-build-arguments "src/bin/tool.rs"))
(check-equal! "build the directory form of the same target"
              '("build" "--message-format=json" "--bin" "tool")
              (binary-build-arguments "src/bin/tool/main.rs"))
(check-equal! "an unselective location builds every binary"
              '("build" "--message-format=json")
              (binary-build-arguments "src/main.rs"))
(check-equal! "library code builds every binary"
              '("build" "--message-format=json")
              (binary-build-arguments "src/analysis/signal.rs"))
;; `--no-run` has no meaning for `cargo build`, so it must not be carried
;; over from the test invocation.
(check-true! "no --no-run in a build invocation"
             (empty? (filter (lambda (argument) (equal? argument "--no-run"))
                             (binary-build-arguments "src/bin/tool.rs"))))

;; binary-run-arguments: the program is run for its own output, so there
;; is nothing to filter and nothing to parse
(check-equal! "run one binary"
              '("run" "--bin" "tool")
              (binary-run-arguments "src/bin/tool.rs"))
(check-equal! "run the directory form of the same target"
              '("run" "--bin" "tool")
              (binary-run-arguments "src/bin/tool/main.rs"))
(check-equal! "an unselective location runs the package's binary"
              '("run")
              (binary-run-arguments "src/main.rs"))
(check-equal! "library code runs the package's binary"
              '("run")
              (binary-run-arguments "src/lib.rs"))
(check-true! "no -- because there is no filter to pass"
             (empty? (filter (lambda (argument) (equal? argument "--"))
                             (binary-run-arguments "src/bin/tool.rs"))))
(check-true! "no message format, so the program's own output shows"
             (empty? (filter (lambda (argument) (equal? argument "--message-format=json"))
                             (binary-run-arguments "src/bin/tool.rs"))))

;; bin-executable-from-cargo-output: shaped like real `cargo build
;; --message-format=json` output, where the build script and the test
;; build of the same crate also carry executables and must not be picked
(define binary-cargo-output
  (string-append
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"custom-build\"],\"name\":\"build-script-build\"},"
   "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/build/kitest-1a2b3c/build-script-build\"}\n"
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"lib\"],\"name\":\"kitest\"},"
   "\"profile\":{\"test\":false},\"executable\":null}\n"
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"lib\"],\"name\":\"kitest\"},"
   "\"profile\":{\"test\":true},\"executable\":\"/w/target/debug/deps/kitest-54a5895930f6071f\"}\n"
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"kitest-cli\"},"
   "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/kitest-cli\"}\n"
   "{\"reason\":\"build-finished\",\"success\":true}\n"))

;; Two binaries in one package, which is what a cursor in shared library
;; code produces. The documented cost is that the first one reported wins,
;; the opposite of the test-target function's rule.
(define two-binary-cargo-output
  (string-append
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"tool\"},"
   "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/tool\"}\n"
   "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"helper\"},"
   "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/helper\"}\n"
   "{\"reason\":\"build-finished\",\"success\":true}\n"))

(check-equal! "the binary artifact is selected"
              "/w/target/debug/kitest-cli"
              (bin-executable-from-cargo-output binary-cargo-output))
(check-equal! "the first binary wins, not the last"
              "/w/target/debug/tool"
              (bin-executable-from-cargo-output two-binary-cargo-output))
(check-false! "a build script is not a binary, executable and all"
              (bin-executable-from-cargo-output
               (string-append
                "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"custom-build\"],\"name\":\"build-script-build\"},"
                "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/build/kitest-1a2b3c/build-script-build\"}\n"
                "{\"reason\":\"build-finished\",\"success\":true}\n")))
(check-false! "a test artifact is not a binary"
              (bin-executable-from-cargo-output
               (string-append
                "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"lib\"],\"name\":\"kitest\"},"
                "\"profile\":{\"test\":true},\"executable\":\"/w/target/debug/deps/kitest-54a5895930f6071f\"}\n")))
;; The test build of a bin target has kind `bin` too, so the profile is
;; what keeps this and `executable-from-cargo-output` apart.
(check-false! "the test build of a bin target is not a binary"
              (bin-executable-from-cargo-output
               (string-append
                "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"tool\"},"
                "\"profile\":{\"test\":true},\"executable\":\"/w/target/debug/deps/tool-9f1c2d3e4b5a6071\"}\n")))
(check-false! "an artifact without an executable does not qualify"
              (bin-executable-from-cargo-output
               (string-append
                "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"tool\"},"
                "\"profile\":{\"test\":false},\"executable\":null}\n")))
(check-false! "no artifact in the output"
              (bin-executable-from-cargo-output "{\"reason\":\"build-finished\",\"success\":true}\n"))
(check-false! "a build failure names no executable"
              (bin-executable-from-cargo-output
               (string-append
                "{\"reason\":\"compiler-message\",\"message\":{\"level\":\"error\"}}\n"
                "{\"reason\":\"build-finished\",\"success\":false}\n")))
(check-false! "nothing was printed at all" (bin-executable-from-cargo-output ""))
(check-false! "compiler warnings on stdout do not derail parsing"
              (bin-executable-from-cargo-output "warning: unused variable\nnot json at all\n"))
;; A json line that parses to something other than an object is skipped on
;; the same principle as a line that does not parse at all.
(check-equal! "non-json and non-object lines are skipped, the artifact is still found"
              "/w/target/debug/tool"
              (bin-executable-from-cargo-output
               (string-append
                "warning: unused variable `x`\n"
                "[1, 2, 3]\n"
                "42\n"
                "\"a bare string\"\n"
                "null\n"
                "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"bin\"],\"name\":\"tool\"},"
                "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/tool\"}\n")))
;; The spec says the kind list contains `bin`, not that it is only `bin`.
(check-equal! "a kind list containing bin among others qualifies"
              "/w/target/debug/tool"
              (bin-executable-from-cargo-output
               (string-append
                "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"cdylib\",\"bin\"],\"name\":\"tool\"},"
                "\"profile\":{\"test\":false},\"executable\":\"/w/target/debug/tool\"}\n")))

;; binary-label: what the status line calls the thing about to run
(check-equal! "a file under src/bin names its binary" "bin tool" (binary-label "src/bin/tool.rs"))
(check-equal! "the directory form is the same binary" "bin tool" (binary-label "src/bin/tool/main.rs"))
(check-equal! "the crate's own binary is unnamed here" "the binary" (binary-label "src/main.rs"))
(check-equal! "the library root is not a binary" "the binary" (binary-label "src/lib.rs"))
(check-equal! "library code is not a binary" "the binary" (binary-label "src/analysis/signal.rs"))
(check-equal! "an integration test selects no binary" "the binary" (binary-label "tests/skeleton.rs"))
(check-equal! "a bare file selects no binary" "the binary" (binary-label "build.rs"))

(finish!)
