;; Stub of helix's virtual helix/components.scm module, for
;; `make compile-check`. See ../README.md.

(provide new-component!
         position
         area-x
         area-y
         area-width
         buffer/clear
         block
         block/render
         frame-set-string!
         style
         style-with-dim
         style-with-reversed
         event-result/consume
         event-result/close
         key-event-char
         key-event-escape?
         key-event-backspace?
         key-event-enter?
         key-event-up?
         key-event-down?)

(define (new-component! name state render functions) void)
(define (position row col) void)
(define (area-x area) 0)
(define (area-y area) 0)
(define (area-width area) 0)
(define (buffer/clear frame area) void)
(define (block) void)
(define (block/render frame area block) void)
(define (frame-set-string! frame x y text style) void)
(define (style) void)
(define (style-with-dim style) void)
(define (style-with-reversed style) void)
(define event-result/consume void)
(define event-result/close void)
(define (key-event-char event) #f)
(define (key-event-escape? event) #f)
(define (key-event-backspace? event) #f)
(define (key-event-enter? event) #f)
(define (key-event-up? event) #f)
(define (key-event-down? event) #f)
