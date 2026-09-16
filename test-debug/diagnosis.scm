;; helix-test-debug: The setup check and its report. See docs/specs/diagnosis.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "text.scm")

(provide check
         debugger-command
         diagnosis
         diagnosis-ok?
         template-arity
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

;; The number of completion entries a named debugger template declares, or
;; #f when languages.toml has no such template.
;;
;; Arity matters as much as the name. Helix fills a template's arguments
;; positionally, so a "firmware" template declaring one completion gets the
;; image and silently never sees the chip, and a template declaring three
;; gets an empty string where it expected a value. Both look like the
;; adapter misbehaving rather than like a configuration error.
(define (template-arity text name)
  (let loop ([lines (source-lines text)]
             [current #f]
             [counting #f]
             [found #f]
             [arity 0])
    (cond
      [(empty? lines) (if (equal? current name) arity found)]
      [else
       (let ([line (trim (car lines))])
         (cond
           ;; A new template ends the one before it, whose count is kept
           ;; only if it was the one asked about.
           [(equal? line "[[language.debugger.templates]]")
            (loop (cdr lines) #f #f (if (equal? current name) arity found) 0)]
           [(and (not current) (starts-with? line "name = "))
            (loop (cdr lines)
                  (identifier-prefix-until (text-after line "\"") #\")
                  counting
                  found
                  arity)]
           ;; A table heading other than a template's own ends the block.
           [(and (starts-with? line "[") (not (starts-with? line "[language.debugger.templates")))
            (loop (cdr lines) #f #f (if (equal? current name) arity found) 0)]
           [(starts-with? line "completion = [")
            (loop (cdr lines) current #t found (+ arity (completion-entries line)))]
           [counting
            (loop (cdr lines)
                  current
                  (not (string-contains? line "]"))
                  found
                  (+ arity (completion-entries line)))]
           [else (loop (cdr lines) current counting found arity)]))])))

;; Completion entries on one line. They are tables, so each begins with a
;; brace, whether the array is written on one line or spread over several.
(define (completion-entries line)
  (let loop ([chars (string->list line)] [count 0])
    (cond [(empty? chars) count]
          [(char=? (car chars) #\{) (loop (cdr chars) (+ count 1))]
          [else (loop (cdr chars) count)])))

;; Whether a languages.toml declares this debugger template at all.
(define (template-present? text name)
  (if (template-arity text name) #t #f))

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
