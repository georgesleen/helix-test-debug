;; helix-test-debug: driving a PlatformIO project. See
;; docs/specs/pio-project.md.
;;
;; PlatformIO builds one program per folder under test/ and runs every test
;; in it, so a single Unity test is debugged by building its folder and
;; stopping at the test's first line. There is no filter to pass.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require "../paths.scm")
(require "../text.scm")

(provide pio-build-arguments
         pio-chip
         pio-environment-platform
         pio-firmware-build
         pio-firmware-environment
         pio-firmware-path
         pio-debug-build
         pio-environment
         pio-environments
         pio-outcome
         pio-program-path
         pio-run-arguments
         pio-root
         pio-test-folder)

;; Nearest directory above a file holding a platformio.ini, or #f. The
;; manifest is what distinguishes a PlatformIO project from a CMake one,
;; and a project may be both, so the caller decides which wins.
(define (pio-root path exists?)
  (let loop ([dir (parent-directory path)])
    (cond [(equal? dir "") #f]
          [(exists? (join-path dir "platformio.ini")) dir]
          [else (loop (parent-directory dir))])))

;; The environment that builds for the host, and so the only one a local
;; debugger can attach to.
(define *host-environment* "native")

(define *section-prefix* "[env:")

;; The environment a section header declares, or #f. A bare [env] section is
;; the defaults for every environment rather than one of them.
(define (section-environment line)
  (let ([text (trim line)])
    (if (not (starts-with? text *section-prefix*))
        #f
        (let ([name (trim (identifier-prefix-until
                           (trim (text-after text *section-prefix*))
                           #\]))])
          (if (equal? name "") #f name)))))

(define (pio-environments text)
  (let loop ([lines (source-lines text)] [found '()])
    (if (empty? lines)
        (reverse found)
        (let ([name (section-environment (car lines))])
          (loop (cdr lines) (if name (cons name found) found))))))

;; The environment to build. Reporting the wrong one is better than
;; reporting none, because the launch names it.
(define (pio-environment text)
  (let ([environments (pio-environments text)])
    (cond [(empty? environments) #f]
          [(member? *host-environment* environments) *host-environment*]
          [else (car environments)])))

(define *test-root* "test")

;; The test folder a file belongs to. A file directly under test/ has none:
;; PlatformIO builds it into every folder's program rather than one of its
;; own, so there is no single program to launch.
(define (pio-test-folder relative-path)
  (let ([segments (split-many relative-path "/")])
    (if (and (> (length segments) 2) (equal? (car segments) *test-root*))
        (list-ref segments 1)
        #f)))

(define (pio-selection environment folder)
  (list "test" "-e" environment "-f" folder))

;; --without-testing is what separates building from running: a debugger
;; needs the program, not its output.
(define (pio-build-arguments environment folder)
  (append (pio-selection environment folder) (list "--without-testing")))

;; A native build has no -g, so a breakpoint on it resolves to no locations
;; and the program runs to completion: the failure reads as an ignored
;; breakpoint rather than a build problem. PlatformIO takes its flags from
;; the environment and offers no flag for them, and steel cannot set a
;; child's environment, so the build runs under a shell.
;;
;; Values reach the shell through "$@" and never through the script text,
;; so a folder name cannot be read as shell syntax. -O0 matters as much as
;; -g: an optimised build steps through lines out of order.
(define *debug-build-script* "PLATFORMIO_BUILD_FLAGS=\"-g -O0\" exec pio \"$@\"")

(define (pio-debug-build environment folder)
  (append (list "-c" *debug-build-script* "pio")
          (pio-build-arguments environment folder)))

(define (pio-run-arguments environment folder)
  (pio-selection environment folder))

;; The name is fixed for every folder in an environment, so the build and
;; the launch have to name the same folder.
(define (pio-program-path environment)
  (join-path (join-path ".pio" (join-path "build" environment)) "program"))

(define *summary-marker* "test cases:")

;; PlatformIO draws rules of = around its summary, which would otherwise go
;; on the statusline with it.
(define (strip-rules text)
  (let loop ([chars (string->list text)] [kept '()])
    (cond [(empty? chars) (trim (list->string (reverse kept)))]
          [(char=? (car chars) #\=) (loop (cdr chars) kept)]
          [else (loop (cdr chars) (cons (car chars) kept))])))

;; The summary pio test printed, or #f. One appears per environment and the
;; last is the one that counts.
(define (pio-outcome output)
  (let loop ([lines (source-lines output)] [outcome #f])
    (cond [(empty? lines) outcome]
          [(string-contains? (car lines) *summary-marker*)
           (loop (cdr lines) (strip-rules (car lines)))]
          [else (loop (cdr lines) outcome)])))

;; The section a line opens, or #f. Assignments below it belong to it,
;; which is what makes a per-environment lookup possible at all.
(define (section-name line)
  (let ([text (trim line)])
    (if (and (starts-with? text "[") (string-contains? text "]"))
        (identifier-prefix-until (text-after text "[") #\])
        #f)))

(define (environment-lines text environment)
  (let loop ([lines (source-lines text)] [current #f] [found '()])
    (cond [(empty? lines) (reverse found)]
          [(section-name (car lines))
           (loop (cdr lines) (section-name (car lines)) found)]
          [(equal? current (string-append "env:" environment))
           (loop (cdr lines) current (cons (car lines) found))]
          [else (loop (cdr lines) current found)])))

;; The value a key is assigned inside one environment, or #f. An assignment
;; in [env] or in a sibling environment is deliberately not it: those are
;; defaults and other people's business respectively.
(define (environment-value text environment key)
  (let loop ([lines (environment-lines text environment)])
    (if (empty? lines)
        #f
        (let ([line (trim (car lines))])
          (if (starts-with? line key)
              (let ([tail (trim (text-after line key))])
                (if (starts-with? tail "=")
                    (trim (text-after tail "="))
                    (loop (cdr lines))))
              (loop (cdr lines)))))))

(define (pio-environment-platform text environment)
  (environment-value text environment "platform"))

;; Everything that is not the host is firmware: the same rule the rust half
;; uses, needing no list of platforms. raspberrypi, espressif32, ststm32, a
;; git URL, or whatever ships next year all qualify.
(define (pio-firmware-environment text)
  (let loop ([environments (pio-environments text)])
    (cond [(empty? environments) #f]
          [(equal? (pio-environment-platform text (car environments)) *host-environment*)
           (loop (cdr environments))]
          [else (car environments)])))

;; Where every PlatformIO platform leaves the linked image.
(define (pio-firmware-path environment)
  (join-path (join-path ".pio" (join-path "build" environment)) "firmware.elf"))

;; -Og -g2, which is what PlatformIO's own debug_build_flags default to, so
;; this matches what `build_type = debug` would have done. Its build type
;; cannot be set per invocation: `pio run` has no --project-option and
;; PLATFORMIO_BUILD_TYPE is ignored, so the flags are appended instead and
;; win by being last.
;;
;; -O0 is deliberately not used here, unlike the host test build. Turning
;; optimisation off can push an image past the flash it has to fit in, and
;; it changes the timing of anything bit-banged. -Og is the setting meant
;; for this: debuggable without rewriting the codegen.
(define *firmware-build-script* "PLATFORMIO_BUILD_FLAGS=\"-Og -g2\" exec pio \"$@\"")

(define (pio-firmware-build environment)
  (list "-c" *firmware-build-script* "pio" "run" "-e" environment))

;; The chip to name in the launch, from PlatformIO's own convention for
;; options it does not define. A board name is not a chip name and is not
;; translated into one: different namespaces, and guessing between them
;; would flash the wrong thing.
(define (pio-chip text environment)
  (let ([chip (environment-value text environment "custom_chip")])
    (if chip chip "")))
