;; helix-test-debug: Invoking cargo and reading what it printed. See
;; docs/specs/cargo-invocation.md and docs/specs/cargo-output.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require-builtin steel/json)
(require "names.scm")
(require "../text.scm")

(provide build-arguments
         executable-from-cargo-output
         outcome-failed?
         panic-location
         run-arguments
         target-arguments
         test-outcome)

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
  (append (list "test" "--color=always")
          (target-arguments relative-path)
          (list "--" filter)
          *filter-flags*
          (list "--color=always")))

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

;; Trimmed text of the last test summary cargo printed, or #f. Several
;; targets print several summaries and the last is the one that counts.
(define (test-outcome output)
  (let loop ([lines (source-lines output)] [outcome #f])
    (cond [(empty? lines) outcome]
          [(starts-with? (trim (car lines)) "test result:") (loop (cdr lines) (trim (car lines)))]
          [else (loop (cdr lines) outcome)])))

;; Whether a summary reports failure. The wording decides, not the counts,
;; and only an explicit failure counts as one.
(define (outcome-failed? outcome)
  (if (string? outcome) (string-contains? outcome "FAILED") #f))

(define *panic-marker* " panicked at ")

;; (file line-number) from a panic line, or #f when it is not one.
(define (panic-line-location line)
  (let ([tail (text-after line *panic-marker*)])
    (if (not tail)
        #f
        (let* ([trimmed (drop-trailing-colon (trim tail))]
               [fields (split-many trimmed ":")])
          (if (not (equal? (length fields) 3))
              #f
              (let ([number (string->number (list-ref fields 1))]
                    [column (string->number (list-ref fields 2))])
                (if (and (integer? number) (integer? column))
                    (list (car fields) number)
                    #f)))))))

;; Where a failing test panicked, as (file line-number), or #f. The first
;; panic is the one that failed the test; later ones are the harness
;; unwinding.
(define (panic-location output)
  (let loop ([lines (source-lines output)])
    (if (empty? lines)
        #f
        (let ([found (panic-line-location (car lines))])
          (if found found (loop (cdr lines)))))))
