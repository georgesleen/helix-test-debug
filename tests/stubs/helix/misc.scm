;; Stub of helix's virtual helix/misc.scm module, for `make compile-check`.
;; See ../README.md.

(provide set-status!
         set-error!
         set-output!
         show-output!
         output->text
         enqueue-thread-local-callback-with-delay
         push-component!
         pop-last-component-by-name!)

(define (set-status! message) void)
(define (set-error! message) void)
(define (set-output! text) void)
(define (show-output!) #f)
(define (output->text text) text)
(define (enqueue-thread-local-callback-with-delay delay thunk) void)
(define (push-component! component) void)
(define (pop-last-component-by-name! name) void)
