;; helix-test-debug: The overlay that lists a crate's tests and hands one
;; back. Editor side: it draws and reads keys, and knows nothing about
;; building or launching. What it does with a chosen test is the caller's
;; callback.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require "helix/misc.scm")
(require "helix/components.scm")
(require "test-debug-rust.scm")

(provide pick-test!)

;; Name the component is pushed under, so it can pop itself.
(define *picker-name* "test-debug-picker")

;; Rows of tests on screen. The overlay is a fixed height rather than a
;; share of the window, because a picker that resizes as you type is
;; harder to aim at than one that scrolls.
(define *rows* 12)

(struct PickerState (entries query index choose!) #:mutable)

(define (visible state)
  (matching-tests-by-name (PickerState-query state) (PickerState-entries state)))

;; The chosen entry, or #f when nothing matches the query.
(define (selected state)
  (let ([shown (visible state)])
    (if (empty? shown)
        #f
        (list-ref shown (min (PickerState-index state) (- (length shown) 1))))))

;; Keep the selection inside the match list. Typing narrows it, so an index
;; that was valid a keystroke ago may not be.
(define (clamp-index! state)
  (let ([count (length (visible state))])
    (set-PickerState-index! state
                            (cond [(equal? count 0) 0]
                                  [(>= (PickerState-index state) count) (- count 1)]
                                  [(< (PickerState-index state) 0) 0]
                                  [else (PickerState-index state)]))))

(define (move! state delta)
  (set-PickerState-index! state (+ (PickerState-index state) delta))
  (clamp-index! state))

(define (query! state text)
  (set-PickerState-query! state text)
  (set-PickerState-index! state 0))

;; Rows to draw, scrolled so the selection is always among them.
(define (window state)
  (let* ([shown (visible state)]
         [count (length shown)]
         [index (PickerState-index state)]
         [first (max 0 (min (- index (quotient *rows* 2)) (- count *rows*)))])
    (if (<= count *rows*)
        (list 0 shown)
        (list first (take (drop shown first) *rows*)))))

;; A row reads as the test name with its file trailing, because the name is
;; what is being matched and the file is only there to disambiguate.
(define (row-text entry width)
  (let* ([text (string-append (discovered-name entry)
                              "  "
                              (discovered-path entry)
                              ":"
                              (number->string (discovered-line entry)))])
    (if (> (string-length text) width)
        (substring text 0 width)
        text)))

(define (render state area frame)
  (let* ([x (+ (area-x area) 1)]
         [width (max 1 (- (area-width area) 2))]
         [summary (discovery-summary (PickerState-query state)
                                     (visible state)
                                     (length (PickerState-entries state)))]
         [scrolled (window state)]
         [first (car scrolled)]
         [rows (car (cdr scrolled))])
    (buffer/clear frame area)
    (block/render frame area (block))
    (frame-set-string! frame x (+ (area-y area) 1) summary (style-with-dim (style)))
    (frame-set-string! frame
                       x
                       (+ (area-y area) 2)
                       (string-append "> " (PickerState-query state))
                       (style))
    (let loop ([remaining rows] [row 0])
      (when (not (empty? remaining))
        (frame-set-string! frame
                           x
                           (+ (area-y area) 4 row)
                           (row-text (car remaining) width)
                           (if (equal? (+ first row) (PickerState-index state))
                               (style-with-reversed (style))
                               (style)))
        (loop (cdr remaining) (+ row 1))))))

(define (close!)
  (pop-last-component-by-name! *picker-name*))

;; Enter on a match closes the overlay and then runs the callback: the
;; callback starts a build and sets a status line, which would otherwise be
;; drawn under a component that is about to disappear.
(define (accept! state)
  (let ([entry (selected state)])
    (if entry
        (begin (close!)
               ((PickerState-choose! state) entry)
               event-result/close)
        event-result/consume)))

(define (backspace! state)
  (let ([text (PickerState-query state)])
    (when (> (string-length text) 0)
      (query! state (substring text 0 (- (string-length text) 1))))
    event-result/consume))

(define (typed! state character)
  (query! state (string-append (PickerState-query state) (string character)))
  event-result/consume)

(define (handle-event state event)
  (cond
    [(key-event-escape? event) (begin (close!) event-result/close)]
    [(key-event-enter? event) (accept! state)]
    [(key-event-backspace? event) (backspace! state)]
    [(key-event-up? event) (begin (move! state -1) event-result/consume)]
    [(key-event-down? event) (begin (move! state 1) event-result/consume)]
    [else
     (let ([character (key-event-char event)])
       (if (char? character)
           (typed! state character)
           event-result/consume))]))

;; Put the cursor after the query, so the terminal caret sits where typing
;; goes rather than in the buffer underneath.
(define (cursor state area)
  (position (+ (area-y area) 2)
            (+ (area-x area) 3 (string-length (PickerState-query state)))))

;;@doc
;; Show `entries` as a filterable list and call `choose!` with the one
;; picked. Nothing is called when the overlay is dismissed.
(define (pick-test! entries choose!)
  (let ([state (PickerState entries "" 0 choose!)])
    (push-component!
     (new-component! *picker-name*
                     state
                     render
                     (hash "handle_event" handle-event
                           "cursor" cursor)))))
