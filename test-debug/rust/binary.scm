;; helix-test-debug: Building and running the crate's binary, for a line
;; that is not in a test. See docs/specs/binary-target.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require-builtin steel/json)
(require "names.scm")
(require "../text.scm")

(provide bin-executable-from-cargo-output
         binary-build-arguments
         binary-label
         binary-run-arguments
         binary-target-arguments)

;; src/bin/tool.rs and src/bin/tool/main.rs are both the binary `tool`.
(define (bin-target-name segments)
  (if (equal? (length segments) 3)
      (strip-rust-extension (list-ref segments 2))
      (list-ref segments 2)))

;; Cargo arguments selecting the binary a source file belongs to. Selecting
;; nothing builds every binary in the package, which is what a crate with
;; one of them wants; src/main.rs cannot do better, because the package's
;; own binary is named in Cargo.toml rather than by its path.
(define (binary-target-arguments relative-path)
  (let ([segments (split-many relative-path "/")])
    (if (and (> (length segments) 2)
             (equal? (car segments) "src")
             (equal? (list-ref segments 1) "bin"))
        (list "--bin" (bin-target-name segments))
        '())))

(define (binary-build-arguments relative-path)
  (append (list "build" "--message-format=json")
          (binary-target-arguments relative-path)))

(define (binary-run-arguments relative-path)
  (append (list "run") (binary-target-arguments relative-path)))

(define (binary-label relative-path)
  (let ([selected (binary-target-arguments relative-path)])
    (if (empty? selected)
        "the binary"
        (string-append "bin " (list-ref selected 1)))))

(define (parse-json-line line)
  (let ([text (trim line)])
    (if (starts-with? text "{")
        (call-with-exception-handler (lambda (failure) #f)
                                     (lambda () (string->jsexpr text)))
        #f)))

;; Whether an artifact's target is a binary. A build script also has an
;; executable, and its kind is custom-build, so the kind is what decides.
(define (bin-kind? target)
  (and (hash? target)
       (let ([kinds (hash-try-get target 'kind)])
         (and (list? kinds) (member? "bin" kinds)))))

;; Executable path of a non-test binary artifact message, or #f for every
;; other cargo message.
(define (bin-executable line)
  (let ([message (parse-json-line line)])
    (if (not (hash? message))
        #f
        (let ([executable (hash-try-get message 'executable)]
              [profile (hash-try-get message 'profile)])
          (if (and (string? executable)
                   (bin-kind? (hash-try-get message 'target))
                   (not (and (hash? profile) (equal? (hash-try-get profile 'test) #t))))
              executable
              #f)))))

;; Path of the binary cargo built, or #f when it reported none. The first
;; qualifying artifact wins: a package with several binaries resolves to
;; whichever cargo reported first, which is why naming the file under
;; src/bin/ is the way to be unambiguous.
(define (bin-executable-from-cargo-output text)
  (let loop ([lines (source-lines text)])
    (if (empty? lines)
        #f
        (let ([candidate (bin-executable (car lines))])
          (if candidate candidate (loop (cdr lines)))))))
