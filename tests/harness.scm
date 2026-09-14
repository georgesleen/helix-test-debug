;; Minimal check harness: counts assertions, reports every failure, and
;; raises at the end so the interpreter exits non-zero for the gate.
;;
;; Copyright (C) 2026 George Sleen
;; SPDX-License-Identifier: LGPL-3.0-or-later

(provide check-equal! check-true! check-false! finish!)

(define *checks* 0)
(define *failures* 0)

(define (record-failure! label expected actual)
  (set! *failures* (+ *failures* 1))
  (displayln (string-append "FAIL " label))
  (displayln (string-append "  expected: " (to-string expected)))
  (displayln (string-append "  actual:   " (to-string actual))))

(define (check-equal! label expected actual)
  (set! *checks* (+ *checks* 1))
  (unless (equal? expected actual)
    (record-failure! label expected actual)))

(define (check-true! label actual)
  (check-equal! label #t actual))

(define (check-false! label actual)
  (check-equal! label #f actual))

(define (finish!)
  (displayln (string-append (to-string *checks*) " checks, "
                            (to-string *failures*) " failures"))
  (unless (equal? *failures* 0)
    (error "test suite failed")))
