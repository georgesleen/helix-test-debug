;; Tests for the C and C++ half. Runs under a bare steel interpreter.
;;
;; Copyright (C) 2026 George Sleen
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require "harness.scm")
(require "../test-debug-cpp.scm")

;; The shape tabled for a macro name, or #f when the name is absent.
(define (shape-of name)
  (let ((hit (filter (lambda (entry) (equal? (list-ref entry 0) name)) (test-macros))))
    (if (empty? hit) #f (list-ref (list-ref hit 0) 1))))

;; test-macros: the table is the single point of extension, so every
;; framework entry has to carry the right shape
(check-equal! "the table holds nine macros" 9 (length (test-macros)))
(check-equal! "googletest plain test" 'suite-name (shape-of "TEST"))
(check-equal! "googletest fixture test" 'suite-name (shape-of "TEST_F"))
(check-equal! "googletest parameterized test" 'suite-name (shape-of "TEST_P"))
(check-equal! "googletest typed test" 'suite-name (shape-of "TYPED_TEST"))
(check-equal! "googletest typed test pattern" 'suite-name (shape-of "TYPED_TEST_P"))
(check-equal! "boost automatic case" 'suite-name (shape-of "BOOST_AUTO_TEST_CASE"))
(check-equal! "boost fixture case" 'suite-name (shape-of "BOOST_FIXTURE_TEST_CASE"))
(check-equal! "catch2 case" 'string-name (shape-of "TEST_CASE"))
(check-equal! "catch2 scenario" 'string-name (shape-of "SCENARIO"))
(check-false! "a wrapper macro is not tabled" (shape-of "MY_OWN_TEST"))

(define macros (test-macros))

;; A codebase wrapping a framework macro extends the table rather than the code.
(define extended-macros (append macros (list (list "MY_OWN_TEST" 'suite-name))))

;; macro-invocation: what counts as an invocation
(check-equal! "a googletest invocation with the brace on the line"
              (list "TEST" 'suite-name "MathTest, Doubles")
              (macro-invocation "TEST(MathTest, Doubles) {" macros))
(check-equal! "an indented fixture invocation"
              (list "TEST_F" 'suite-name "MathFixture, Doubles")
              (macro-invocation "  TEST_F(MathFixture, Doubles) {" macros))
(check-equal! "a parameterized invocation"
              (list "TEST_P" 'suite-name "MathParams, Doubles")
              (macro-invocation "TEST_P(MathParams, Doubles) {" macros))
(check-equal! "a boost invocation takes one identifier"
              (list "BOOST_AUTO_TEST_CASE" 'suite-name "halves_a_value")
              (macro-invocation "BOOST_AUTO_TEST_CASE(halves_a_value) {" macros))
(check-equal! "a catch2 scenario invocation"
              (list "SCENARIO" 'string-name "\"a full turn\"")
              (macro-invocation "SCENARIO(\"a full turn\") {" macros))
(check-equal! "the argument text is raw and untrimmed"
              (list "TEST" 'suite-name " MathTest , Doubles ")
              (macro-invocation "TEST( MathTest , Doubles ) {" macros))
;; The outermost parentheses are the macro's own, so a call in a one line
;; body must not extend the argument text.
(check-equal! "a call after the invocation does not extend the arguments"
              (list "TEST" 'suite-name "MathTest, Doubles")
              (macro-invocation "TEST(MathTest, Doubles) { EXPECT_EQ(doubled(2.0), 4.0); }" macros))
(check-equal! "parentheses inside a string argument are kept"
              (list "TEST_CASE" 'string-name "\"doubles f(x)\", \"[math]\"")
              (macro-invocation "TEST_CASE(\"doubles f(x)\", \"[math]\") {" macros))
;; The longer tabled name has to win, or every fixture test reports as TEST.
(check-equal! "a longer macro name is not truncated to a shorter one"
              "TEST_F"
              (macro-invocation-macro (macro-invocation "TEST_F(MathFixture, Doubles) {" macros)))
(check-equal! "the shape comes from the table, not the line"
              'string-name
              (macro-invocation-shape (macro-invocation "TEST_CASE(\"doubles a value\") {" macros)))
(check-equal! "the argument text is read back whole"
              "MathTest, Doubles"
              (macro-invocation-arguments (macro-invocation "TEST(MathTest, Doubles) {" macros)))
(check-false! "a line comment mentioning a macro is not an invocation"
              (macro-invocation "  // TEST(MathTest, Doubles)" macros))
(check-false! "a block comment mentioning a macro is not an invocation"
              (macro-invocation "  /* TEST(MathTest, Doubles) */" macros))
(check-false! "a macro inside a string literal is not an invocation"
              (macro-invocation "  const char* name = \"TEST(MathTest, Doubles)\";" macros))
(check-false! "a macro passed as a call argument is not an invocation"
              (macro-invocation "  RUN_TEST(TEST(MathTest, Doubles));" macros))
(check-false! "a macro absent from the table is not an invocation"
              (macro-invocation "MY_OWN_TEST(WrapperSuite, Wrapped) {" macros))
(check-false! "a longer identifier starting with a tabled name is not an invocation"
              (macro-invocation "TESTING_UTILS(MathTest, Doubles) {" macros))
(check-false! "a tabled name extended by a suffix is not an invocation"
              (macro-invocation "TEST_CASE_HELPER(\"doubles a value\") {" macros))
(check-false! "a bare macro name with no parentheses is not an invocation"
              (macro-invocation "TEST" macros))
(check-false! "a macro name used as a value is not an invocation"
              (macro-invocation "  return TEST;" macros))
(check-false! "a blank line is not an invocation" (macro-invocation "" macros))
(check-false! "a whitespace line is not an invocation" (macro-invocation "    " macros))
(check-equal! "an extended table recognises a wrapper macro"
              (list "MY_OWN_TEST" 'suite-name "WrapperSuite, Wrapped")
              (macro-invocation "MY_OWN_TEST(WrapperSuite, Wrapped) {" extended-macros))
;; The caller supplies the continuation lines, so an invocation split over
;; several lines still has to be recognised on its first line.
(check-equal! "an unclosed invocation still matches"
              "TEST"
              (macro-invocation-macro (macro-invocation "TEST(MathTest," macros)))
;; Chosen reading: with no closing parenthesis the argument text runs to
;; the end of the line, verbatim.
(check-equal! "an unclosed invocation carries the text it has"
              (list "TEST" 'suite-name "MathTest,")
              (macro-invocation "TEST(MathTest," macros))
;; Chosen reading: the macro name is the first token, and C permits
;; whitespace before the argument list, so this is an invocation.
(check-equal! "whitespace before the argument list still invokes"
              (list "TEST" 'suite-name "MathTest, Doubles")
              (macro-invocation "TEST (MathTest, Doubles) {" macros))

;; candidate-name: rendering the arguments into the name ctest knows
(check-equal! "two identifiers render as suite and name"
              "MathTest.Doubles"
              (candidate-name (list "TEST" 'suite-name "MathTest, Doubles")))
(check-equal! "whitespace around each argument is trimmed"
              "MathTest.Doubles"
              (candidate-name (list "TEST" 'suite-name "  MathTest ,  Doubles  ")))
(check-equal! "one identifier renders bare"
              "halves_a_value"
              (candidate-name (list "BOOST_AUTO_TEST_CASE" 'suite-name "halves_a_value")))
(check-equal! "a typed test renders like any suite and name"
              "VectorTest.Sums"
              (candidate-name (list "TYPED_TEST" 'suite-name "VectorTest, Sums")))
;; Guessing here would put the debugger on the wrong test.
(check-false! "three identifiers yield no candidate"
              (candidate-name (list "TEST" 'suite-name "MathTest, Doubles, Extra")))
(check-equal! "a string literal renders as its contents"
              "doubles a value"
              (candidate-name (list "TEST_CASE" 'string-name "\"doubles a value\"")))
;; Catch2 tags follow the name, so the first literal is the name.
(check-equal! "the first string literal wins over a tag literal"
              "doubles a value"
              (candidate-name (list "TEST_CASE" 'string-name "\"doubles a value\", \"[math]\"")))
(check-equal! "escapes are left exactly as written"
              "escapes \\n stay"
              (candidate-name (list "TEST_CASE" 'string-name "\"escapes \\n stay\"")))
(check-equal! "an escaped quote does not end the literal"
              "a \\\"quoted\\\" value"
              (candidate-name (list "SCENARIO" 'string-name "\"a \\\"quoted\\\" value\"")))
(check-false! "an identifier is not a string literal"
              (candidate-name (list "TEST_CASE" 'string-name "doubles")))
;; Chosen reading: a present but empty literal has empty contents, which is
;; a name ctest can be asked about, rather than a shape mismatch.
(check-equal! "an empty string literal renders empty"
              ""
              (candidate-name (list "TEST_CASE" 'string-name "\"\"")))
;; Chosen reading: no arguments is not one argument, so there is nothing to
;; render and no candidate.
(check-false! "no arguments yield no candidate"
              (candidate-name (list "TEST" 'suite-name "")))
;; Chosen reading: the table decides, and it tables the boost fixture case
;; as suite-name, so its two arguments render mechanically even though the
;; second is a fixture type rather than a test name.
(check-equal! "a boost fixture case renders both arguments"
              "halves_a_value.MathFixture"
              (candidate-name (list "BOOST_FIXTURE_TEST_CASE" 'suite-name "halves_a_value, MathFixture")))

;; A translation unit shaped like the real thing: a helper in an anonymous
;; namespace, adjacent tests with the brace in both places, one test per
;; framework, and a wrapper macro the table does not know.
(define cpp-source
  (string-append
   "#include <gtest/gtest.h>\n"                          ; 0
   "\n"                                                  ; 1
   "namespace {\n"                                        ; 2
   "\n"                                                   ; 3
   "double doubled(double v) {\n"                         ; 4
   "  return v * 2.0;\n"                                  ; 5
   "}\n"                                                  ; 6
   "\n"                                                   ; 7
   "}  // namespace\n"                                    ; 8
   "\n"                                                   ; 9
   "TEST(MathTest, Doubles) {\n"                          ; 10
   "  EXPECT_EQ(doubled(2.0), 4.0);\n"                    ; 11
   "}\n"                                                  ; 12
   "\n"                                                   ; 13
   "TEST(MathTest, Halves)\n"                             ; 14
   "{\n"                                                  ; 15
   "  // the brace sits on its own line here\n"           ; 16
   "\n"                                                   ; 17
   "  EXPECT_EQ(halved(4.0), 2.0);\n"                     ; 18
   "}\n"                                                  ; 19
   "\n"                                                   ; 20
   "TEST_F(MathFixture, Doubles) {\n"                     ; 21
   "  EXPECT_EQ(doubled(value_), 4.0);\n"                 ; 22
   "}\n"                                                  ; 23
   "\n"                                                   ; 24
   "TEST_P(MathParams, Doubles) {\n"                      ; 25
   "  EXPECT_EQ(doubled(GetParam()), 4.0);\n"             ; 26
   "}\n"                                                  ; 27
   "\n"                                                   ; 28
   "TEST_CASE(\"doubles a value\", \"[math]\") {\n"       ; 29
   "  REQUIRE(doubled(2.0) == 4.0);\n"                    ; 30
   "}\n"                                                  ; 31
   "\n"                                                   ; 32
   "BOOST_AUTO_TEST_CASE(halves_a_value) {\n"             ; 33
   "  BOOST_CHECK_EQUAL(halved(4.0), 2.0);\n"             ; 34
   "}\n"                                                  ; 35
   "\n"                                                   ; 36
   "MY_OWN_TEST(WrapperSuite, Wrapped) {\n"               ; 37
   "  EXPECT_TRUE(true);\n"                               ; 38
   "}\n"))                                                ; 39

(define lines (source-lines cpp-source))

;; test-at-line: the cursor to test mapping, which is the whole point
(check-equal! "cursor in a googletest body"
              (list "MathTest.Doubles" 10)
              (cpp-test-at-line lines 11 macros))
(check-equal! "cursor on the invocation line counts as inside it"
              (list "MathTest.Doubles" 10)
              (cpp-test-at-line lines 10 macros))
(check-equal! "cursor in a body whose brace sits on its own line"
              (list "MathTest.Halves" 14)
              (cpp-test-at-line lines 18 macros))
(check-equal! "cursor on the lone brace belongs to the test above it"
              (list "MathTest.Halves" 14)
              (cpp-test-at-line lines 15 macros))
(check-equal! "cursor in a fixture test"
              (list "MathFixture.Doubles" 21)
              (cpp-test-at-line lines 22 macros))
(check-equal! "cursor in a parameterized test"
              (list "MathParams.Doubles" 25)
              (cpp-test-at-line lines 26 macros))
(check-equal! "cursor in a catch2 case names the string"
              (list "doubles a value" 29)
              (cpp-test-at-line lines 30 macros))
(check-equal! "cursor in a boost case names the single identifier"
              (list "halves_a_value" 33)
              (cpp-test-at-line lines 34 macros))
;; The closing brace at column zero is the wall, so the test above does not
;; leak into the gap after it.
(check-false! "cursor between two tests reports neither"
              (cpp-test-at-line lines 13 macros))
(check-false! "cursor in an untested helper reports nothing"
              (cpp-test-at-line lines 5 macros))
(check-false! "cursor above every invocation reports nothing"
              (cpp-test-at-line lines 0 macros))
(check-false! "cursor in a body whose macro is not tabled reports nothing"
              (cpp-test-at-line lines 38 macros))
(check-equal! "an extended table finds the wrapper macro's test"
              (list "WrapperSuite.Wrapped" 37)
              (cpp-test-at-line lines 38 extended-macros))
(check-false! "an empty buffer holds no test" (cpp-test-at-line '() 0 macros))

;; breakpoint-line: one based, and the brace may be anywhere
(check-equal! "the brace on the macro line puts the body one line down"
              12
              (cpp-breakpoint-line 10 lines))
(check-equal! "the brace on its own line, skipping a comment and a blank"
              19
              (cpp-breakpoint-line 14 lines))
(check-equal! "a catch2 body is found the same way"
              31
              (cpp-breakpoint-line 29 lines))

;; Everything between the brace and the first statement is skipped.
(define preamble-source
  (string-append
   "TEST(BodyTest, SkipsPreamble)\n"   ; 0
   "{\n"                               ; 1
   "\n"                                ; 2
   "  /* a block comment */\n"         ; 3
   "  // a line comment\n"             ; 4
   "  int value = 1;\n"                ; 5
   "}\n"))                             ; 6

(check-equal! "blank lines and both comment styles are skipped"
              6
              (cpp-breakpoint-line 0 (source-lines preamble-source)))

;; Chosen reading: the scan starts after the line holding the brace, so a
;; body written on the macro line has no line of its own.
(define inline-body-source
  (string-append
   "TEST(BodyTest, OneLine) { EXPECT_TRUE(ready()); }\n" ; 0
   "\n"                                                  ; 1
   "TEST(BodyTest, Following) {\n"                        ; 2
   "  EXPECT_TRUE(done());\n"                             ; 3
   "}\n"))                                                ; 4

(check-equal! "a one line body sends the scan past the macro line"
              3
              (cpp-breakpoint-line 0 (source-lines inline-body-source)))

;; Chosen reading: a declaration with no body has no first statement.
(check-false! "a declaration with no brace has no breakpoint line"
              (cpp-breakpoint-line 0 (source-lines "TEST(BodyTest, Declared);\n")))

;; ctest output shaped like the real thing: a built test with a filter
;; argument and a working directory, a parameterized pair, a prefixed
;; sibling that is not parameterized, and a test whose target is not built
;; yet so it has no command.
(define ctest-json
  (string-append
   "{\n"
   "  \"kind\" : \"ctestInfo\",\n"
   "  \"version\" : { \"major\" : 1, \"minor\" : 0 },\n"
   "  \"backtraceGraph\" : { \"commands\" : [ \"add_test\" ], \"files\" : [ \"CMakeLists.txt\" ], \"nodes\" : [ ] },\n"
   "  \"tests\" : [\n"
   "    {\n"
   "      \"name\" : \"MathTest.Doubles\",\n"
   "      \"command\" : [ \"/w/build/suite\", \"--gtest_filter=MathTest.Doubles\" ],\n"
   "      \"properties\" : [\n"
   "        { \"name\" : \"LABELS\", \"value\" : [ \"unit\" ] },\n"
   "        { \"name\" : \"WORKING_DIRECTORY\", \"value\" : \"/w/build\" }\n"
   "      ]\n"
   "    },\n"
   "    {\n"
   "      \"name\" : \"Params.Case/0\",\n"
   "      \"command\" : [ \"/w/build/suite\", \"--gtest_filter=Params.Case/0\" ],\n"
   "      \"properties\" : [ { \"name\" : \"WORKING_DIRECTORY\", \"value\" : \"/w/build\" } ]\n"
   "    },\n"
   "    {\n"
   "      \"name\" : \"Params.Case/1\",\n"
   "      \"command\" : [ \"/w/build/suite\", \"--gtest_filter=Params.Case/1\" ],\n"
   "      \"properties\" : [ { \"name\" : \"WORKING_DIRECTORY\", \"value\" : \"/w/build\" } ]\n"
   "    },\n"
   "    {\n"
   "      \"name\" : \"Params.Cases\",\n"
   "      \"command\" : [ \"/w/build/cases\" ],\n"
   "      \"properties\" : [ ]\n"
   "    },\n"
   "    {\n"
   "      \"name\" : \"doubles a value\",\n"
   "      \"properties\" : [ { \"name\" : \"WORKING_DIRECTORY\", \"value\" : \"/w/build\" } ]\n"
   "    }\n"
   "  ]\n"
   "}\n"))

;; ctest-tests: the tuples, in ctest's order
(check-equal! "every reported test becomes a tuple"
              (list (list "MathTest.Doubles" "/w/build/suite"
                          (list "--gtest_filter=MathTest.Doubles") "/w/build")
                    (list "Params.Case/0" "/w/build/suite"
                          (list "--gtest_filter=Params.Case/0") "/w/build")
                    (list "Params.Case/1" "/w/build/suite"
                          (list "--gtest_filter=Params.Case/1") "/w/build")
                    (list "Params.Cases" "/w/build/cases" '() #f)
                    (list "doubles a value" #f '() "/w/build"))
              (ctest-tests ctest-json))
(check-equal! "order is ctest's order, unsorted"
              '("Zeta.Test" "Alpha.Test" "Middle.Test")
              (map ctest-test-name
                   (ctest-tests (string-append
                                 "{ \"kind\" : \"ctestInfo\", \"tests\" : ["
                                 " { \"name\" : \"Zeta.Test\", \"command\" : [ \"/w/build/suite\" ] },"
                                 " { \"name\" : \"Alpha.Test\", \"command\" : [ \"/w/build/suite\" ] },"
                                 " { \"name\" : \"Middle.Test\", \"command\" : [ \"/w/build/suite\" ] } ] }"))))
(check-equal! "malformed json yields no tests" '() (ctest-tests "{ \"kind\" : \"ctestIn"))
(check-equal! "output that is not json at all yields no tests"
              '()
              (ctest-tests "CMake Error: could not read the cache\n"))
(check-equal! "empty output yields no tests" '() (ctest-tests ""))
(check-equal! "json with no tests key yields no tests"
              '()
              (ctest-tests "{ \"kind\" : \"ctestInfo\", \"version\" : { \"major\" : 1 } }"))
(check-equal! "an empty tests array yields no tests"
              '()
              (ctest-tests "{ \"kind\" : \"ctestInfo\", \"tests\" : [ ] }"))
;; Chosen reading: an empty command names no executable, so it reads the
;; same as an absent one.
(check-equal! "an empty command reads like an absent command"
              (list (list "MathTest.Doubles" #f '() #f))
              (ctest-tests (string-append
                            "{ \"kind\" : \"ctestInfo\", \"tests\" : ["
                            " { \"name\" : \"MathTest.Doubles\", \"command\" : [ ],"
                            "   \"properties\" : [ ] } ] }")))

(define tests (ctest-tests ctest-json))

;; accessors: the tuple read back field by field
(check-equal! "the name accessor" "MathTest.Doubles" (ctest-test-name (list-ref tests 0)))
(check-equal! "the executable accessor" "/w/build/suite" (ctest-test-executable (list-ref tests 0)))
(check-equal! "the arguments accessor"
              '("--gtest_filter=MathTest.Doubles")
              (ctest-test-arguments (list-ref tests 0)))
(check-equal! "the directory accessor" "/w/build" (ctest-test-directory (list-ref tests 0)))
(check-equal! "a name with spaces survives" "doubles a value" (ctest-test-name (list-ref tests 4)))
(check-false! "an unbuilt test has no executable" (ctest-test-executable (list-ref tests 4)))
(check-equal! "an unbuilt test has no arguments" '() (ctest-test-arguments (list-ref tests 4)))
(check-false! "a test without the property has no directory"
              (ctest-test-directory (list-ref tests 3)))
(check-equal! "a single element command has no arguments"
              '()
              (ctest-test-arguments (list-ref tests 3)))

;; matching-tests: which registered tests a candidate refers to
(check-equal! "a parameterized candidate expands to its instances, in order"
              (list (list-ref tests 1) (list-ref tests 2))
              (matching-tests "Params.Case" tests))
;; The slash is required, so a longer name sharing the prefix is not an
;; instance of it.
(check-false! "a prefixed sibling without a slash is not an instance"
              (not (empty? (filter (lambda (test) (equal? (ctest-test-name test) "Params.Cases"))
                                   (matching-tests "Params.Case" tests)))))
(check-equal! "an exact match is returned alone"
              (list (list-ref tests 0))
              (matching-tests "MathTest.Doubles" tests))
(check-equal! "a candidate naming a string test matches it"
              (list (list-ref tests 4))
              (matching-tests "doubles a value" tests))
;; Chosen reading: the exact rule looks at the whole name, so a candidate
;; that already carries an instance suffix matches exactly.
(check-equal! "a candidate that is itself an instance matches exactly"
              (list (list-ref tests 1))
              (matching-tests "Params.Case/0" tests))
(check-equal! "nothing matching yields the empty list"
              '()
              (matching-tests "Nowhere.Near" tests))
(check-equal! "a candidate of false yields the empty list" '() (matching-tests #f tests))
(check-equal! "no registered tests yields the empty list" '() (matching-tests "MathTest.Doubles" '()))

;; The exact name and its instances both registered, with the exact name
;; buried in the middle, so preference cannot come from position.
(define exact-and-instances
  (ctest-tests (string-append
                "{ \"kind\" : \"ctestInfo\", \"tests\" : ["
                " { \"name\" : \"Params.Case/0\", \"command\" : [ \"/w/build/suite\" ] },"
                " { \"name\" : \"Params.Case\", \"command\" : [ \"/w/build/suite\" ] },"
                " { \"name\" : \"Params.Case/1\", \"command\" : [ \"/w/build/suite\" ] } ] }")))

(check-equal! "the exact match wins over instances that share its prefix"
              '("Params.Case")
              (map ctest-test-name (matching-tests "Params.Case" exact-and-instances)))

;; build-directory and project-root: filesystem access is injected
(define (files-at . paths)
  (lambda (candidate)
    (not (empty? (filter (lambda (path) (equal? candidate path)) paths)))))

(check-equal! "build is preferred when several are configured"
              "/w/project/build"
              (build-directory "/w/project"
                               (files-at "/w/project/build/CMakeCache.txt"
                                         "/w/project/cmake-build-debug/CMakeCache.txt")))
;; A directory that exists but holds no cache is not configured, so the
;; later candidate wins.
(check-equal! "a configured directory beats a merely present one"
              "/w/project/cmake-build-debug"
              (build-directory "/w/project"
                               (files-at "/w/project/build"
                                         "/w/project/cmake-build-debug/CMakeCache.txt")))
(check-equal! "debug is tried before release"
              "/w/project/cmake-build-debug"
              (build-directory "/w/project"
                               (files-at "/w/project/cmake-build-debug/CMakeCache.txt"
                                         "/w/project/cmake-build-release/CMakeCache.txt")))
(check-equal! "release is found when it is the only one"
              "/w/project/cmake-build-release"
              (build-directory "/w/project"
                               (files-at "/w/project/cmake-build-release/CMakeCache.txt")))
(check-false! "no candidate configured yields nothing"
              (build-directory "/w/project" (files-at "/w/project/CMakeLists.txt")))
(check-false! "a cache outside the candidates is ignored"
              (build-directory "/w/project" (files-at "/w/project/out/CMakeCache.txt")))
(check-false! "nothing exists at all" (build-directory "/w/project" (files-at)))

(check-equal! "the nearest CMakeLists wins"
              "/w/project/src"
              (project-root "/w/project/src/math_test.cpp"
                            (files-at "/w/project/CMakeLists.txt"
                                      "/w/project/src/CMakeLists.txt")))
(check-equal! "the top level CMakeLists when the subdirectory has none"
              "/w/project"
              (project-root "/w/project/src/math_test.cpp"
                            (files-at "/w/project/CMakeLists.txt")))
(check-equal! "the search climbs past several directories"
              "/w/project/src"
              (project-root "/w/project/src/math/vector_test.cpp"
                            (files-at "/w/project/CMakeLists.txt"
                                      "/w/project/src/CMakeLists.txt")))
(check-false! "no CMakeLists anywhere above"
              (project-root "/w/project/src/math_test.cpp" (files-at)))

(finish!)
