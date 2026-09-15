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
                  project-root))

(provide test-debug
         test-run
         test-again
         test-pick
         test-doctor
         test-debug-failure
         test-cancel
         debug-breakpoint
         debug-breakpoints
         debug-breakpoints-clear
         debug-variables
         debug-step-over
         debug-step-in
         debug-step-out
         debug-continue)

;; Debugger template this cog drives, taking the binary, the test filter,
;; the source file and the line to stop on. README.md carries the
;; languages.toml it expects.
(define *cargo-template* "cargo test at line")

;; Template for a binary ctest already named, which needs no filter flag
;; because ctest reported the argument that selects the test.
(define *binary-template* "binary at line")

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

;; Resolve the cursor in a rust buffer, or a string saying why not.
(define (rust-request path lines line)
  (let ([test (test-at-line lines line)]
        [root (crate-root path path-exists?)]
        [found (declaration-name-at lines line)])
    (cond
      [(not root) (string-append "no Cargo.toml above " (base-name path))]
      [test
       (let ([relative-path (path-within root path)])
         (hash 'language 'rust
               'root root
               'relative-path relative-path
               'file (base-name path)
               'filter (qualified-test-name relative-path lines test)
               'line (breakpoint-line (test-declaration-line test))))]
      [found (string-append found " is not a test; it has no #[test] attribute")]
      [else "no function at or above the cursor"])))

;; Resolve the cursor in a C or C++ buffer. The candidate from the cursor is
;; matched against what ctest registered, so a parameterized test resolves
;; to its generated siblings rather than failing.
(define (cpp-request path lines line)
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
  (if (equal? (request-get request 'language) 'cpp)
      (helix.debug-start *binary-template*
                         binary
                         (car (request-get request 'arguments))
                         file
                         (number->string line))
      (helix.debug-start *cargo-template*
                         binary
                         (request-filter request)
                         file
                         (number->string line)))
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
;; at-binary!, which decides where to stop.
(define (build-rust-then! request at-binary!)
  (let ([arguments (build-arguments (request-get request 'relative-path))])
    (start-job!
     (string-append "building " (request-filter request))
     "cargo"
     (request-root request)
     arguments
     (lambda (output)
       (let ([binary (if (string? output) (executable-from-cargo-output output) #f)])
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

(define (build-then! request at-binary!)
  (set! *last-request* request)
  (if (equal? (request-get request 'language) 'cpp)
      (build-cpp-then! request at-binary!)
      (build-rust-then! request at-binary!)))

(define (debug-request! request)
  (build-then! request
               (lambda (binary)
                 (launch! request binary (request-file request) (request-line request)))))

(define (run-request! request)
  (set! *last-request* request)
  (if (equal? (request-get request 'language) 'cpp)
      (fail! "running without a debugger is rust only so far; use test-debug")
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
                                     " printed no result; the build probably failed"))))))))

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
;; Debug the test under the cursor. Builds its cargo test target, then
;; starts a debug session stopped on the test's first line.
(define (test-debug)
  (with-request! debug-request!))

;;@doc
;; Run the test under the cursor without a debugger and report its result.
(define (test-run)
  (with-request! run-request!))

;;@doc
;; Debug the test from the last test-debug or test-run again, from any
;; buffer.
(define (test-again)
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

;;@doc
;; Pick a test from anywhere in the crate and debug it. Type to filter,
;; up and down to move, enter to debug, escape to dismiss.
(define (test-pick)
  (let ([path (focused-path)])
    (cond
      [(not (string? path)) (fail! "this buffer has no file on disk")]
      [(job-running?) (fail! (string-append "already " *job-label*))]
      [(not (equal? (language-for path) 'rust))
       (fail! "picking a test is rust only so far; use test-debug")]
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
  (if (equal? (request-get request 'language) 'cpp)
      (fail! "debugging a failure is rust only so far; use test-debug")
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
                                      (car (cdr location)))))]))))))

;;@doc
;; Run the test under the cursor and, if it fails, debug it stopped at the
;; line that panicked.
(define (test-debug-failure)
  (with-request! debug-failure!))

;;@doc
;; Stop waiting on the build in flight. Cargo keeps running; only the wait
;; is abandoned.
(define (test-cancel)
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

;; Write the list back, creating .helix/ when it is the first breakpoint in
;; a workspace. Returns whether it was written.
(define (store-breakpoints! root breakpoints)
  (call-with-exception-handler
   (lambda (failure) #f)
   (lambda ()
     (let ([directory (join-path root *breakpoint-directory*)])
       (when (not (path-exists? directory))
         (create-directory! directory))
       (call-with-output-file (breakpoint-store root)
                              (lambda (port) (display (breakpoints->text breakpoints) port)))
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

;; Replay one breakpoint: helix only toggles at the cursor, so each file is
;; opened and visited in turn.
(define (replay-breakpoint! root breakpoint)
  (let ([file (join-path root (car breakpoint))])
    (when (path-exists? file)
      (helix.open file)
      (helix.goto-line (car (cdr breakpoint)))
      (dap_toggle_breakpoint))))

;; Replay every stored breakpoint, then return to where the cursor was.
;; Returns how many were placed.
(define (replay-breakpoints! root)
  (let ([breakpoints (stored-breakpoints root)]
        [was (focused-path)]
        [line (+ (get-current-line-number) 1)])
    (for-each (lambda (breakpoint) (replay-breakpoint! root breakpoint)) breakpoints)
    (when (string? was)
      (helix.open was)
      (helix.goto-line line))
    (length breakpoints)))

;; Place a workspace's breakpoints once per session, before the first
;; launch. Helix sends the breakpoints it holds when a session starts, so
;; this has to happen before the adapter is asked to launch, not after.
(define (restore-breakpoints! root)
  (when (and root (not (member? root *restored*)))
    (set! *restored* (cons root *restored*))
    (let ([placed (replay-breakpoints! root)])
      (when (> placed 0)
        (status! (string-append "restored " (breakpoint-count-message placed)))))))

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
             (let ([placed (replay-breakpoints! root)])
               (status! (string-append "restored "
                                       (breakpoint-count-message placed)
                                       " in "
                                       root)))])))))

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
            (adapter-check (debugger-command text)))))

(define (cursor-checks)
  (let ([request (request-at-cursor)])
    (list (check "cursor" (not (string? request)) (if (string? request) request "")))))

;;@doc
;; Report whether everything test-debug needs is in place, and what to fix.
(define (test-doctor)
  (let ([checks (append (list (check "cargo" (if (which "cargo") #t #f) "cargo is not on PATH"))
                        (configuration-checks (languages-toml))
                        (cursor-checks))])
    (if (diagnosis-ok? checks)
        (status! (diagnosis checks))
        (fail! (diagnosis checks)))))
