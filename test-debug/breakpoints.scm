;; helix-test-debug: The breakpoint text format. See docs/specs/breakpoints.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "text.scm")

(provide breakpoint-budget
         breakpoints->text
         budget-report
         text->breakpoints
         toggle-breakpoint
         within-budget)

;; The store file, named in the report because a budget is not something
;; the editor was told: the message has to be enough to find it.
(define *store-name* ".helix/test-debug-breakpoints")

;; Marker for the optional budget line. It is not a breakpoint and must not
;; parse as one: "budget: 4" would otherwise split into a file called
;; budget on line 4.
(define *budget-keyword* "budget")

;; The text after `budget` and its colon, or #f when the line does not
;; declare one. Spacing is tolerated on both sides of the colon, because a
;; hand-written header is not formatted.
(define (budget-value line)
  (let ([trimmed (trim line)])
    (if (not (starts-with? trimmed *budget-keyword*))
        #f
        (let ([tail (trim (text-after trimmed *budget-keyword*))])
          (if (starts-with? tail ":") (trim (substring tail 1 (string-length tail))) #f)))))

(define (budget-line? line)
  (if (budget-value line) #t #f))

;; The budget a store declares, or #f. A typo must not become a limit: only
;; a whole number counts, and anything else reads as no budget at all.
(define (declared-budget line)
  (let ([value (string->number (budget-value line))])
    (if (and (integer? value) (>= value 0)) value #f)))

(define (breakpoint-budget text)
  (let loop ([lines (source-lines text)])
    (cond [(empty? lines) #f]
          [(budget-line? (car lines)) (declared-budget (car lines))]
          [else (loop (cdr lines))])))

;; Breakpoints as one file:line per line, in the order given, after the
;; budget when there is one. Without a budget the text is what it always
;; was, so a host store never grows a header.
(define (breakpoints->text breakpoints [budget #f])
  (let loop ([remaining breakpoints]
             [text (if budget
                       (string-append *budget-keyword*
                                      ": "
                                      (number->string budget)
                                      "\n")
                       "")])
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
          [(budget-line? (car lines)) (loop (cdr lines) found)]
          [else
           (let ([breakpoint (text->breakpoint (trim (car lines)))])
             (loop (cdr lines) (if breakpoint (cons breakpoint found) found)))])))

;; The breakpoints that fit. The ones set first are kept, because those are
;; the ones the user has been working with.
(define (within-budget breakpoints budget)
  (if (not budget)
      breakpoints
      (if (<= (length breakpoints) budget)
          breakpoints
          (take breakpoints budget))))

;; What the editor says after placing, or #f when there is nothing to say.
;; A report that always fires is noise.
(define (budget-report placed total budget)
  (if (or (not budget) (>= placed total))
      #f
      (string-append "placed "
                     (number->string placed)
                     " of "
                     (number->string total)
                     ", the budget in "
                     *store-name*
                     " is "
                     (number->string budget))))

(define (same-breakpoint? breakpoint file line)
  (and (equal? (car breakpoint) file) (equal? (car (cdr breakpoint)) line)))

;; The list with a breakpoint added, or removed when it is already there.
;; Removal drops every occurrence, so a hand-edited file cannot need two
;; toggles to clear one breakpoint.
(define (toggle-breakpoint breakpoints file line)
  (let ([kept (filter (lambda (breakpoint) (not (same-breakpoint? breakpoint file line)))
                      breakpoints)])
    (if (equal? (length kept) (length breakpoints))
        (append breakpoints (list (list file line)))
        kept)))
