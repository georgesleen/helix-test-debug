;; helix-test-debug: String and line helpers shared by every language half.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)

(provide drop-trailing-colon
         identifier-prefix
         identifier-prefix-until
         indentation
         member?
         source-lines
         text-after)

(define (member? item items)
  (not (empty? (filter (lambda (candidate) (equal? candidate item)) items))))

(define (source-lines text)
  (split-many text "\n"))

;; Identifier up to the first occurrence of `stop`.
(define (identifier-prefix-until token stop)
  (let loop ([chars (string->list token)] [kept '()])
    (cond [(empty? chars) (list->string (reverse kept))]
          [(char=? (car chars) stop) (list->string (reverse kept))]
          [else (loop (cdr chars) (cons (car chars) kept))])))

;; Identifier up to the first `(` or `<`, so `foo()` and `foo<T>(` both
;; yield foo.
(define (identifier-prefix token)
  (identifier-prefix-until (identifier-prefix-until token #\() #\<))

;; Depth of a line's indentation. Tabs count as one each, which is enough
;; because only the ordering of depths matters, never the column.
(define (indentation line)
  (let loop ([chars (string->list line)] [count 0])
    (cond [(empty? chars) count]
          [(char=? (car chars) #\space) (loop (cdr chars) (+ count 1))]
          [(char=? (car chars) #\tab) (loop (cdr chars) (+ count 1))]
          [else count])))

;; Text following the first occurrence of marker, or #f when absent.
(define (text-after text marker)
  (let ([span (string-length marker)]
        [limit (string-length text)])
    (let loop ([index 0])
      (cond [(> (+ index span) limit) #f]
            [(equal? (substring text index (+ index span)) marker)
             (substring text (+ index span) limit)]
            [else (loop (+ index 1))]))))

;; libtest ends the panic line with a colon before the message on the next
;; line; trim-end only takes whitespace.
(define (drop-trailing-colon text)
  (if (ends-with? text ":")
      (substring text 0 (- (string-length text) 1))
      text))
