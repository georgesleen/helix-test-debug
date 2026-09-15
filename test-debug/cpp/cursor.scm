;; helix-test-debug: finding the C or C++ test under the cursor. See
;; docs/specs/cpp-cursor-to-test.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "../text.scm")

(provide test-macros
         macro-invocation
         macro-invocation-macro
         macro-invocation-shape
         macro-invocation-arguments
         candidate-name
         cpp-test-at-line
         cpp-breakpoint-line)

;; Test macros and the shape of their arguments. The single point of
;; extension: a codebase wrapping TEST in its own macro adds a pair here.
(define (test-macros)
  '(("TEST" suite-name)
    ("TEST_F" suite-name)
    ("TEST_P" suite-name)
    ("TYPED_TEST" suite-name)
    ("TYPED_TEST_P" suite-name)
    ("BOOST_AUTO_TEST_CASE" suite-name)
    ("BOOST_FIXTURE_TEST_CASE" suite-name)
    ("TEST_CASE" string-name)
    ("SCENARIO" string-name)))

(define (macro-shape macro macros)
  (let ([found (filter (lambda (entry) (equal? (car entry) macro)) macros)])
    (if (empty? found) #f (car (cdr (car found))))))

;; Text between the first parenthesis and the matching one, or to the end of
;; the line when it does not close there.
(define (argument-text line)
  (let ([opening (text-after line "(")])
    (if (not opening)
        #f
        (let loop ([chars (string->list opening)] [depth 0] [kept '()])
          (cond [(empty? chars) (list->string (reverse kept))]
                [(and (char=? (car chars) #\)) (equal? depth 0)) (list->string (reverse kept))]
                [else
                 (loop (cdr chars)
                       (cond [(char=? (car chars) #\() (+ depth 1)]
                             [(char=? (car chars) #\)) (- depth 1)]
                             [else depth])
                       (cons (car chars) kept))])))))

;; The macro name a line opens with, or #f. Anything before it, including a
;; comment marker or an assignment, means this is not an invocation.
(define (leading-macro line)
  (let ([text (trim line)])
    (trim (identifier-prefix-until text #\())))

;; The test macro invoked on this line as (macro shape arguments), or #f.
(define (macro-invocation line macros)
  (let* ([macro (leading-macro line)]
         [shape (if (equal? macro "") #f (macro-shape macro macros))])
    (if (not shape)
        #f
        (let ([arguments (argument-text line)])
          (if arguments (list macro shape arguments) #f)))))

(define (macro-invocation-macro invocation) (list-ref invocation 0))
(define (macro-invocation-shape invocation) (list-ref invocation 1))
(define (macro-invocation-arguments invocation) (list-ref invocation 2))

;; Contents of the first string literal in the text, or #f. An escape is
;; recognised so a quoted quote does not end the literal, and kept as
;; written so the name matches the source.
(define (string-literal-contents text)
  (let ([opening (text-after text "\"")])
    (if (not opening)
        #f
        (let loop ([chars (string->list opening)] [kept '()])
          (cond [(empty? chars) #f]
                [(char=? (car chars) #\") (list->string (reverse kept))]
                [(and (char=? (car chars) #\\) (not (empty? (cdr chars))))
                 (loop (cdr (cdr chars)) (cons (car (cdr chars)) (cons (car chars) kept)))]
                [else (loop (cdr chars) (cons (car chars) kept))])))))

;; The candidate test name for an invocation, or #f when its arguments do
;; not fit the shape. A shape we have mis-tabled yields #f rather than a
;; guess, because debugging the wrong test is worse than detecting none.
(define (candidate-name invocation)
  (let ([shape (macro-invocation-shape invocation)]
        [arguments (macro-invocation-arguments invocation)])
    (if (equal? shape 'string-name)
        (string-literal-contents arguments)
        (let ([fields (map trim (split-many arguments ","))])
          (cond [(equal? (length fields) 1)
                 (if (equal? (car fields) "") #f (car fields))]
                [(equal? (length fields) 2)
                 (string-append (car fields) "." (car (cdr fields)))]
                [else #f])))))

;; A line that closes a test body at column zero ends the test above it.
(define (body-close-line? line)
  (starts-with? line "}"))

;; The test enclosing a zero-based line as (candidate declaration-line), or
;; #f. The macro table is supplied by the caller, which is what makes the
;; dispatch in the editor half the only place that knows the language.
(define (cpp-test-at-line lines line macros)
  (if (empty? lines)
      #f
      (let loop ([index (clamp-line lines line)])
        (cond [(< index 0) #f]
              [(macro-invocation (list-ref lines index) macros)
               (let ([candidate (candidate-name (macro-invocation (list-ref lines index) macros))])
                 (if candidate (list candidate index) #f))]
              [(and (< index line) (body-close-line? (list-ref lines index))) #f]
              [else (loop (- index 1))]))))

;; One-based line number of the first statement in the body. The brace may
;; sit on the macro line or on its own, so this scans forward for it and
;; then past blanks and comments.
(define (comment-line? text)
  (or (starts-with? text "//") (starts-with? text "/*") (starts-with? text "*")))

(define (cpp-breakpoint-line declaration lines)
  (let loop ([index declaration] [seen-brace #f])
    (cond [(> index (- (length lines) 1)) #f]
          [else
           (let ([text (trim (list-ref lines index))])
             (cond [(not seen-brace)
                    (loop (+ index 1) (string-contains? text "{"))]
                   [(equal? text "") (loop (+ index 1) #t)]
                   [(comment-line? text) (loop (+ index 1) #t)]
                   [else (+ index 1)]))])))
