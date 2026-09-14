;; Stub of helix's virtual helix/static.scm module, for `make compile-check`.
;; See ../README.md. The dap_* statics are absent from the fork's static.scm
;; on disk because mod.rs appends their provides at runtime.

(provide get-current-line-number
         dap_terminate)

(define (get-current-line-number) 0)
(define (dap_terminate) void)
