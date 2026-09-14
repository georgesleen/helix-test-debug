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
(require (only-in "helix/static.scm" get-current-line-number dap_terminate))
(require-builtin helix/core/text as text.)
(require-builtin steel/process)
(require-builtin steel/strings)
(require "test-debug-rust.scm")

(provide debug-test
         run-test
         debug-test-again)

;; Debugger template this cog drives, taking the binary, the test filter,
;; the source file and the line to stop on. README.md carries the
;; languages.toml it expects.
(define *template* "cargo test at line")

;; Cargo is polled from the editor thread this often, and abandoned after
;; this many polls.
(define *poll-interval-ms* 250)
(define *poll-limit* 1200)

;; Label of the job in flight, or #f when idle. Editor thread only.
(define *job* #f)

;; Last resolved request, so it can be repeated from another buffer.
(define *last-request* #f)

(define (status! message)
  (set-status! (string-append "test-debug: " message)))

(define (fail! message)
  (set-error! (string-append "test-debug: " message)))

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

;; Re-arming this timer is what wakes the editor. A callback queued from a
;; worker thread is drained only when the event loop wakes, so without a
;; timer the result would not land until the next keypress.
(define (pump! label ticks)
  (when (string? *job*)
    (if (> ticks *poll-limit*)
        (begin
          (set! *job* #f)
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
           (lambda () (pump! label (+ ticks 1))))))))

;; Run cargo on a worker thread; complete! runs on the editor thread with
;; cargo's stdout, or #f when it could not be run.
(define (start-job! label root arguments complete!)
  (set! *job* label)
  (status! label)
  (spawn-native-thread
   (lambda ()
     (let ([output (captured-output "cargo" arguments root)])
       (hx.block-on-task
        (lambda ()
          (set! *job* #f)
          (complete! output))))))
  (pump! label 1))

(define (launch! request binary)
  (terminate-existing!)
  (helix.debug-start *template*
                     binary
                     (request-filter request)
                     (request-file request)
                     (number->string (request-line request)))
  (status! (string-append (request-filter request)
                          " at "
                          (request-file request)
                          ":"
                          (number->string (request-line request)))))

(define (debug-request! request)
  (set! *last-request* request)
  (let ([arguments (build-arguments (request-relative-path request))])
    (start-job!
     (string-append "building " (request-filter request))
     (request-root request)
     arguments
     (lambda (output)
       (let ([binary (if (string? output) (executable-from-cargo-output output) #f)])
         (if binary
             (launch! request binary)
             (fail! (string-append "no test binary built; run `cargo "
                                   (string-join arguments " ")
                                   "` in "
                                   (request-root request)
                                   " to see why"))))))))

;; Last line of cargo's test summary, which is the part worth reading.
(define (test-outcome output)
  (let loop ([lines (source-lines output)] [outcome #f])
    (cond [(empty? lines) outcome]
          [(starts-with? (trim (car lines)) "test result:") (loop (cdr lines) (trim (car lines)))]
          [else (loop (cdr lines) outcome)])))

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

(define (with-request! act!)
  (if (string? *job*)
      (fail! (string-append "already " *job*))
      (let ([request (request-at-cursor)])
        (if (string? request) (fail! request) (act! request)))))

;;@doc
;; Debug the test under the cursor. Builds its cargo test target, then
;; starts a debug session stopped on the test's first line.
(define (debug-test)
  (with-request! debug-request!))

;;@doc
;; Run the test under the cursor without a debugger and report its result.
(define (run-test)
  (with-request! run-request!))

;;@doc
;; Debug the test from the last debug-test or run-test again, from any
;; buffer.
(define (debug-test-again)
  (cond [(string? *job*) (fail! (string-append "already " *job*))]
        [*last-request* (debug-request! *last-request*)]
        [else (fail! "nothing debugged yet")]))
