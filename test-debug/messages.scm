;; helix-test-debug: Messages the editor half reports.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)

(provide dirty-buffer-warning
         output-report)

(define (dirty-buffer-warning name)
  (string-append "saved " name " before building"))

;; What the output buffer holds: which job printed it, then the output
;; itself, unaltered. The text is what a build or a test run actually
;; wrote, so nothing is trimmed out of it beyond a trailing newline that
;; would leave a blank line at the end of the buffer.
(define (output-report label text)
  (string-append label "\n\n" (trim-end text) "\n"))
