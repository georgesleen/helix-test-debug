;; helix-test-debug: finding the Unity test under the cursor. See
;; docs/specs/unity-cursor-to-test.md.
;;
;; Unity has no test attribute: a test is an ordinary function, and what
;; makes it a test is a RUN_TEST call in the runner. So unlike the
;; GoogleTest path, the cursor can only name a candidate and the authority
;; lives in another file.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "../text.scm")
(require (only-in "cursor.scm" cpp-breakpoint-line))

(provide run-test-names
         unity-breakpoint-line
         unity-function-at-line
         unity-test-registered?)

;; The registration macro. Exactly this spelling: RUN_TEST_CASE and
;; MY_RUN_TEST are different macros and must not be mistaken for it.
(define *registration* "RUN_TEST")

;; Tokens that may precede the return type of a definition.
(define *declaration-modifiers* '("static" "extern" "inline"))

;; Whether a token could be an identifier rather than punctuation. A
;; definition is recognised structurally, so this only has to reject the
;; obvious.
(define (identifier-token? token)
  (and (not (equal? token ""))
       (equal? (identifier-prefix token) token)))

;; The name a definition line declares, or #f. The shape is a return type,
;; a name, and an opening parenthesis; a prototype ends in a semicolon and
;; declares nothing to stop in, so it is excluded.
(define (definition-name line)
  (let* ([text (trim line)]
         [before (identifier-prefix-until text #\()])
    (if (or (equal? before text) (equal? (trim before) ""))
        #f
        (let ([tokens (filter (lambda (token) (not (member? token *declaration-modifiers*)))
                              (split-whitespace (trim before)))])
          (if (or (< (length tokens) 2) (ends-with? (trim text) ";"))
              #f
              (let ([name (last tokens)])
                (if (identifier-token? name) name #f)))))))

;; A line closing a body at column zero ends the function above it. C has no
;; nesting to worry about, so the nearest definition at or above the cursor
;; is the answer.
(define (unity-function-at-line lines line)
  (if (empty? lines)
      #f
      (let loop ([index (clamp-line lines line)])
        (cond [(< index 0) #f]
              [(definition-name (list-ref lines index))
               (list (definition-name (list-ref lines index)) index)]
              [else (loop (- index 1))]))))

;; Whether a character could continue an identifier. The macro name has to
;; stand alone on both sides: RUN_TEST_CASE continues after it, and
;; MY_RUN_TEST continues before it, and neither is this macro. Written over
;; code points because steel has no char-alphabetic?.
(define (identifier-character? character)
  (let ([code (char->integer character)])
    (or (and (>= code 97) (<= code 122))
        (and (>= code 65) (<= code 90))
        (and (>= code 48) (<= code 57))
        (equal? code 95))))

(define (boundary-before? prefix)
  (let ([chars (string->list prefix)])
    (or (empty? chars) (not (identifier-character? (last chars))))))

;; Every RUN_TEST registration on one line, in order. Several may share a
;; line, and a commented-out one still counts: telling a real call from a
;; comment needs a parser, and a false positive here is a test that fails to
;; run rather than the wrong test being debugged.
;;
;; Splitting on the macro name puts every candidate boundary between two
;; segments, which is what makes both sides checkable.
(define (line-registrations line)
  (let ([segments (split-many line *registration*)])
    (let loop ([prefix (car segments)] [rest (cdr segments)] [found '()])
      (if (empty? rest)
          (reverse found)
          (let ([suffix (car rest)])
            (loop (string-append prefix *registration* suffix)
                  (cdr rest)
                  (if (and (boundary-before? prefix) (starts-with? (trim suffix) "("))
                      (let ([name (trim (identifier-prefix-until
                                         (trim (text-after suffix "("))
                                         #\)))])
                        (if (equal? name "") found (cons name found)))
                      found)))))))

(define (run-test-names lines)
  (let loop ([remaining lines] [found '()])
    (if (empty? remaining)
        found
        (loop (cdr remaining) (append found (line-registrations (car remaining)))))))

(define (unity-test-registered? name registrations)
  (member? name registrations))

;; The same rule the GoogleTest path uses: the two differ in how a test is
;; recognised, not in where to stop. A body that never opens yields the line
;; after the declaration rather than a line past the end.
(define (unity-breakpoint-line declaration lines)
  (let ([found (cpp-breakpoint-line declaration lines)])
    (if found found (+ (clamp-line lines (+ declaration 1)) 1))))
