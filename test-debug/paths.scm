;; helix-test-debug: Path arithmetic and the crate root. See docs/specs/paths.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)

(provide base-name
         crate-root
         join-path
         parent-directory
         path-within)

(define (parent-directory path)
  (let ([segments (split-many path "/")])
    (if (< (length segments) 2)
        ""
        (string-join (take segments (- (length segments) 1)) "/"))))

(define (base-name path)
  (let ([segments (split-many path "/")])
    (if (empty? segments) path (last segments))))

(define (join-path dir name)
  (if (equal? dir "/")
      (string-append dir name)
      (string-append dir "/" name)))

;; Path with a directory prefix removed. A path outside the directory is
;; returned unchanged.
(define (path-within root path)
  (let ([prefix (string-append root "/")])
    (if (starts-with? path prefix)
        (substring path (string-length prefix) (string-length path))
        path)))

;; Nearest ancestor directory of a file that holds a Cargo.toml. exists? is
;; injected, so this is pure.
(define (crate-root path exists?)
  (let loop ([dir (parent-directory path)])
    (cond [(equal? dir "") #f]
          [(exists? (join-path dir "Cargo.toml")) dir]
          [else (loop (parent-directory dir))])))
