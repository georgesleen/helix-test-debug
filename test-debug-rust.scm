;; helix-test-debug: rust half. Locates the test under the cursor and
;; derives the cargo invocation and breakpoint that debug it.
;;
;; Copyright (C) 2026 George Sleen
;;
;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Lesser General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
;; General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.
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
         breakpoint-line
         target-arguments
         build-arguments
         parent-directory
         base-name
         join-path
         path-within
         crate-root
         executable-from-cargo-output)

;; Tokens that may precede `fn` in a declaration. An extern ABI string is
;; handled separately because it is not a fixed spelling.
(define *function-modifiers*
  '("pub" "pub(crate)" "pub(super)" "pub(self)" "async" "const" "unsafe" "extern" "default"))

(define (member? item items)
  (not (empty? (filter (lambda (candidate) (equal? candidate item)) items))))

(define (source-lines text)
  (split-many text "\n"))

;; Identifier up to the first `(` or `<`, so `foo()` and `foo<T>(` both
;; yield foo.
(define (identifier-prefix token)
  (let loop ([chars (string->list token)] [kept '()])
    (cond [(empty? chars) (list->string (reverse kept))]
          [(char=? (car chars) #\() (list->string (reverse kept))]
          [(char=? (car chars) #\<) (list->string (reverse kept))]
          [else (loop (cdr chars) (cons (car chars) kept))])))

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
