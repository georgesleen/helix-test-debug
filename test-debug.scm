;; helix-test-debug: debug the test under the cursor, for Helix with the
;; Steel plugin system (github:mattwparas/helix, branch
;; steel-event-system).
;;
;; Copyright (C) 2026 George Sleen
;;
;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Lesser General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
;; General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.
;;
;; Editor half: reads the cursor, builds the test target off the editor
;; thread, and starts a debug session on the result. The decisions all live
;; in test-debug-rust.scm, which is pure and carries the tests.

(require (prefix-in helix. "helix/commands.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/ext.scm")
;; get-current-line-number lives with the static commands, not in misc.
(require (only-in "helix/static.scm" get-current-line-number))
(require-builtin helix/core/text as text.)
(require-builtin steel/process)
(require-builtin steel/strings)
(require "test-debug-rust.scm")

(provide debug-test)

;; Debugger template this cog drives. It takes the binary, the test filter,
;; the source file and the line to stop on; see README.md for the languages
;; configuration it expects.
(define *template* "cargo test at line")

(define (status! message)
  (set-status! (string-append "debug-test: " message)))

(define (fail! message)
  (set-error! (string-append "debug-test: " message)))

(define (focused-path)
  (editor-document->path (editor->doc-id (editor-focus))))

(define (focused-text)
  (text.rope->string (editor->text (editor->doc-id (editor-focus)))))

;; stdout of a command run in a directory, or #f when it could not be run.
;; A command that runs and fails yields its output, which for cargo means
;; an empty string.
(define (captured-output program arguments directory)
  (let ([spawned (spawn-process
                  (with-stdout-piped
                   (with-current-dir (command program arguments) directory)))])
    (if (Err? spawned)
        #f
        (let ([finished (wait->stdout (Ok->value spawned))])
          (if (Err? finished) #f (Ok->value finished))))))

;; Hand the built binary to helix's debugger. Runs on the editor thread.
(define (launch! binary test path line)
  (helix.debug-start *template*
                     binary
                     (test-name test)
                     (base-name path)
                     (number->string line))
  (status! (string-append (test-name test) " at " (base-name path) ":" (number->string line))))

(define (report-build-failure! test root arguments)
  (fail! (string-append "cargo built no test binary for "
                        (test-name test)
                        "; run `cargo "
                        (string-join arguments " ")
                        "` in "
                        root
                        " to see why")))

;; Build the target off the editor thread, then come back to launch. The
;; build blocks whichever thread it runs on, so it must not be this one.
;; Ends on a status call so the command yields void: a typed command's
;; return value is stringified onto the statusline, and `void` is a value
;; rather than a procedure here, so it cannot be called for one.
(define (build-and-launch! path root test)
  (define arguments (build-arguments (path-within root path)))
  (define line (breakpoint-line (test-declaration-line test)))
  (spawn-native-thread
   (lambda ()
     (let ([output (captured-output "cargo" arguments root)])
       (hx.block-on-task
        (lambda ()
          (let ([binary (if (string? output) (executable-from-cargo-output output) #f)])
            (if binary
                (launch! binary test path line)
                (report-build-failure! test root arguments))))))))
  (status! (string-append "building " (test-name test))))

;;@doc
;; Debug the test under the cursor. Builds its cargo test target, then
;; starts a debug session stopped on the test's first line.
(define (debug-test)
  (let ([path (focused-path)])
    (if (not (string? path))
        (fail! "this buffer has no file on disk")
        (let ([test (test-at-line (source-lines (focused-text)) (get-current-line-number))]
              [root (crate-root path path-exists?)])
          (cond [(not test) (fail! "no test function at the cursor")]
                [(not root) (fail! "no Cargo.toml above this file")]
                [else (build-and-launch! path root test)])))))
