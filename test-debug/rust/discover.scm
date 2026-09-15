;; helix-test-debug: Every test in a crate, read from its source rather
;; than from a build. See docs/specs/crate-discovery.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "cursor.scm")
(require "names.scm")
(require "../text.scm")

(provide compiled-source?
         discovered-line
         discovered-name
         discovered-path
         discovery-summary
         matching-tests-by-name
         tests-in-file)

;; Directories under the crate root cargo compiles. Everything else,
;; target/ above all, is skipped rather than parsed.
(define *compiled-roots* '("src" "tests" "benches"))

(define (compiled-source? relative-path)
  (let ([segments (split-many relative-path "/")])
    (and (ends-with? relative-path ".rs")
         (> (length segments) 1)
         (member? (car segments) *compiled-roots*))))

;; An entry pairs the name libtest matches with the place to stop.
(define (discovered-name entry) (list-ref entry 0))
(define (discovered-path entry) (list-ref entry 1))
(define (discovered-line entry) (list-ref entry 2))

;; The test declared on this line, or #f. Asking test-at-line at the
;; declaration keeps one definition of what a test is: a declaration it
;; reports from elsewhere belongs to another line and is left to it.
(define (test-declared-at lines index)
  (if (function-name (list-ref lines index))
      (let ([test (test-at-line lines index)])
        (if (and test (equal? (test-declaration-line test) index)) test #f))
      #f))

(define (tests-in-file relative-path lines)
  (let loop ([index 0]
             [found '()])
    (if (>= index (length lines))
        (reverse found)
        (let ([test (test-declared-at lines index)])
          (loop (+ index 1)
                (if test
                    (cons (list (qualified-test-name relative-path lines test)
                                relative-path
                                (breakpoint-line (test-declaration-line test)))
                          found)
                    found))))))

;; Whether the characters of query appear in name in order. Subsequence
;; matching is what makes a module path worth typing: `anig` reaches
;; analysis::signal without the separators.
(define (subsequence? query name)
  (let loop ([wanted (string->list (string-downcase query))]
             [seen (string->list (string-downcase name))])
    (cond [(empty? wanted) #t]
          [(empty? seen) #f]
          [(equal? (car wanted) (car seen)) (loop (cdr wanted) (cdr seen))]
          [else (loop wanted (cdr seen))])))

(define (matching-tests-by-name query entries)
  (if (equal? query "")
      entries
      (filter (lambda (entry) (subsequence? query (discovered-name entry))) entries)))

(define (discovery-summary query entries total)
  (cond
    [(equal? total 0) "no tests found in this crate"]
    [(equal? query "") (string-append (number->string total) " tests")]
    [(empty? entries) (string-append "nothing matches " query)]
    [else (string-append (number->string (length entries))
                         " of "
                         (number->string total)
                         " tests matching "
                         query)]))
