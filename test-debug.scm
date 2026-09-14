;; helix-test-debug: debug or run the test under the cursor, for Helix with
;; the Steel plugin system (github:mattwparas/helix, branch
;; steel-event-system).
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later
;;
;; Editor half: reads the cursor, builds off the editor thread, and starts
;; the session. Every decision lives in test-debug-rust.scm, which is pure
;; and carries the tests.

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
                  dap_next
                  dap_step_in
                  dap_step_out
                  dap_continue))
(require-builtin helix/core/text as text.)
(require-builtin steel/process)
(require-builtin steel/strings)
(require "test-debug-rust.scm")

(provide test-debug
         test-run
         test-again
         test-doctor
         test-debug-failure
         test-cancel
         debug-variables
         debug-step-over
         debug-step-in
         debug-step-out
         debug-continue)

;; Debugger template this cog drives, taking the binary, the test filter,
;; the source file and the line to stop on. README.md carries the
;; languages.toml it expects.
(define *template* "cargo test at line")

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

;; A request is everything needed to build and launch, resolved from the
;; cursor before any work starts.
(define (make-request root relative-path file filter line)
  (list root relative-path file filter line))

(define (request-root request) (list-ref request 0))
(define (request-relative-path request) (list-ref request 1))
(define (request-file request) (list-ref request 2))
(define (request-filter request) (list-ref request 3))
(define (request-line request) (list-ref request 4))

;; Resolve the cursor into a request, or a string saying why not. The
;; message names what was found, because "no test here" leaves you guessing
;; whether to move the cursor or add an attribute.
(define (request-at-cursor)
  (let ([path (focused-path)])
    (if (not (string? path))
        "this buffer has no file on disk"
        (let* ([lines (source-lines (focused-text))]
               [line (get-current-line-number)]
               [test (test-at-line lines line)]
               [root (crate-root path path-exists?)]
               [found (declaration-name-at lines line)])
          (cond
            [(not root) (string-append "no Cargo.toml above " (base-name path))]
            [test
             (let ([relative-path (path-within root path)])
               (make-request root
                             relative-path
                             (base-name path)
                             (qualified-test-name relative-path lines test)
                             (breakpoint-line (test-declaration-line test))))]
            [found (string-append found " is not a test; it has no #[test] attribute")]
            [else "no function at or above the cursor"])))))

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
          (fail! (string-append "gave up waiting for cargo after "
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

;; Run cargo on a worker thread; complete! runs on the editor thread with
;; cargo's stdout, or #f when it could not be run.
(define (start-job! label root arguments complete!)
  (set! *job-label* label)
  (status! label)
  (spawn-native-thread
   (lambda ()
     (let ([output (captured-output "cargo" arguments root)])
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
  (helix.debug-start *template* binary (request-filter request) file (number->string line))
  (status! (string-append (request-filter request)
                          " at "
                          file
                          ":"
                          (number->string line))))

(define (report-build-failure! request arguments)
  (fail! (string-append "no test binary built; run `cargo "
                        (string-join arguments " ")
                        "` in "
                        (request-root request)
                        " to see why")))

;; Build, then hand the binary to at-binary!, which decides where to stop.
(define (build-then! request at-binary!)
  (set! *last-request* request)
  (let ([arguments (build-arguments (request-relative-path request))])
    (start-job!
     (string-append "building " (request-filter request))
     (request-root request)
     arguments
     (lambda (output)
       (let ([binary (if (string? output) (executable-from-cargo-output output) #f)])
         (if binary
             (at-binary! binary)
             (report-build-failure! request arguments)))))))

(define (debug-request! request)
  (build-then! request
               (lambda (binary)
                 (launch! request binary (request-file request) (request-line request)))))

(define (run-request! request)
  (set! *last-request* request)
  (start-job!
   (string-append "running " (request-filter request))
   (request-root request)
   (run-arguments (request-relative-path request) (request-filter request))
   (lambda (output)
     (let ([outcome (if (string? output) (test-outcome output) #f)])
       (if outcome
           (status! (string-append (request-filter request) ": " outcome))
           (fail! (string-append (request-filter request)
                                 " printed no result; the build probably failed")))))))

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

;; Run the test, and when it fails debug it stopped where it panicked. The
;; panic path is reduced to a base name because that is what the adapter
;; resolves against the binary's debug info.
(define (debug-failure! request)
  (start-job!
   (string-append "running " (request-filter request))
   (request-root request)
   (run-arguments (request-relative-path request) (request-filter request))
   (lambda (output)
     (let* ([outcome (if (string? output) (test-outcome output) #f)]
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
                                  (car (cdr location)))))])))))

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
                   (template-present? text *template*)
                   (string-append "no \"" *template* "\" template; see the README"))
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
