;; helix-test-debug: The breakpoint text format. See docs/specs/breakpoints.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "text.scm")

(provide breakpoints->text
         text->breakpoints)

;; Breakpoints as one file:line per line, in the order given.
(define (breakpoints->text breakpoints)
  (let loop ([remaining breakpoints] [text ""])
    (if (empty? remaining)
        text
        (let ([breakpoint (car remaining)])
          (loop (cdr remaining)
                (string-append text
                               (car breakpoint)
                               ":"
                               (number->string (car (cdr breakpoint)))
                               "\n"))))))

;; One file:line into (file line-number), or #f. The split is at the last
;; colon so a path may contain one.
(define (text->breakpoint line)
  (let ([fields (split-many line ":")])
    (if (< (length fields) 2)
        #f
        (let ([number (string->number (last fields))]
              [file (string-join (take fields (- (length fields) 1)) ":")])
          (if (integer? number) (list file number) #f)))))

;; Breakpoints parsed from text. A corrupt line is skipped rather than
;; failing the parse, so a damaged file cannot stop the editor starting.
(define (text->breakpoints text)
  (let loop ([lines (source-lines text)] [found '()])
    (cond [(empty? lines) (reverse found)]
          [(equal? (trim (car lines)) "") (loop (cdr lines) found)]
          [else
           (let ([breakpoint (text->breakpoint (trim (car lines)))])
             (loop (cdr lines) (if breakpoint (cons breakpoint found) found)))])))
