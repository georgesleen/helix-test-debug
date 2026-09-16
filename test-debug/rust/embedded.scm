;; helix-test-debug: recognising an embedded cargo project. See
;; docs/specs/embedded-cargo.md.
;;
;; A crate that runs on a microcontroller says so in .cargo/config.toml: it
;; names a runner that flashes, and a default target triple. The runner is
;; what tells the cog a local launch is wrong.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "../paths.scm")
(require "../text.scm")
(require (only-in "cargo.scm" target-arguments))

(provide cross-target?
         remote-launch?
         embedded-run-arguments
         cargo-build-target
         cargo-runner
         probe-rs-runner?
         runner-chip)

(define *adapter* "probe-rs")
(define *chip-flag* "--chip")
(define *chip-assignment* "--chip=")

;; Contents of the first double-quoted string on a line, or #f. TOML has
;; other string forms; a runner written in one of them is not recognised
;; rather than guessed at.
(define (quoted-value line)
  (let ([opening (text-after line "\"")])
    (if (not opening)
        #f
        (let ([closing (identifier-prefix-until opening #\")])
          (if (equal? closing opening) #f closing)))))

;; A commented-out assignment is ignored. Unlike a RUN_TEST call, where a
;; false positive costs a test that fails to run, a false positive here
;; sends every launch at a debug probe that is not there.
(define (comment-line? line)
  (starts-with? (trim line) "#"))

(define (assignment-value line key)
  (let ([text (trim line)])
    (if (or (comment-line? text) (not (starts-with? text key)))
        #f
        (let ([tail (trim (text-after text key))])
          (if (starts-with? tail "=") (quoted-value tail) #f)))))

(define (first-assignment text key)
  (let loop ([lines (source-lines text)])
    (cond [(empty? lines) #f]
          [(assignment-value (car lines) key) (assignment-value (car lines) key)]
          [else (loop (cdr lines))])))

(define (cargo-runner text)
  (first-assignment text "runner"))

;; The first word decides. A runner the cog cannot drive must not be
;; recognised: the launch would be built for the wrong tool.
(define (probe-rs-runner? runner)
  (if (not (string? runner))
      #f
      (let ([words (split-whitespace (trim runner))])
        (if (empty? words)
            #f
            (let ([program (car words)])
              (or (equal? program *adapter*)
                  (ends-with? program (string-append "/" *adapter*))))))))

;; The chip a runner names, or #f. probe-rs can detect one itself, so this
;; is missing information rather than an error.
(define (runner-chip runner)
  (if (not (string? runner))
      #f
      (let loop ([words (split-whitespace (trim runner))])
        (cond [(empty? words) #f]
              [(starts-with? (car words) *chip-assignment*)
               (let ([value (text-after (car words) *chip-assignment*)])
                 (if (equal? value "") #f value))]
              [(equal? (car words) *chip-flag*)
               (if (empty? (cdr words)) #f (car (cdr words)))]
              [else (loop (cdr words))]))))

(define *build-section* "[build]")

;; The default target triple, or #f. A [target.'cfg(...)'] section header
;; contains the word and an equals sign, so only an assignment inside
;; [build] counts.
(define (cargo-build-target text)
  (let loop ([lines (source-lines text)] [in-build #f])
    (cond [(empty? lines) #f]
          [(starts-with? (trim (car lines)) "[")
           (loop (cdr lines) (equal? (trim (car lines)) *build-section*))]
          [(and in-build (assignment-value (car lines) "target"))
           (assignment-value (car lines) "target")]
          [else (loop (cdr lines) in-build)])))

;; Flags probe-rs accepts. The host form cannot be reused: probe-rs
;; declares its own argument parser rather than libtest's, and
;; --test-threads is absent from it, so passing it is a hard error rather
;; than an ignored flag. It runs tests one at a time regardless.
;;
;; --nocapture is left out for the opposite reason: probe-rs accepts and
;; ignores it, so passing it would only suggest it did something.
(define *embedded-filter-flags* '("--exact" "--include-ignored"))

(define (embedded-run-arguments relative-path filter)
  (append (list "test")
          (target-arguments relative-path)
          (list "--" filter)
          *embedded-filter-flags*))

;; Whether a crate builds for something other than the machine building it,
;; which is what makes a launch remote rather than local. There is
;; deliberately no list of embedded triples: anything that is not the host
;; qualifies, including targets that do not exist yet.
(define (cross-target? triple host)
  (and (string? triple) (not (equal? triple host))))

;; Whether the binary needs something else to run it. A declared runner is
;; that statement: cargo will not execute the artifact directly, so neither
;; should the cog. That one fact is the whole rule, which is why no list of
;; targets or tools appears in this file. Which adapter to drive, and what
;; to tell it, is the launch template's business.
(define (remote-launch? runner)
  (and (string? runner) (not (equal? (trim runner) ""))))
