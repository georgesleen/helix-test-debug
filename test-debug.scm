;; helix-test-debug: debug or run the test under the cursor, for Helix with
;; the Steel plugin system (github:mattwparas/helix, branch
;; steel-event-system).
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later
;;
;; Editor half: reads the cursor, builds off the editor thread, and starts
;; the session. Every decision lives in the pure halves gathered by
;; test-debug-rust.scm and test-debug-cpp.scm, which carry the tests. This
;; file is the only place that knows which language a buffer is.

(require (prefix-in helix. "helix/commands.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/ext.scm")
;; The cursor line and the dap_* commands are static commands, not misc.
(require (only-in "helix/static.scm"
                  get-helix-scm-path
                  get-current-line-number
                  dap_terminate
                  dap_variables
                  dap_toggle_breakpoint
                  dap_next
                  dap_step_in
                  dap_step_out
                  dap_continue))
(require-builtin helix/core/text as text.)
(require-builtin steel/process)
(require-builtin steel/strings)
(require-builtin steel/filesystem)
(require (only-in "test-debug-picker.scm" pick-test!))
(require "test-debug-rust.scm")
(require (only-in "test-debug-cpp.scm"
                  test-macros
                  macro-invocation
                  candidate-name
                  cpp-test-at-line
                  cpp-breakpoint-line
                  ctest-tests
                  ctest-test-name
                  ctest-test-executable
                  ctest-test-arguments
                  ctest-test-directory
                  matching-tests
                  build-directory
                  project-root
                  run-test-names
                  unity-breakpoint-line
                  unity-function-at-line
                  unity-test-registered?
                  unity-tests-in-file
                  pio-build-arguments
                  pio-debug-build
                  pio-environment
                  pio-outcome
                  pio-program-path
                  pio-root
                  pio-run-arguments
                  build-type-debuggable?
                  cmake-build-type
                  cmake-cross-system?
                  cmake-toolchain-file
                  codemodel-reply
                  codemodel-targets
                  firmware-artifact
                  pio-chip
                  pio-environment-platform
                  pio-firmware-build
                  pio-firmware-environment
                  pio-firmware-path
                  pio-test-folder))

(provide debug-here
         dbgh
         run-here
         debug-again
         test-pick
         debug-doctor
         debug-failure
         debug-cancel
         debug-breakpoint
         debug-breakpoints
         debug-breakpoints-clear
         debug-variables
         debug-step-over
         debug-step-in
         debug-step-out
         debug-continue)

;; Debugger templates this cog drives. README.md carries the
;; languages.toml it expects.
;;
;; A test: the binary, the test filter, the source file and the line.
(define *cargo-template* "cargo test at line")

;; A binary ctest already named, which needs no filter flag because ctest
;; reported the argument that selects the test.
(define *binary-template* "binary at line")

;; The crate's own binary, stopped at the cursor. A template's arguments
;; are positional, so one with no filter has to be its own template.
(define *program-template* "program at line")

;; An embedded target, flashed by probe-rs, taking only the ELF. probe-rs
;; has no preRunCommands, so the breakpoint cannot ride in the launch: it
;; is placed in helix first, and helix sends it once the adapter reports
;; itself initialised.
(define *firmware-template* "firmware")

;; Cargo is polled from the editor thread this often, and abandoned after
;; this many polls.
(define *poll-interval-ms* 250)
(define *poll-limit* 1200)

;; Label of the job in flight, or #f when idle. Editor thread only.
(define *job-label* #f)

(define (job-running?)
  (string? *job-label*))

;; Last resolved request, so it can be repeated from another buffer.
(define *last-request* #f)

;; Whether the variables popup is being kept fresh. Helix builds that
;; popup from a snapshot and never updates it, so stepping refreshes it
;; here instead.
(define *watching-variables* #f)

;; How long the adapter is given to report the new stop location before the
;; popup is rebuilt.
(define *refresh-delay-ms* 120)

(define (status! message)
  (set-status! (string-append "test: " message)))

(define (fail! message)
  (set-error! (string-append "test: " message)))

(define (focused-path)
  (editor-document->path (editor->doc-id (editor-focus))))

(define (focused-text)
  (text.rope->string (editor->text (editor->doc-id (editor-focus)))))

;; stdout of a command run in a directory, or #f when it could not be run
;; at all. A command that runs and fails yields whatever it printed.
(define (captured-output program arguments directory)
  (let ([spawned (spawn-process
                  (with-stdout-piped
                   (with-current-dir (command program arguments) directory)))])
    (if (Err? spawned)
        #f
        (let ([finished (wait->stdout (Ok->value spawned))])
          (if (Err? finished) #f (Ok->value finished))))))

;; Suffixes that decide which half of the cog handles a buffer. This is the
;; only language knowledge in the file.
(define *rust-suffixes* '(".rs"))
(define *cpp-suffixes* '(".c" ".cc" ".cpp" ".cxx" ".h" ".hh" ".hpp" ".hxx"))

(define (suffix-of? path suffixes)
  (not (empty? (filter (lambda (suffix) (ends-with? path suffix)) suffixes))))

(define (language-for path)
  (cond [(suffix-of? path *rust-suffixes*) 'rust]
        [(suffix-of? path *cpp-suffixes*) 'cpp]
        [else #f]))

;; A request is everything needed to build and launch, resolved from the
;; cursor before any work starts. Keyed rather than positional because the
;; two languages carry different fields: cargo derives its command, while
;; ctest reports one.
(define (request-get request key)
  (hash-try-get request key))

(define (request-root request) (request-get request 'root))
(define (request-file request) (request-get request 'file))
(define (request-filter request) (request-get request 'filter))
(define (request-line request) (request-get request 'line))

;; Resolve the cursor in a rust buffer, or a string saying why not. A line
;; that is not in a test is not a failure: the breakpoint machinery does not
;; care, so the crate's binary is built instead and stopped at the cursor
;; itself rather than at the first line of a body.
;; The triple this machine builds for, or #f when rustc cannot say. Asked
;; once: it cannot change while the editor is running.
(define *host-triple* #f)

(define (host-triple)
  (when (not *host-triple*)
    (let ([output (captured-output "rustc" '("-vV") ".")])
      (set! *host-triple*
            (if (string? output)
                (let loop ([lines (source-lines output)])
                  (cond [(empty? lines) #f]
                        [(starts-with? (trim (car lines)) "host:")
                         (trim (text-after (car lines) "host:"))]
                        [else (loop (cdr lines))]))
                #f))))
  *host-triple*)

;; The runner a crate declares, or #f. Read on each resolution rather than
;; cached: a project gains one the moment it is pointed at hardware.
(define (crate-runner root)
  (cargo-runner (or (file-contents (join-path root ".cargo/config.toml")) "")))

;; A crate whose config declares a runner is not launched locally: cargo
;; will not execute the artifact directly, so neither does the cog. The
;; runner's identity is not consulted, and no target list exists here;
;; which adapter to drive is what the launch template says.
(define (crate-firmware? root)
  (let ([config (or (file-contents (join-path root ".cargo/config.toml")) "")])
    (remote-launch? (cargo-runner config))))

;; What the status line calls the target: the chip when the runner names
;; one, otherwise the triple, which every cross build has.
(define (firmware-label root)
  (let ([config (or (file-contents (join-path root ".cargo/config.toml")) "")])
    (or (runner-chip (cargo-runner config))
        (cargo-build-target config)
        "the target")))

(define (rust-request path lines line)
  (let ([test (test-at-line lines line)]
        [root (crate-root path path-exists?)])
    (cond
      [(not root) (string-append "no Cargo.toml above " (base-name path))]
      [(and test (crate-firmware? root))
       (string-append "debugging one test on "
                      (or (runner-chip (crate-runner root)) "the target")
                      " needs a debug console, which helix has no command for; run-here runs it")]
      [test
       (let ([relative-path (path-within root path)])
         (hash 'language 'rust
               'kind 'test
               'root root
               'relative-path relative-path
               'file (base-name path)
               'filter (qualified-test-name relative-path lines test)
               'line (breakpoint-line (test-declaration-line test))))]
      ;; An embedded crate cannot be launched locally. Its binary runs on
      ;; the target, and one of its tests cannot even be selected, because
      ;; naming a test is a debug-console command and helix has no way to
      ;; send one. Saying so beats flashing the wrong thing.
      [(crate-firmware? root)
       (let ([relative-path (path-within root path)])
         (hash 'language 'rust
               'kind 'firmware
               'root root
               'relative-path relative-path
               'file (base-name path)
               'filter (firmware-label root)
               'chip (or (runner-chip (crate-runner root)) "")
               'line (+ line 1)))]
      [else
       (let ([relative-path (path-within root path)])
         (hash 'language 'rust
               'kind 'binary
               'root root
               'relative-path relative-path
               'file (base-name path)
               'filter (binary-label relative-path)
               'line (+ line 1)))])))

;; Resolve the cursor in a C or C++ buffer. The candidate from the cursor is
;; matched against what ctest registered, so a parameterized test resolves
;; to its generated siblings rather than failing.
(define (ctest-request path lines line)
  (let* ([test (cpp-test-at-line lines line (test-macros))]
         [root (project-root path path-exists?)]
         [build (if root (build-directory root path-exists?) #f)])
    (cond
      [(not test) "no test macro at or above the cursor"]
      [(not root) (string-append "no CMakeLists.txt above " (base-name path))]
      [(not build) (string-append "no configured build directory under " root)]
      [else
       (let* ([candidate (car test)]
              [listed (ctest-tests (or (captured-output "ctest" '("--show-only=json-v1") build) ""))]
              [matches (matching-tests candidate listed)])
         (cond
           [(empty? listed)
            (string-append "ctest registered no tests in " build "; configure and build first")]
           [(empty? matches)
            (string-append candidate " is not a test ctest knows; it may need a build")]
           [else
            (let ([match (car matches)])
              (hash 'language 'cpp
                    'root root
                    'build build
                    'file (base-name path)
                    'filter (ctest-test-name match)
                    'line (cpp-breakpoint-line (car (cdr test)) lines)
                    'executable (ctest-test-executable match)
                    'arguments (ctest-test-arguments match)
                    'directory (ctest-test-directory match)))]))])))

;; Every registration in a test folder, not just in the file at the cursor:
;; the runner's main is conventionally beside the tests rather than in them.
(define (folder-registrations directory)
  (let loop ([entries (safe-read-dir directory)] [found '()])
    (if (empty? entries)
        found
        (let ([text (if (is-dir? (car entries)) #f (file-contents (car entries)))])
          (loop (cdr entries)
                (if (string? text)
                    (append found (run-test-names (source-lines text)))
                    found))))))

;; Resolve the cursor in a PlatformIO project. Unity has no test attribute,
;; so the cursor names a candidate and a RUN_TEST call in the folder is what
;; makes it a test. There is no filter to pass: the program runs every test
;; in its folder, and the breakpoint is what isolates this one.
(define (unity-request path lines line root)
  (let* ([function (unity-function-at-line lines line)]
         [relative-path (path-within root path)]
         [folder (pio-test-folder relative-path)]
         [environment (pio-environment (or (file-contents (join-path root "platformio.ini")) ""))])
    (cond
      [(not function) "no function at or above the cursor"]
      [(not folder)
       (string-append (base-name path) " is not inside a test/<folder>/ of " root)]
      [(not environment) (string-append "platformio.ini in " root " declares no environment")]
      [(not (unity-test-registered? (car function)
                                    (folder-registrations
                                     (join-path (join-path root "test") folder))))
       (string-append (car function)
                      " is not a test; nothing in "
                      folder
                      " calls RUN_TEST("
                      (car function)
                      ")")]
      [else
       (hash 'language 'cpp
             'kind 'unity
             'root root
             'file (base-name path)
             'filter (car function)
             'line (unity-breakpoint-line (car (cdr function)) lines)
             'environment environment
             'folder folder
             'executable (join-path root (pio-program-path environment)))])))

;; CMake writes its system facts under a version directory, so the file has
;; to be looked for rather than named.
(define (cmake-system-file build)
  (let ([directory (join-path build "CMakeFiles")])
    (let loop ([entries (safe-read-dir directory)])
      (cond [(empty? entries) #f]
            [else
             (let ([candidate (join-path (car entries) "CMakeSystem.cmake")])
               (if (and (is-dir? (car entries)) (path-exists? candidate))
                   candidate
                   (loop (cdr entries))))]))))

;; Either signal is enough: a build may name a system with no toolchain
;; file, or use a toolchain file whose system matches the host.
(define (cmake-cross? build)
  (let ([system (cmake-system-file build)])
    (or (and system (cmake-cross-system? (or (file-contents system) "")))
        (if (cmake-toolchain-file (or (file-contents (join-path build "CMakeCache.txt")) ""))
            #t
            #f))))

;; The file API answers "which image do I flash" for any project and any
;; toolchain, but only if the query exists before cmake configures, so it
;; is written before the build rather than read after it.
(define (write-codemodel-query! build)
  (call-with-exception-handler
   (lambda (failure) #f)
   (lambda ()
     (let loop ([directory build]
                [segments '(".cmake" "api" "v1" "query")])
       (if (empty? segments)
           (call-with-output-file (join-path directory "codemodel-v2")
                                  (lambda (port) (display "" port)))
           (let ([next (join-path directory (car segments))])
             (when (not (path-exists? next))
               (create-directory! next))
             (loop next (cdr segments))))))))

(define (reply-directory build)
  (join-path (join-path (join-path (join-path build ".cmake") "api") "v1") "reply"))

;; The newest index file, since a reply directory accumulates one per
;; configure and only the last describes the build as it now stands.
(define (newest-index build)
  (let loop ([entries (safe-read-dir (reply-directory build))] [found #f])
    (cond [(empty? entries) found]
          [(starts-with? (base-name (car entries)) "index-")
           (loop (cdr entries)
                 (if (or (not found) (string>? (base-name (car entries)) (base-name found)))
                     (car entries)
                     found))]
          [else (loop (cdr entries) found)])))

;; The image for the file under the cursor, from the file API's reply.
;; Which of a project's executables that is, and whether the source is
;; compiled into it directly or through a library, is decided in the pure
;; half.
(define (cmake-firmware-artifact build source)
  (let ([index (newest-index build)])
    (if (not index)
        #f
        (let ([reply (codemodel-reply (or (file-contents index) ""))])
          (if (not reply)
              #f
              (firmware-artifact
               (map (lambda (target)
                      (or (file-contents (join-path (reply-directory build) target)) ""))
                    (codemodel-targets
                     (or (file-contents (join-path (reply-directory build) reply)) "")))
               source))))))

;; A project may carry both manifests. PlatformIO wins when the file is
;; inside its test tree, because that is the only thing that could have
;; built it.
(define (cpp-request path lines line)
  (let* ([pio (pio-root path path-exists?)]
         [root (project-root path path-exists?)]
         [build (if root (build-directory root path-exists?) #f)])
    (cond
      [(and pio (pio-test-folder (path-within pio path)))
       (unity-request path lines line pio)]
      [pio (pio-firmware-request path lines line pio)]
      [(and build (cmake-cross? build)) (cmake-firmware-request path lines line root build)]
      [else (ctest-request path lines line)])))

;; Firmware in a PlatformIO project: everything outside test/ builds for the
;; board rather than the host.
(define (pio-firmware-request path lines line root)
  (let* ([manifest (or (file-contents (join-path root "platformio.ini")) "")]
         [environment (pio-firmware-environment manifest)])
    (if (not environment)
        (string-append "no environment in " root "/platformio.ini builds for a board")
        (hash 'language 'cpp
              'kind 'pio-firmware
              'root root
              'file (base-name path)
              'filter environment
              'line (+ line 1)
              'environment environment
              'chip (pio-chip manifest environment)
              'executable (join-path root (pio-firmware-path environment))))))

;; Firmware in a CMake project. The artifact is not known yet: the file API
;; only answers after a configure, so the build resolves it.
(define (cmake-firmware-request path lines line root build)
  (let ([type (cmake-build-type (or (file-contents (join-path build "CMakeCache.txt")) ""))])
    (hash 'language 'cpp
          'kind 'cmake-firmware
          'root root
          'build build
          'file (base-name path)
          ;; CMake names sources relative to the top of the project, so the
          ;; base name is not enough to match one: a file in a subdirectory
          ;; is "main/main.c" there and would match nothing.
          'relative-path (path-within root path)
          'filter (or type "the target")
          'line (+ line 1)
          'chip ""
          'debuggable (build-type-debuggable?
                       type
                       (cmake-cache-flags
                        (or (file-contents (join-path build "CMakeCache.txt")) ""))))))

;; Whatever C and C++ flags the cache carries, so a project that adds -g by
;; hand is not warned about needlessly.
(define (cmake-cache-flags cache)
  (string-append (or (cmake-build-type cache) "") " " cache))

;; Resolve the cursor into a request, or a string saying why not. The
;; message names what was found, because "no test here" leaves you guessing
;; whether to move the cursor or add an attribute.
(define (request-at-cursor)
  (let ([path (focused-path)])
    (if (not (string? path))
        "this buffer has no file on disk"
        (let ([lines (source-lines (focused-text))]
              [line (get-current-line-number)]
              [language (language-for path)])
          (cond [(equal? language 'rust) (rust-request path lines line)]
                [(equal? language 'cpp) (cpp-request path lines line)]
                [else (string-append "no test support for " (base-name path))])))))

;; Ending a live session keeps a relaunch from colliding with it and from
;; leaving the adapter behind. Nothing exposes whether one is running, so
;; this is attempted unconditionally and its complaint discarded.
(define (terminate-existing!)
  (call-with-exception-handler (lambda (failure) #f) (lambda () (dap_terminate))))

(define (elapsed-seconds ticks)
  (quotient (* ticks *poll-interval-ms*) 1000))

;; Re-arm a timer until the job finishes. This is what wakes the editor: a
;; callback queued from a worker thread is drained only when the event loop
;; wakes, so without it the result would not land until the next keypress.
(define (keep-awake! label ticks)
  (when (job-running?)
    (if (> ticks *poll-limit*)
        (begin
          (set! *job-label* #f)
          (fail! (string-append "gave up waiting after "
                                (number->string (elapsed-seconds ticks))
                                "s")))
        (begin
          (status! (string-append label
                                  " ("
                                  (number->string (elapsed-seconds ticks))
                                  "s)"))
          (enqueue-thread-local-callback-with-delay
           *poll-interval-ms*
           (lambda () (keep-awake! label (+ ticks 1))))))))

;; Run a program on a worker thread; complete! runs on the editor thread
;; with its stdout, or #f when it could not be run.
(define (start-job! label program directory arguments complete!)
  (set! *job-label* label)
  (status! label)
  (spawn-native-thread
   (lambda ()
     (let ([output (captured-output program arguments directory)])
       (hx.block-on-task
        (lambda ()
          (set! *job-label* #f)
          (complete! output))))))
  (keep-awake! label 1))

;; Start a session on a binary, stopped at file and line. The stop location
;; is a parameter because debugging a failure stops where it panicked, not
;; where the test began.
(define (launch! request binary file line)
  (terminate-existing!)
  ;; Helix hands the adapter the breakpoints it holds when the session
  ;; starts, so a remembered set has to be in place before this, not after.
  (restore-breakpoints! (request-root request))
  (cond
    ;; Every remote launch is the same shape: the adapter gets the image and
    ;; the chip, and the breakpoint goes through helix because a flashing
    ;; adapter takes none in its launch request.
    [(remote-kind? (request-get request 'kind))
     (place-breakpoint! (firmware-source request) line)
     (helix.debug-start *firmware-template* binary (request-get request 'chip))]
    ;; A Unity program runs every test in its folder and takes no filter,
    ;; so the breakpoint is what isolates the one under the cursor. Same
    ;; template as a rust binary, for the same reason.
    [(equal? (request-get request 'kind) 'unity)
     (helix.debug-start *program-template* binary file (number->string line))]
    [(equal? (request-get request 'language) 'cpp)
     (helix.debug-start *binary-template*
                        binary
                        (car (request-get request 'arguments))
                        file
                        (number->string line))]
    ;; A binary takes no filter, so it needs a template of its own: a
    ;; template's arguments are positional and cannot be left out.
    [(equal? (request-get request 'kind) 'binary)
     (helix.debug-start *program-template* binary file (number->string line))]
    ;; probe-rs takes no breakpoint in its launch request and drops the key
    ;; silently, so the breakpoint is placed in helix and helix delivers it
    ;; over setBreakpoints once the adapter is initialised.
    [else
     (helix.debug-start *cargo-template*
                        binary
                        (request-filter request)
                        file
                        (number->string line))])
  (status! (string-append (request-filter request)
                          " at "
                          file
                          ":"
                          (number->string line))))

(define (report-build-failure! request command)
  (fail! (string-append "nothing to debug; run `"
                        command
                        "` in "
                        (request-root request)
                        " to see why")))

;; Build the cargo target, then hand the binary cargo reported to
;; at-binary!, which decides where to stop. A test target and a binary
;; differ in the invocation and in which artifact to pick out of the JSON.
(define (build-rust-then! request at-binary!)
  (let* ([binary? (or (equal? (request-get request 'kind) 'binary)
                      ;; Firmware builds exactly like a binary: the triple
                      ;; comes from .cargo/config.toml, so cargo needs no
                      ;; telling and the artifact is found the same way.
                      (equal? (request-get request 'kind) 'firmware))]
         [relative-path (request-get request 'relative-path)]
         [arguments (if binary?
                        (binary-build-arguments relative-path)
                        (build-arguments relative-path))])
    (start-job!
     (string-append "building " (request-filter request))
     "cargo"
     (request-root request)
     arguments
     (lambda (output)
       (let ([binary (if (string? output)
                         (if binary?
                             (bin-executable-from-cargo-output output)
                             (executable-from-cargo-output output))
                         #f)])
         (if binary
             (at-binary! binary)
             (report-build-failure! request (string-append "cargo " (string-join arguments " ")))))))))

;; Build the CMake project, then use the executable ctest already named.
;; Nothing has to be parsed out of the build: discovery happened before it.
(define (build-cpp-then! request at-binary!)
  (let ([build (request-get request 'build)])
    (start-job!
     (string-append "building " (request-filter request))
     "cmake"
     build
     (list "--build" ".")
     (lambda (output)
       (let ([binary (request-get request 'executable)])
         (cond
           [(not (string? output)) (report-build-failure! request "cmake --build .")]
           [(not (string? binary))
            (fail! (string-append "ctest named no executable for "
                                  (request-filter request)
                                  "; build the project once so it can"))]
           [(not (equal? (length (request-get request 'arguments)) 1))
            (fail! (string-append "ctest runs "
                                  (request-filter request)
                                  " with "
                                  (number->string (length (request-get request 'arguments)))
                                  " arguments; the launch template takes exactly one"))]
           [else (at-binary! binary)]))))))

;; Build one test folder's program without running it. PlatformIO leaves it
;; at a fixed path per environment, so nothing has to be parsed out of the
;; build either.
(define (build-pio-then! request at-binary!)
  (let ([arguments (pio-debug-build (request-get request 'environment)
                                    (request-get request 'folder))])
    (start-job!
     (string-append "building " (request-get request 'folder))
     "sh"
     (request-root request)
     arguments
     (lambda (output)
       (let ([binary (request-get request 'executable)])
         (cond
           [(not (string? output))
            (report-build-failure! request (string-append "pio " (string-join (pio-build-arguments (request-get request 'environment) (request-get request 'folder)) " ")))]
           [(not (path-exists? binary))
            (report-build-failure! request (string-append "pio " (string-join (pio-build-arguments (request-get request 'environment) (request-get request 'folder)) " ")))]
           [else (at-binary! binary)]))))))

(define (build-then! request at-binary!)
  (set! *last-request* request)
  (cond [(equal? (request-get request 'kind) 'unity) (build-pio-then! request at-binary!)]
        [(equal? (request-get request 'kind) 'pio-firmware)
         (build-pio-firmware-then! request at-binary!)]
        [(equal? (request-get request 'kind) 'cmake-firmware)
         (build-cmake-firmware-then! request at-binary!)]
        [(equal? (request-get request 'language) 'cpp) (build-cpp-then! request at-binary!)]
        [else (build-rust-then! request at-binary!)]))

;; Build the image PlatformIO leaves at a fixed path, with debug flags
;; appended because its build type cannot be set per invocation.
(define (build-pio-firmware-then! request at-binary!)
  (let ([arguments (pio-firmware-build (request-get request 'environment))])
    (start-job!
     (string-append "building " (request-get request 'environment))
     "sh"
     (request-root request)
     arguments
     (lambda (output)
       (let ([binary (request-get request 'executable)])
         (cond
           [(not (string? output))
            (report-build-failure! request
                                   (string-append "pio run -e "
                                                  (request-get request 'environment)))]
           [(not (path-exists? binary))
            (report-build-failure! request
                                   (string-append "pio run -e "
                                                  (request-get request 'environment)))]
           [else (at-binary! binary)]))))))

;; Configure and build, then ask CMake's file API which image was produced.
;; The query has to exist before the configure, so it is written first.
(define (build-cmake-firmware-then! request at-binary!)
  (let ([build (request-get request 'build)])
    (write-codemodel-query! build)
    (when (not (request-get request 'debuggable))
      (status! (string-append "this build has no debug flags; "
                              "configure it Debug or RelWithDebInfo "
                              "or the breakpoint will not bind")))
    (start-job!
     (string-append "building " (base-name build))
     "sh"
     (request-root request)
     (list "-c" "cmake \"$1\" >/dev/null && cmake --build \"$1\"" "sh" build)
     (lambda (output)
       (let ([artifact (cmake-firmware-artifact
                        build
                        (request-get request 'relative-path))])
         (cond
           [(not (string? output))
            (report-build-failure! request (string-append "cmake --build " build))]
           [(not artifact)
            (fail! (string-append "CMake's file API named no single executable in "
                                  build
                                  "; a project that builds several cannot have one chosen for it"))]
           [else (at-binary! (join-path build artifact))]))))))

(define (debug-request! request)
  (build-then! request
               (lambda (binary)
                 (launch! request binary (request-file request) (request-line request)))))

;; Run a test and report libtest's summary. A binary has no summary, so it
;; reports the last line the program printed instead, which is the useful
;; part of a program run from an editor.
(define (run-request! request)
  (set! *last-request* request)
  (cond
    ;; A Unity run is per folder rather than per test, so the summary
    ;; covers the folder and the status line says so.
    [(equal? (request-get request 'kind) 'unity) (run-pio! request)]
    [(equal? (request-get request 'language) 'cpp)
     (fail! "running a ctest without a debugger is not supported yet; use debug-here")]
    [(equal? (request-get request 'kind) 'binary) (run-binary! request)]
    [(equal? (request-get request 'kind) 'firmware) (run-firmware! request)]
    [else
     (start-job!
      (string-append "running " (request-filter request))
      "cargo"
      (request-root request)
      (run-arguments (request-get request 'relative-path) (request-filter request))
      (lambda (output)
        (let ([outcome (if (string? output) (test-outcome output) #f)])
          (if outcome
              (status! (string-append (request-filter request) ": " outcome))
              (fail! (string-append (request-filter request)
                                    " printed no result; the build probably failed"))))))]))

;; Run on the target, through the runner the crate declares. cargo run
;; flashes and runs; a test needs probe-rs's own flags, since it rejects
;; --test-threads outright rather than ignoring it.
(define (run-firmware! request)
  (start-job!
   (string-append "running on " (request-filter request))
   "cargo"
   (request-root request)
   (binary-run-arguments (request-get request 'relative-path))
   (lambda (output)
     (let ([tail (if (string? output) (last-line output) #f)])
       (cond
         [(not (string? output))
          (fail! (string-append "could not run on " (request-filter request)))]
         [tail (status! (string-append (request-filter request) ": " tail))]
         [else (status! (string-append (request-filter request) " printed nothing"))])))))

;; Run a test folder and report PlatformIO's summary. The folder is named
;; in the status because the run is not confined to the test at the cursor.
(define (run-pio! request)
  (start-job!
   (string-append "running " (request-get request 'folder))
   "pio"
   (request-root request)
   (pio-run-arguments (request-get request 'environment) (request-get request 'folder))
   (lambda (output)
     (let ([outcome (if (string? output) (pio-outcome output) #f)])
       (if outcome
           (status! (string-append (request-get request 'folder) ": " outcome))
           (fail! (string-append (request-get request 'folder)
                                 " printed no summary; the build probably failed")))))))

;; Last non-blank line of some output, or #f.
(define (last-line text)
  (let loop ([lines (source-lines text)] [found #f])
    (if (empty? lines)
        found
        (loop (cdr lines)
              (if (equal? (trim (car lines)) "") found (trim (car lines)))))))

(define (run-binary! request)
  (start-job!
   (string-append "running " (request-filter request))
   "cargo"
   (request-root request)
   (binary-run-arguments (request-get request 'relative-path))
   (lambda (output)
     (let ([tail (if (string? output) (last-line output) #f)])
       (cond
         [(not (string? output))
          (fail! (string-append "could not run " (request-filter request)))]
         [(panic-location output)
          (let ([location (panic-location output)])
            (fail! (string-append (request-filter request)
                                  " panicked at "
                                  (car location)
                                  ":"
                                  (number->string (car (cdr location)))
                                  "; test-debug-failure stops there")))]
         [tail (status! (string-append (request-filter request) ": " tail))]
         [else (status! (string-append (request-filter request) " printed nothing"))])))))

;; Write the buffer before building, so cargo compiles the code on screen.
;; An unsaved edit otherwise shifts every line the breakpoint was computed
;; from.
(define (save-if-dirty!)
  (when (editor-document-dirty? (editor->doc-id (editor-focus)))
    (helix.write)
    (status! (dirty-buffer-warning (base-name (focused-path))))))

(define (with-request! act!)
  (if (job-running?)
      (fail! (string-append "already " *job-label*))
      (let ([request (request-at-cursor)])
        (if (string? request)
            (fail! request)
            (begin (save-if-dirty!) (act! request))))))

;;@doc
;; Debug the line under the cursor. In a test, builds its cargo test target
;; and stops on the test's first line; anywhere else, builds the crate's
;; binary and stops on the cursor itself.
(define (debug-here)
  (with-request! debug-request!))

;;@doc
;; Alias for debug-here.
(define (dbgh)
  (debug-here))

;;@doc
;; Run the line under the cursor without a debugger: a test and its result,
;; or the crate's binary and its last line of output.
(define (run-here)
  (with-request! run-request!))

;;@doc
;; Debug whatever debug-here or run-here last resolved, from any buffer.
(define (debug-again)
  (cond [(job-running?) (fail! (string-append "already " *job-label*))]
        [*last-request* (debug-request! *last-request*)]
        [else (fail! "nothing debugged yet")]))

;; Every test in the crate, read from its sources. Discovery walks the tree
;; rather than asking cargo: a libtest binary can list its tests, but only
;; once it is built, and the source carries the line to stop on that
;; `--list` does not.
(define (crate-tests root)
  (let walk ([queue (list "")] [found '()])
    (if (empty? queue)
        found
        (let* ([relative (car queue)]
               [absolute (if (equal? relative "") root (join-path root relative))]
               [children (directory-children absolute relative)])
          (walk (append (cdr queue) (car children))
                (append found (tests-of-files root (car (cdr children)))))))))

;; Subdirectories worth descending into and files worth parsing, both as
;; paths relative to the crate root. A directory cargo does not compile is
;; never opened, which is what keeps target/ from being walked.
(define (directory-children absolute relative)
  (let loop ([entries (safe-read-dir absolute)] [directories '()] [files '()])
    (if (empty? entries)
        (list (reverse directories) (reverse files))
        (let* ([entry (car entries)]
               [name (base-name entry)]
               [path (if (equal? relative "") name (string-append relative "/" name))])
          (cond [(is-dir? entry)
                 (loop (cdr entries)
                       (if (walkable? path) (cons path directories) directories)
                       files)]
                [(compiled-source? path) (loop (cdr entries) directories (cons path files))]
                [else (loop (cdr entries) directories files)])))))

;; A directory is walked when it could still lead to compiled sources: a
;; top-level one cargo compiles, or anything beneath one.
(define (walkable? path)
  (or (member? path '("src" "tests" "benches"))
      (compiled-source? (string-append path "/lib.rs"))))

(define (safe-read-dir path)
  (call-with-exception-handler (lambda (failure) '())
                               (lambda () (read-dir path))))

(define (tests-of-files root paths)
  (let loop ([remaining paths] [found '()])
    (if (empty? remaining)
        found
        (let ([text (file-contents (join-path root (car remaining)))])
          (loop (cdr remaining)
                (if (string? text)
                    (append found (tests-in-file (car remaining) (source-lines text)))
                    found))))))

;; Debug a test that was picked rather than pointed at. Everything the
;; launch needs is in the entry, so no cursor is consulted.
(define (debug-discovered! root entry)
  (debug-request! (hash 'language 'rust
                        'root root
                        'relative-path (discovered-path entry)
                        'file (base-name (discovered-path entry))
                        'filter (discovered-name entry)
                        'line (discovered-line entry))))

;; Every Unity test in a PlatformIO project, folder by folder. Each folder
;; is its own program, so a picked test carries the folder it belongs to.
(define (pio-tests root)
  (let ([test-root (join-path root "test")])
    (let loop ([folders (safe-read-dir test-root)] [found '()])
      (if (empty? folders)
          found
          (let ([folder (car folders)])
            (loop (cdr folders)
                  (if (is-dir? folder)
                      (append found (folder-tests root (base-name folder)))
                      found)))))))

;; The tests one folder defines. Registrations are gathered across the
;; folder first, because the runner naming them is conventionally a
;; different file from the one defining them.
(define (folder-tests root folder)
  (let* ([directory (join-path (join-path root "test") folder)]
         [registrations (folder-registrations directory)])
    (let loop ([entries (safe-read-dir directory)] [found '()])
      (if (empty? entries)
          found
          (let* ([entry (car entries)]
                 [text (if (is-dir? entry) #f (file-contents entry))])
            (loop (cdr entries)
                  (if (string? text)
                      (append found
                              (unity-tests-in-file (path-within root entry)
                                                   (source-lines text)
                                                   registrations))
                      found)))))))

;; Debug a Unity test that was picked rather than pointed at. The folder
;; comes back out of the entry's path and the environment from the
;; manifest, so nothing has to be remembered between the pick and the
;; launch.
(define (debug-picked-unity! root entry)
  (let ([environment (pio-environment (or (file-contents (join-path root "platformio.ini")) ""))]
        [folder (pio-test-folder (discovered-path entry))])
    (if (not (and environment folder))
        (fail! (string-append "cannot resolve a PlatformIO program for "
                              (discovered-name entry)))
        (debug-request! (hash 'language 'cpp
                              'kind 'unity
                              'root root
                              'file (base-name (discovered-path entry))
                              'filter (discovered-name entry)
                              'line (discovered-line entry)
                              'environment environment
                              'folder folder
                              'executable (join-path root (pio-program-path environment)))))))

;;@doc
;; Pick a test from anywhere in the project and debug it. Type to filter,
;; up and down to move, enter to debug, escape to dismiss.
(define (test-pick)
  (let* ([path (focused-path)]
         [pio (if (string? path) (pio-root path path-exists?) #f)])
    (cond
      [(not (string? path)) (fail! "this buffer has no file on disk")]
      [(job-running?) (fail! (string-append "already " *job-label*))]
      [pio
       (let ([entries (pio-tests pio)])
         (if (empty? entries)
             (fail! (string-append "nothing under " pio " calls RUN_TEST"))
             (pick-test! entries (lambda (entry) (debug-picked-unity! pio entry)))))]
      [(not (equal? (language-for path) 'rust))
       (fail! "picking a test needs a cargo crate or a PlatformIO project")]
      [else
       (let ([root (crate-root path path-exists?)])
         (if (not root)
             (fail! (string-append "no Cargo.toml above " (base-name path)))
             (let ([entries (crate-tests root)])
               (if (empty? entries)
                   (fail! (string-append "no tests found under " root))
                   (pick-test! entries
                               (lambda (entry) (debug-discovered! root entry)))))))])))

;; Run the test, and when it fails debug it stopped where it panicked. The
;; panic path is reduced to a base name because that is what the adapter
;; resolves against the binary's debug info. Rust only: it reads libtest's
;; panic line.
(define (debug-failure! request)
  (cond
    [(equal? (request-get request 'language) 'cpp)
     (fail! "debugging a failure is rust only so far; use test-debug")]
    ;; A binary has no libtest summary, so a panic line is the whole
    ;; signal: it panicked or it did not.
    [(equal? (request-get request 'kind) 'binary)
     (start-job!
      (string-append "running " (request-filter request))
      "cargo"
      (request-root request)
      (binary-run-arguments (request-get request 'relative-path))
      (lambda (output)
        (let ([location (if (string? output) (panic-location output) #f)])
          (cond
            [(not (string? output))
             (fail! (string-append "could not run " (request-filter request)))]
            [(not location)
             (status! (string-append (request-filter request)
                                     " did not panic, nothing to debug"))]
            [else
             (build-then! request
                          (lambda (binary)
                            (launch! request
                                     binary
                                     (base-name (car location))
                                     (car (cdr location)))))]))))]
    [else
     (start-job!
      (string-append "running " (request-filter request))
      "cargo"
      (request-root request)
      (run-arguments (request-get request 'relative-path) (request-filter request))
      (lambda (output)
        (let ([outcome (if (string? output) (test-outcome output) #f)]
              [location (if (string? output) (panic-location output) #f)])
          (cond
            [(not (outcome-failed? outcome))
             (status! (string-append (request-filter request)
                                     " passed, nothing to debug: "
                                     (if outcome outcome "no result")))]
            [(not location)
             (fail! (string-append (request-filter request)
                                   " failed but printed no panic location"))]
            [else
             (build-then! request
                          (lambda (binary)
                            (launch! request
                                     binary
                                     (base-name (car location))
                                     (car (cdr location)))))]))))]))

;;@doc
;; Run the test under the cursor and, if it fails, debug it stopped at the
;; line that panicked.
(define (debug-failure)
  (with-request! debug-failure!))

;;@doc
;; Stop waiting on the build in flight. Cargo keeps running; only the wait
;; is abandoned.
(define (debug-cancel)
  (if (job-running?)
      (begin
        (set! *job-label* #f)
        (status! "stopped waiting"))
      (status! "nothing in flight")))

;; Rebuild the variables popup. Helix installs it under a fixed layer id,
;; so this replaces the stale one rather than stacking another.
(define (refresh-variables!)
  (when *watching-variables*
    (enqueue-thread-local-callback-with-delay *refresh-delay-ms* dap_variables)))

;; Step, then rebuild the popup once the adapter has reported the new stop
;; location.
(define (step-then-refresh! step!)
  (step!)
  (refresh-variables!))

;;@doc
;; Show the variables popup and keep it fresh as you step. Helix builds it
;; from a snapshot that never updates; call this again to stop refreshing.
(define (debug-variables)
  (set! *watching-variables* (not *watching-variables*))
  (dap_variables)
  (status! (if *watching-variables*
               "variables follow each step"
               "variables no longer refresh")))

;;@doc
;; Step over, refreshing the variables popup.
(define (debug-step-over)
  (step-then-refresh! dap_next))

;;@doc
;; Step into, refreshing the variables popup.
(define (debug-step-in)
  (step-then-refresh! dap_step_in))

;;@doc
;; Step out, refreshing the variables popup.
(define (debug-step-out)
  (step-then-refresh! dap_step_out))

;;@doc
;; Continue, refreshing the variables popup at the next stop.
(define (debug-continue)
  (step-then-refresh! dap_continue))

;; Where a workspace's breakpoints live. Helix already keeps per-workspace
;; configuration in .helix/, so this sits beside it rather than inventing a
;; second convention or a state directory keyed on a hashed path.
(define *breakpoint-directory* ".helix")
(define *breakpoint-file* "test-debug-breakpoints")

;; Workspaces whose breakpoints have been replayed into helix this session,
;; so a second launch does not walk the files again.
(define *restored* '())

;; The workspace a path belongs to, whichever language it is, or #f.
(define (workspace-root path)
  (let ([crate (crate-root path path-exists?)])
    (if crate crate (project-root path path-exists?))))

(define (breakpoint-store root)
  (join-path (join-path root *breakpoint-directory*) *breakpoint-file*))

;; Breakpoints recorded for a workspace. A missing or corrupt file reads as
;; none: losing breakpoints is a nuisance, refusing to debug is worse.
(define (stored-breakpoints root)
  (let ([text (file-contents (breakpoint-store root))])
    (if (string? text) (text->breakpoints text) '())))

;; The budget a workspace declares, or #f. It is a property of the target
;; rather than of the cog: an RP2040 has four breakpoint comparators per
;; core and probe-rs programs them directly, so the fifth breakpoint fails
;; the session instead of degrading.
(define (stored-budget root)
  (let ([text (file-contents (breakpoint-store root))])
    (if (string? text) (breakpoint-budget text) #f)))

;; Write the list back, creating .helix/ when it is the first breakpoint in
;; a workspace, and preserving the budget the file declares. Returns
;; whether it was written.
(define (store-breakpoints! root breakpoints)
  (call-with-exception-handler
   (lambda (failure) #f)
   (lambda ()
     (let ([directory (join-path root *breakpoint-directory*)]
           [budget (stored-budget root)])
       (when (not (path-exists? directory))
         (create-directory! directory))
       (call-with-output-file (breakpoint-store root)
                              (lambda (port)
                                (display (breakpoints->text breakpoints budget) port)))
       #t))))

(define (breakpoint-count-message count)
  (string-append (number->string count)
                 (if (equal? count 1) " breakpoint" " breakpoints")))

;;@doc
;; Toggle a breakpoint on the current line and remember it for this
;; workspace, so it is still there next time the editor starts.
(define (debug-breakpoint)
  (let ([path (focused-path)])
    (if (not (string? path))
        (fail! "this buffer has no file on disk")
        (let ([root (workspace-root path)]
              [line (+ (get-current-line-number) 1)])
          (dap_toggle_breakpoint)
          (if (not root)
              (status! (string-append "breakpoint set, but not remembered: no workspace above "
                                      (base-name path)))
              (let* ([relative (path-within root path)]
                     [before (stored-breakpoints root)]
                     [toggled (toggle-breakpoint before relative line)]
                     [added (> (length toggled) (length before))])
                (if (store-breakpoints! root toggled)
                    (status! (string-append (if added "remembered " "forgot ")
                                            relative
                                            ":"
                                            (number->string line)
                                            ", "
                                            (breakpoint-count-message (length toggled))
                                            " in this workspace"))
                    (fail! (string-append "could not write " (breakpoint-store root))))))))))

(define *remote-kinds* '(firmware pio-firmware cmake-firmware))

(define (remote-kind? kind)
  (member? kind *remote-kinds*))

;; The file the breakpoint goes in. A rust request carries a path relative
;; to the crate; the C and C++ ones carry only a base name, so the buffer's
;; own path is used.
(define (firmware-source request)
  (let ([relative (request-get request 'relative-path)])
    (if (string? relative)
        (join-path (request-root request) relative)
        (or (focused-path) (request-file request)))))

;; Place a breakpoint in helix at an absolute file and one-based line.
;; Helix can only toggle at the cursor, so the line has to be visited. A
;; breakpoint already there is toggled back off; nothing exposes what helix
;; holds, so that cannot be checked first.
(define (place-breakpoint! file line)
  (when (path-exists? file)
    (helix.open file)
    (helix.goto-line line)
    (dap_toggle_breakpoint)))

;; Replay one breakpoint: helix only toggles at the cursor, so each file is
;; opened and visited in turn.
(define (replay-breakpoint! root breakpoint)
  (let ([file (join-path root (car breakpoint))])
    (when (path-exists? file)
      (helix.open file)
      (helix.goto-line (car (cdr breakpoint)))
      (dap_toggle_breakpoint))))

;; Replay the stored breakpoints the budget allows, then return to where
;; the cursor was. Returns how many were placed, and how many were stored,
;; so the caller can say what it dropped.
(define (replay-breakpoints! root)
  (let* ([stored (stored-breakpoints root)]
         [placing (within-budget stored (stored-budget root))]
         [was (focused-path)]
         [line (+ (get-current-line-number) 1)])
    (for-each (lambda (breakpoint) (replay-breakpoint! root breakpoint)) placing)
    (when (string? was)
      (helix.open was)
      (helix.goto-line line))
    (list (length placing) (length stored))))

;; What to say after placing: the count, plus what the budget dropped. A
;; report that always fires would be noise, so the pure half returns #f
;; when there is nothing to add.
(define (placement-message root placement)
  (let* ([placed (car placement)]
         [total (car (cdr placement))]
         [dropped (budget-report placed total (stored-budget root))])
    (if dropped
        dropped
        (string-append "restored " (breakpoint-count-message placed)))))

;; Place a workspace's breakpoints once per session, before the first
;; launch. Helix sends the breakpoints it holds when a session starts, so
;; this has to happen before the adapter is asked to launch, not after.
(define (restore-breakpoints! root)
  (when (and root (not (member? root *restored*)))
    (set! *restored* (cons root *restored*))
    (let ([placement (replay-breakpoints! root)])
      (when (> (car (cdr placement)) 0)
        (status! (placement-message root placement))))))

;;@doc
;; Place this workspace's remembered breakpoints in the editor, opening
;; each file they are in and returning to where you were.
(define (debug-breakpoints)
  (let ([path (focused-path)])
    (if (not (string? path))
        (fail! "this buffer has no file on disk")
        (let ([root (workspace-root path)])
          (cond
            [(not root) (fail! (string-append "no workspace above " (base-name path)))]
            [(empty? (stored-breakpoints root))
             (status! (string-append "no breakpoints remembered in " root))]
            [else
             (set! *restored* (cons root *restored*))
             ;; The status comes after the replay: opening each file paints
             ;; over whatever was on the line before.
             (let ([placement (replay-breakpoints! root)])
               (status! (string-append (placement-message root placement) " in " root)))])))))

;;@doc
;; Forget this workspace's remembered breakpoints. Breakpoints already in
;; the editor stay where they are.
(define (debug-breakpoints-clear)
  (let ([path (focused-path)])
    (if (not (string? path))
        (fail! "this buffer has no file on disk")
        (let ([root (workspace-root path)])
          (cond
            [(not root) (fail! (string-append "no workspace above " (base-name path)))]
            [(store-breakpoints! root '())
             (status! (string-append "forgot every breakpoint in " root))]
            [else (fail! (string-append "could not write " (breakpoint-store root)))])))))

;; Contents of a file, or #f when it cannot be read.
(define (file-contents path)
  (if (path-exists? path)
      (call-with-exception-handler (lambda (failure) #f)
                                   (lambda () (call-with-input-file path read-port-to-string)))
      #f))

;; helix.scm sits in the configuration directory, so languages.toml is its
;; sibling. There is no accessor for the directory itself.
(define (languages-toml)
  (file-contents (join-path (parent-directory (get-helix-scm-path)) "languages.toml")))

(define (adapter-check configured)
  (cond [(not configured)
         (check "adapter" #f "languages.toml configures no debugger command for rust")]
        [(which configured)
         (check "adapter" #t "")]
        [else (check "adapter" #f (string-append configured " is not on PATH"))]))

(define (configuration-checks text)
  (if (not text)
      (list (check "languages.toml" #f "not found beside helix.scm; see the README"))
      (list (check "template"
                   (template-present? text *cargo-template*)
                   (string-append "no \"" *cargo-template* "\" template; see the README"))
            (check "program template"
                   (template-present? text *program-template*)
                   (string-append "no \""
                                  *program-template*
                                  "\" template, so only tests can be debugged; see the README"))
            (adapter-check (debugger-command text)))))

(define (cursor-checks)
  (let ([request (request-at-cursor)])
    (list (check "cursor" (not (string? request)) (if (string? request) request "")))))

;;@doc
;; Report whether everything test-debug needs is in place, and what to fix.
(define (debug-doctor)
  (let ([checks (append (list (check "cargo" (if (which "cargo") #t #f) "cargo is not on PATH"))
                        (configuration-checks (languages-toml))
                        (cursor-checks))])
    (if (diagnosis-ok? checks)
        (status! (diagnosis checks))
        (fail! (diagnosis checks)))))
