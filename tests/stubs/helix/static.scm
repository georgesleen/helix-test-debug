;; Stub of helix's virtual helix/static.scm module, for `make compile-check`.
;; See ../README.md. The dap_* statics are absent from the fork's static.scm
;; on disk because mod.rs appends their provides at runtime.

(provide get-helix-scm-path
         get-current-line-number
         dap_terminate
         dap_variables
         dap_toggle_breakpoint
         dap_next
         dap_step_in
         dap_step_out
         dap_continue)

(define (get-helix-scm-path) "/tmp/helix.scm")
(define (get-current-line-number) 0)
(define (dap_terminate) void)
(define (dap_variables) void)
(define (dap_toggle_breakpoint) void)
(define (dap_next) void)
(define (dap_step_in) void)
(define (dap_step_out) void)
(define (dap_continue) void)
