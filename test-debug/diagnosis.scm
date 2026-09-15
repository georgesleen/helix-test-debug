;; helix-test-debug: The setup check and its report. See docs/specs/diagnosis.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "text.scm")

(provide check
         debugger-command
         diagnosis
         diagnosis-ok?
         template-present?)

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
