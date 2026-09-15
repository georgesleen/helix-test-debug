;; helix-test-debug: The path libtest matches. See docs/specs/qualified-names.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "cursor.scm")
(require "../text.scm")

(provide enclosing-modules
         module-prefix
         qualified-test-name
         strip-rust-extension)

;; Tokens that may precede `mod`.
(define *module-modifiers* '("pub" "pub(crate)" "pub(super)" "pub(self)"))

;; Module this line declares, or #f. `mod foo;` is a declaration without a
;; body and never encloses anything, so it is excluded.
(define (module-name line)
  (let loop ([tokens (split-whitespace line)])
    (cond [(empty? tokens) #f]
          [(equal? (car tokens) "mod")
           (if (empty? (cdr tokens))
               #f
               (let ([name (identifier-prefix-until (car (cdr tokens)) #\{)])
                 (if (or (equal? name "") (ends-with? name ";")) #f name)))]
          [(member? (car tokens) *module-modifiers*) (loop (cdr tokens))]
          [else #f])))

;; Modules enclosing a declaration, outermost first. A module encloses it
;; when it is declared above and indented less, which holds for any
;; conventionally formatted source.
(define (enclosing-modules lines declaration)
  (let loop ([index (- declaration 1)]
             [depth (indentation (list-ref lines declaration))]
             [found '()])
    (if (< index 0)
        found
        (let* ([line (list-ref lines index)]
               [name (module-name line)]
               [depth-here (indentation line)])
          (if (and name (< depth-here depth))
              (loop (- index 1) depth-here (cons name found))
              (loop (- index 1) depth found))))))

;; Module path a source file contributes, given its path relative to the
;; crate root. Files under src/ are modules of the library; a test or
;; benchmark file is its own crate root and contributes nothing.
(define (module-prefix relative-path)
  (let ([segments (split-many relative-path "/")])
    (if (or (empty? segments) (not (equal? (car segments) "src")))
        '()
        (let ([inner (cdr segments)])
          (if (empty? inner)
              '()
              (let* ([leaf (strip-rust-extension (last inner))]
                     [branches (take inner (- (length inner) 1))])
                (if (member? leaf '("lib" "main" "mod"))
                    branches
                    (append branches (list leaf)))))))))

;; The path libtest matches with --exact: the file's module path, the
;; modules declared around the test, then the test itself.
(define (qualified-test-name relative-path lines test)
  (string-join (append (module-prefix relative-path)
                       (enclosing-modules lines (test-declaration-line test))
                       (list (test-name test)))
               "::"))

(define (strip-rust-extension name)
  (if (ends-with? name ".rs")
      (substring name 0 (- (string-length name) 3))
      name))
