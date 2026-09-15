;; helix-test-debug: Finding the test under the cursor. See docs/specs/cursor-to-test.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "../text.scm")

(provide breakpoint-line
         declaration-name-at
         function-name
         test-at-line
         test-attribute?
         test-declaration-line
         test-name)

;; Tokens that may precede `fn` in a declaration. An extern ABI string is
;; handled separately because it is not a fixed spelling.
(define *function-modifiers*
  '("pub" "pub(crate)" "pub(super)" "pub(self)" "async" "const" "unsafe" "extern" "default"))

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

;; One-based line of the first statement in the body. A breakpoint on the
;; declaration itself resolves into the harness closure that wraps the test
;; rather than the test body.
(define (breakpoint-line declaration)
  (+ declaration 2))
