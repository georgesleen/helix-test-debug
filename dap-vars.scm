;; dap-vars: a live variables panel for Helix, as a vertical split.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later
;;
;; This file is standalone. It requires nothing from the rest of this repo
;; and knows nothing about which debug adapter is running: everything it
;; shows comes from a plain text file written by `helix-dap-vars`, the
;; proxy in dap-vars/, which sits between helix and any DAP adapter and
;; rewrites that file on every stop.
;;
;;   (require "cogs/dap-vars.scm")
;;   ;; then bind :dap-variables to a key
;;
;; Helix's own `dap_variables` builds a popup from a snapshot and never
;; updates it, and Steel is given no access to scopes, variables or frames,
;; so nothing here could be done in the editor alone. A file can be opened
;; by the editor, reloaded by the editor, and written by somebody who does
;; have the data -- which is the whole design.

(require (prefix-in helix. "helix/commands.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")
(require-builtin steel/strings)
(require-builtin steel/filesystem)

(provide dap-variables
         dap-variables-on
         dap-variables-off
         dap-variables-path!)

;; How often the file is checked. Fast while a session is live, because
;; this is the panel's whole latency after a step; slow while waiting for
;; one, because then it is only a directory listing.
(define *tick-live-ms* 150)
(define *tick-idle-ms* 500)

;; What the proxy leaves in the temporary directory: one directory per
;; user, one file per proxy, named after its pid. The suffix is `.log`
;; rather than `.txt` so helix gives the panel log highlighting from its
;; file type, which needs no language command and no patched editor.
(define *directory-prefix* "helix-dap-vars-")
(define *file-suffix* ".log")

;; Whether the panel is wanted at all. Everything else is derived.
(define *enabled* #f)

;; A path set by hand with dap-variables-path!, for somebody who ran the
;; proxy with --out. #f means discover it.
(define *pinned-path* #f)

;; The file the open panel is showing, or #f when no panel is open.
(define *path* #f)

;; The panel's document, or #f. Held so the panel can be reloaded and
;; closed without the user's focus ever moving.
(define *doc-id* #f)

;; First line of the file as last seen. It carries a counter the proxy
;; increments once per stop, so it differs after every stop even when the
;; variables happen to render identically.
(define *token* #f)

;; Whether a tick is already scheduled, so a second toggle cannot start a
;; second loop.
(define *polling* #f)

;;@doc
;; Toggle the debugger variables panel
(define (dap-variables)
  (if *enabled* (dap-variables-off) (dap-variables-on)))

;;@doc
;; Show the debugger variables panel
(define (dap-variables-on)
  (set! *enabled* #t)
  (if *polling*
      void
      (begin
        (set! *polling* #t)
        (tick)))
  (set-status! "variables: following the debug session"))

;;@doc
;; Hide the debugger variables panel
(define (dap-variables-off)
  (set! *enabled* #f)
  (close-panel!)
  (set-status! "variables: panel off"))

;;@doc
;; Follow an explicit variables file, for a proxy started with --out
(define (dap-variables-path! path)
  (set! *pinned-path* (if (string? path) path #f))
  (close-panel!)
  (set-status! (if (string? path)
                   (string-append "variables: following " path)
                   "variables: discovering the file again")))

;; ------------------------------------------------------------ the loop

;; One pass. Re-enqueues itself until the panel is switched off, which is
;; the only way to run periodic work on the editor thread.
(define (tick)
  (if (not *enabled*)
      (begin
        (set! *polling* #f)
        void)
      (begin
        (if (closed-by-hand?)
            ;; The user closed the split. Treat that as the off switch
            ;; rather than reopening it under them; the next toggle brings
            ;; it back.
            (begin
              (set! *enabled* #f)
              (forget-panel!))
            (let ([path (live-file)])
              (cond
                ;; No file: either no session yet, or the one there ended.
                [(not (string? path)) (close-panel!)]
                ;; A different session than the panel is showing.
                [(not (equal? path *path*))
                 (close-panel!)
                 (open-panel! path)]
                [else (refresh!)])))
        (if *enabled*
            (enqueue-thread-local-callback-with-delay
             (if (string? *path*) *tick-live-ms* *tick-idle-ms*)
             tick)
            (set! *polling* #f)))))

;; ------------------------------------------------------------ the panel

(define (open-panel! path)
  (let ([saved (editor-focus)])
    (helix.vsplit path)
    (set! *path* path)
    (set! *doc-id* (editor->doc-id (editor-focus)))
    (set! *token* (file-token path))
    ;; The panel's language comes from its `.log` file type, so nothing
    ;; here has to ask for one.
    ;; The panel never takes focus, on open or on refresh: it is something
    ;; to glance at while stepping, and stealing the cursor would make
    ;; stepping unusable.
    (editor-set-focus! saved)))

;; Close the panel if it is open, then forget it. Safe to call when no
;; panel exists, which is why every path out goes through here.
(define (close-panel!)
  (let ([view (and *doc-id* (editor-doc-in-view? *doc-id*))])
    (when view
      (if (panel-focused?)
          ;; Already standing in it; helix picks the next view itself.
          (helix.buffer-close)
          (let ([saved (editor-focus)])
            (editor-set-focus! view)
            (helix.buffer-close)
            (editor-set-focus! saved)))))
  (forget-panel!))

(define (forget-panel!)
  (set! *path* #f)
  (set! *doc-id* #f)
  (set! *token* #f))

;; The panel's document exists but no view shows it: the user closed the
;; split. This has to be checked before anything else touches the document,
;; because editor-document-reload on a document that is in no view attaches
;; it to the focused one.
(define (closed-by-hand?)
  (and *doc-id* (not (editor-doc-in-view? *doc-id*))))

(define (panel-focused?)
  (let ([path (editor-document->path (editor->doc-id (editor-focus)))])
    (and (string? path) (equal? path *path*))))

;; Pull the file back in when it has changed. Nothing is reloaded when the
;; token is unchanged, so an idle session costs one short read per tick.
(define (refresh!)
  (let ([token (file-token *path*)])
    (when (and (string? token) (not (equal? token *token*)))
      (set! *token* token)
      (when (not (reload-panel!))
        ;; The buffer was edited by hand, or the document is gone. Rebuild
        ;; it rather than leaving stale text on screen.
        (let ([path *path*])
          (close-panel!)
          (open-panel! path))))))

(define (reload-panel!)
  (call-with-exception-handler (lambda (failure) #f)
                               (lambda ()
                                 (editor-document-reload *doc-id*)
                                 #t)))

;; ---------------------------------------------------------- the file

;; The file to follow, or #f when no live session has one.
(define (live-file)
  (if (string? *pinned-path*)
      (and (path-exists? *pinned-path*) *pinned-path*)
      (first-live (session-files))))

(define (first-live paths)
  (cond
    [(null? paths) #f]
    [(owner-alive? (car paths)) (car paths)]
    [else (first-live (cdr paths))]))

;; Candidate files, newest session first.
;;
;; Ordering by name picked the lowest pid, which is the *oldest* session:
;; a session that outlives its editor command -- one helix failed to
;; terminate, say -- then owned the panel forever, and the session the user
;; just started was never shown. The proxy's own start time settles it, and
;; unlike a pid it cannot wrap around. Name order is the fallback where
;; there is no /proc, so two sessions still agree on one file per tick
;; rather than alternating.
(define (session-files)
  (let ([named (sort (apply append
                            (map (lambda (directory)
                                   (filter (lambda (entry)
                                             (ends-with? entry *file-suffix*))
                                           (entries-of directory)))
                                 (session-directories)))
                     string<?)])
    (sort named (lambda (left right)
                  (> (or (start-time-of left) 0) (or (start-time-of right) 0))))))

;; Field 22 of /proc/<pid>/stat: when the proxy started, in clock ticks
;; since boot. The executable name is field 2 and may itself hold spaces
;; and brackets, so the fields are counted from after the last `)` rather
;; than from the start of the line.
(define (start-time-of path)
  (let ([line (first-line (string-append "/proc/" (pid-of path) "/stat"))])
    (if (not (string? line))
        #f
        ;; After the last `)` the first field is the state, which is field
        ;; 3, so starttime sits 19 fields further along.
        (let ([fields (split-whitespace (last (split-many line ")")))])
          (if (< (length fields) 20)
              #f
              (string->number (list-ref fields 19)))))))

(define (session-directories)
  (apply append
         (map (lambda (root)
                (filter (lambda (entry)
                          (and (starts-with? (file-name entry) *directory-prefix*)
                               (is-dir? entry)))
                        (entries-of root)))
              (temp-roots))))

(define (entries-of directory)
  (if (path-exists? directory)
      (let ([entries (call-with-exception-handler (lambda (failure) #f)
                                                  (lambda () (read-dir directory)))])
        (if (list? entries) entries '()))
      '()))

(define (environment-directory name)
  (let ([configured (call-with-exception-handler (lambda (failure) #f)
                                                 (lambda () (env-var name)))])
    (if (and (string? configured) (not (equal? configured ""))) configured #f)))

;; Where the proxy may have left its file, best first. XDG_RUNTIME_DIR is
;; tmpfs on a systemd machine, so the proxy prefers it: a panel rewritten
;; on every stop has no business reaching persistent storage. A proxy on a
;; machine without one still writes under TMPDIR, so both are searched.
(define (temp-roots)
  (filter string?
          (list (environment-directory "XDG_RUNTIME_DIR")
                (or (environment-directory "TMPDIR") "/tmp"))))

;; A proxy killed with SIGKILL -- which is how helix ends an adapter --
;; cannot delete its own file, so a stale one can outlive its session. The
;; file is named after the proxy's pid, so /proc settles it. Where there is
;; no /proc, every file counts as live.
(define (owner-alive? path)
  (if (path-exists? "/proc")
      (path-exists? (string-append "/proc/" (pid-of path)))
      #t))

(define (pid-of path)
  (let ([name (file-name path)])
    (substring name 0 (- (string-length name) (string-length *file-suffix*)))))

;; First line of a file, or #f when it cannot be read. Only one line is
;; ever wanted: the panel's is its change token, and /proc/<pid>/stat is
;; one line anyway.
(define (first-line path)
  (if (and (string? path) (path-exists? path))
      (let ([line (call-with-exception-handler (lambda (failure) #f)
                                               (lambda ()
                                                 (call-with-input-file path
                                                                       read-line-from-port)))])
        (if (string? line) line #f))
      #f))

;; The panel's change token: it carries a counter the proxy increments once
;; per stop, so it differs after every stop.
(define (file-token path)
  (first-line path))
