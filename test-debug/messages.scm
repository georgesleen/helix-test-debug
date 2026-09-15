;; helix-test-debug: Messages the editor half reports.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)

(provide dirty-buffer-warning)

(define (dirty-buffer-warning name)
  (string-append "saved " name " before building"))
