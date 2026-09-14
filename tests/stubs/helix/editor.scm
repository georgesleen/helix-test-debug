;; Stub of helix's virtual helix/editor.scm module, for `make compile-check`.
;; See ../README.md.

(provide editor-document-dirty?
         editor-focus
         editor->doc-id
         editor->text
         editor-document->path)

(define (editor-focus) 0)
(define (editor->doc-id view) 0)
(define (editor->text doc) "")
(define (editor-document->path doc) "")
(define (editor-document-dirty? doc) #f)
