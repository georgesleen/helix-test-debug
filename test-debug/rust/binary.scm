;; helix-test-debug: Building and running the crate's binary, for a line
;; that is not in a test. See docs/specs/binary-target.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require-builtin steel/json)
(require "names.scm")
(require "../text.scm")

(provide bin-executable-from-cargo-output
         bin-names-from-cargo-output
         cargo-artifact-debuggable?
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

;; The artifact messages cargo emitted for non-test binaries. A build
;; script also has an executable, and its kind is custom-build, so the kind
;; is what decides.
(define (bin-artifacts text)
  (filter (lambda (message)
            (and (hash? message)
                 (string? (hash-try-get message 'executable))
                 (bin-kind? (hash-try-get message 'target))
                 (let ([profile (hash-try-get message 'profile)])
                   (not (and (hash? profile) (equal? (hash-try-get profile 'test) #t))))))
          (map parse-json-line (source-lines text))))

(define (artifact-executable message)
  (hash-try-get message 'executable))

(define (artifact-source message)
  (let ([target (hash-try-get message 'target)])
    (if (hash? target) (hash-try-get target 'src_path) #f)))

(define (artifact-name message)
  (let ([target (hash-try-get message 'target)])
    (if (hash? target) (hash-try-get target 'name) #f)))

;; The binaries cargo built, by name, for a message that has to name them.
(define (bin-names-from-cargo-output text)
  (filter string? (map artifact-name (bin-artifacts text))))

;; Path of the binary to debug, or #f when the output does not settle it.
;;
;; One binary needs no choosing. Several do, and taking the first would
;; silently debug the wrong program: a workspace builds every member's
;; binary, and a package may declare extra [[bin]] targets beside
;; src/main.rs. Cargo names each target's root source, so a cursor sitting
;; in one of them is an answer; otherwise the caller says it cannot tell.
(define (bin-executable-from-cargo-output text source)
  (let ([artifacts (bin-artifacts text)])
    (cond
      [(empty? artifacts) #f]
      [(equal? (length artifacts) 1) (artifact-executable (car artifacts))]
      [else
       (let loop ([remaining artifacts])
         (cond [(empty? remaining) #f]
               [(and (string? source) (equal? (artifact-source (car remaining)) source))
                (artifact-executable (car remaining))]
               [else (loop (cdr remaining))]))])))

;; Whether the image cargo produced carries line information.
;;
;; Only an explicit absence counts: cargo reports debuginfo as a number or
;; not at all, and a missing field means the profile's default rather than
;; none. Warning on a missing field would cry wolf on every ordinary dev
;; build, and a warning nobody believes is worse than none.
(define (cargo-artifact-debuggable? text executable)
  (let loop ([remaining (bin-artifacts text)])
    (cond
      [(empty? remaining) #t]
      [(equal? (artifact-executable (car remaining)) executable)
       (let* ([profile (hash-try-get (car remaining) 'profile)]
              [debuginfo (if (hash? profile) (hash-try-get profile 'debuginfo) #f)])
         ;; A json number arrives as a float, so this is a numeric test
         ;; rather than a comparison against the integer 0.
         (not (or (and (number? debuginfo) (zero? debuginfo))
                  (equal? debuginfo "none"))))]
      [else (loop (cdr remaining))])))
