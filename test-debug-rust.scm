;; helix-test-debug: rust half. Locates the test under the cursor and
;; derives the cargo invocation and breakpoint that debug it.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later
;;
;; Every function here is pure: filesystem access arrives as an injected
;; predicate. That keeps this half runnable under a bare steel interpreter,
;; which is where its tests run.

(require-builtin steel/strings)
(require-builtin steel/json)

(provide source-lines
         function-name
         test-attribute?
         test-at-line
         test-name
         test-declaration-line
         declaration-name-at
         module-prefix
         enclosing-modules
         qualified-test-name
         breakpoint-line
         target-arguments
         build-arguments
         run-arguments
         parent-directory
         base-name
         join-path
         path-within
         crate-root
         executable-from-cargo-output
         check
         diagnosis
         diagnosis-ok?
         template-present?
         debugger-command)

;; Tokens that may precede `fn` in a declaration. An extern ABI string is
;; handled separately because it is not a fixed spelling.
(define *function-modifiers*
  '("pub" "pub(crate)" "pub(super)" "pub(self)" "async" "const" "unsafe" "extern" "default"))

;; Tokens that may precede `mod`.
(define *module-modifiers* '("pub" "pub(crate)" "pub(super)" "pub(self)"))

(define (member? item items)
  (not (empty? (filter (lambda (candidate) (equal? candidate item)) items))))

(define (source-lines text)
  (split-many text "\n"))

;; Identifier up to the first occurrence of `stop`.
(define (identifier-prefix-until token stop)
  (let loop ([chars (string->list token)] [kept '()])
    (cond [(empty? chars) (list->string (reverse kept))]
          [(char=? (car chars) stop) (list->string (reverse kept))]
          [else (loop (cdr chars) (cons (car chars) kept))])))

;; Identifier up to the first `(` or `<`, so `foo()` and `foo<T>(` both
;; yield foo.
(define (identifier-prefix token)
  (identifier-prefix-until (identifier-prefix-until token #\() #\<))

;; Name of the function declared on this line, or #f when the line does not
;; declare one.
(define (function-name line)
  (let loop ([tokens (split-whitespace line)])
    (cond [(empty? tokens) #f]
          [(equal? (car tokens) "fn")
           (if (empty? (cdr tokens))
               #f
               (let ([name (identifier-prefix (car (cdr tokens)))])
                 (if (equal? name "") #f name)))]
          [(starts-with? (car tokens) "\"") (loop (cdr tokens))]
          [(member? (car tokens) *function-modifiers*) (loop (cdr tokens))]
          [else #f])))

;; An attribute marking a test: plain #[test] and the async variants such
;; as #[tokio::test].
(define (test-attribute? line)
  (let ([text (trim line)])
    (and (starts-with? text "#[") (string-contains? text "test"))))

;; Lines that may sit between a test attribute and the declaration it
;; applies to.
(define (attribute-gap-line? line)
  (let ([text (trim line)])
    (or (equal? text "") (starts-with? text "//") (starts-with? text "#["))))

(define (clamp-line lines line)
  (let ([last-index (- (length lines) 1)])
    (cond [(> line last-index) last-index]
          [(< line 0) 0]
          [else line])))

;; Nearest declaration below a line, so long as only attributes, comments
;; and blanks intervene. Covers a cursor parked on the #[test] line.
(define (declaration-line-below lines line)
  (let loop ([index line])
    (cond [(> index (- (length lines) 1)) #f]
          [(function-name (list-ref lines index)) index]
          [(attribute-gap-line? (list-ref lines index)) (loop (+ index 1))]
          [else #f])))

(define (declaration-line-above lines line)
  (let loop ([index line])
    (cond [(< index 0) #f]
          [(function-name (list-ref lines index)) index]
          [else (loop (- index 1))])))

;; Declaration governing a line: the one it sits inside, or the one its
;; attribute block introduces.
(define (declaration-line-at lines line)
  (let ([start (clamp-line lines line)])
    (let ([below (declaration-line-below lines start)])
      (if below below (declaration-line-above lines start)))))

(define (test-marked? lines declaration)
  (let loop ([index (- declaration 1)])
    (cond [(< index 0) #f]
          [(test-attribute? (list-ref lines index)) #t]
          [(attribute-gap-line? (list-ref lines index)) (loop (- index 1))]
          [else #f])))

;; The test enclosing a zero-based line as (name declaration-line), or #f
;; when the line is not inside a test.
(define (test-at-line lines line)
  (if (empty? lines)
      #f
      (let ([declaration (declaration-line-at lines line)])
        (if (and declaration (test-marked? lines declaration))
            (list (function-name (list-ref lines declaration)) declaration)
            #f))))

(define (test-name test)
  (car test))

(define (test-declaration-line test)
  (car (cdr test)))

;; Name of the nearest declaration governing a line, whether or not it is a
;; test. Used to say what was found when no test was.
(define (declaration-name-at lines line)
  (if (empty? lines)
      #f
      (let ([declaration (declaration-line-at lines line)])
        (if declaration (function-name (list-ref lines declaration)) #f))))

;; Depth of a line's indentation. Tabs count as one each, which is enough
;; because only the ordering of depths matters, never the column.
(define (indentation line)
  (let loop ([chars (string->list line)] [count 0])
    (cond [(empty? chars) count]
          [(char=? (car chars) #\space) (loop (cdr chars) (+ count 1))]
          [(char=? (car chars) #\tab) (loop (cdr chars) (+ count 1))]
          [else count])))

;; Module this line declares, or #f. `mod foo;` is a declaration without a
;; body and never encloses anything, so it is excluded.
(define (module-name line)
  (let loop ([tokens (split-whitespace line)])
    (cond [(empty? tokens) #f]
          [(equal? (car tokens) "mod")
           (if (empty? (cdr tokens))
               #f
               (let ([name (identifier-prefix-until (car (cdr tokens)) #\{)])
                 (if (or (equal? name "") (ends-with? name ";")) #f name)))]
          [(member? (car tokens) *module-modifiers*) (loop (cdr tokens))]
          [else #f])))

;; Modules enclosing a declaration, outermost first. A module encloses it
;; when it is declared above and indented less, which holds for any
;; conventionally formatted source.
(define (enclosing-modules lines declaration)
  (let loop ([index (- declaration 1)]
             [depth (indentation (list-ref lines declaration))]
             [found '()])
    (if (< index 0)
        found
        (let* ([line (list-ref lines index)]
               [name (module-name line)]
               [depth-here (indentation line)])
          (if (and name (< depth-here depth))
              (loop (- index 1) depth-here (cons name found))
              (loop (- index 1) depth found))))))

;; Module path a source file contributes, given its path relative to the
;; crate root. Files under src/ are modules of the library; a test or
;; benchmark file is its own crate root and contributes nothing.
(define (module-prefix relative-path)
  (let ([segments (split-many relative-path "/")])
    (if (or (empty? segments) (not (equal? (car segments) "src")))
        '()
        (let ([inner (cdr segments)])
          (if (empty? inner)
              '()
              (let* ([leaf (strip-rust-extension (last inner))]
                     [branches (take inner (- (length inner) 1))])
                (if (member? leaf '("lib" "main" "mod"))
                    branches
                    (append branches (list leaf)))))))))

;; The path libtest matches with --exact: the file's module path, the
;; modules declared around the test, then the test itself.
(define (qualified-test-name relative-path lines test)
  (string-join (append (module-prefix relative-path)
                       (enclosing-modules lines (test-declaration-line test))
                       (list (test-name test)))
               "::"))

;; One-based line of the first statement in the body. A breakpoint on the
;; declaration itself resolves into the harness closure that wraps the test
;; rather than the test body.
(define (breakpoint-line declaration)
  (+ declaration 2))

(define (strip-rust-extension name)
  (if (ends-with? name ".rs")
      (substring name 0 (- (string-length name) 3))
      name))

;; tests/foo.rs and tests/foo/main.rs are both target foo.
(define (target-name segments)
  (if (equal? (length segments) 2)
      (strip-rust-extension (list-ref segments 1))
      (list-ref segments 1)))

;; Cargo arguments selecting the target holding a source file, given its
;; path relative to the crate root. An unrecognised location selects
;; nothing, which leaves cargo to build every test target.
(define (target-arguments relative-path)
  (let ([segments (split-many relative-path "/")])
    (cond [(empty? segments) '()]
          [(equal? (car segments) "src") '("--lib")]
          [(< (length segments) 2) '()]
          [(equal? (car segments) "tests") (list "--test" (target-name segments))]
          [(equal? (car segments) "benches") (list "--bench" (target-name segments))]
          [else '()])))

;; Full cargo invocation that builds, but does not run, the test target
;; holding a source file. JSON output is what names the built binary.
(define (build-arguments relative-path)
  (append (list "test" "--no-run" "--message-format=json")
          (target-arguments relative-path)))

;; Flags that pin a run to exactly one test. --exact makes the filter a
;; whole-path match instead of a substring, and --include-ignored costs
;; nothing for a test that is not ignored while making an #[ignore]d one
;; runnable, so neither flag has to be conditional.
(define *filter-flags* '("--exact" "--include-ignored"))

;; Full cargo invocation that builds and runs exactly one test.
(define (run-arguments relative-path filter)
  (append (list "test")
          (target-arguments relative-path)
          (list "--" filter)
          *filter-flags*))

(define (parent-directory path)
  (let ([segments (split-many path "/")])
    (if (< (length segments) 2)
        ""
        (string-join (take segments (- (length segments) 1)) "/"))))

(define (base-name path)
  (let ([segments (split-many path "/")])
    (if (empty? segments) path (last segments))))

(define (join-path dir name)
  (if (equal? dir "/")
      (string-append dir name)
      (string-append dir "/" name)))

;; Path with a directory prefix removed. A path outside the directory is
;; returned unchanged.
(define (path-within root path)
  (let ([prefix (string-append root "/")])
    (if (starts-with? path prefix)
        (substring path (string-length prefix) (string-length path))
        path)))

;; Nearest ancestor directory of a file that holds a Cargo.toml. exists? is
;; injected, so this is pure.
(define (crate-root path exists?)
  (let loop ([dir (parent-directory path)])
    (cond [(equal? dir "") #f]
          [(exists? (join-path dir "Cargo.toml")) dir]
          [else (loop (parent-directory dir))])))

(define (parse-json-line line)
  (let ([text (trim line)])
    (if (starts-with? text "{")
        (call-with-exception-handler (lambda (failure) #f)
                                     (lambda () (string->jsexpr text)))
        #f)))

;; Executable path of a test-profile artifact message, or #f for every
;; other cargo message.
(define (test-executable line)
  (let ([message (parse-json-line line)])
    (if (not (hash? message))
        #f
        (let ([executable (hash-try-get message 'executable)]
              [profile (hash-try-get message 'profile)])
          (if (and (string? executable)
                   (hash? profile)
                   (equal? (hash-try-get profile 'test) #t))
              executable
              #f)))))

;; Path of the test binary cargo built, or #f when it reported none. Cargo
;; emits one JSON message per line and the artifact appears before the
;; final build summary.
(define (executable-from-cargo-output text)
  (let loop ([lines (source-lines text)] [found #f])
    (if (empty? lines)
        found
        (let ([candidate (test-executable (car lines))])
          (loop (cdr lines) (if candidate candidate found))))))

;; One diagnosis line: a label, whether it passed, and what to do when it
;; did not.
(define (check label ok remedy)
  (list label ok remedy))

(define (check-label entry) (list-ref entry 0))
(define (check-ok entry) (list-ref entry 1))
(define (check-remedy entry) (list-ref entry 2))

;; Diagnosis as one statusline-sized string: the failures with their
;; remedies, or a summary when everything passed.
(define (diagnosis checks)
  (let ([failed (filter (lambda (entry) (not (check-ok entry))) checks)])
    (if (empty? failed)
        (string-append (number->string (length checks)) " checks passed")
        (string-join (map (lambda (entry)
                            (string-append (check-label entry) ": " (check-remedy entry)))
                          failed)
                     "; "))))

(define (diagnosis-ok? checks)
  (empty? (filter (lambda (entry) (not (check-ok entry))) checks)))

;; Whether a languages.toml names this debugger template.
(define (template-present? text name)
  (string-contains? text (string-append "\"" name "\"")))

;; Adapter command a languages.toml configures, or #f. The first command
;; after the debugger table is the adapter; the language servers above it
;; have their own.
(define (debugger-command text)
  (let loop ([lines (source-lines text)] [in-debugger #f])
    (cond [(empty? lines) #f]
          [else
           (let ([line (trim (car lines))])
             (cond [(starts-with? line "[language.debugger]") (loop (cdr lines) #t)]
                   [(and in-debugger (starts-with? line "command = "))
                    (identifier-prefix-until (substring line 11 (string-length line)) #\")]
                   [(and in-debugger (starts-with? line "[")) #f]
                   [else (loop (cdr lines) in-debugger)]))])))
