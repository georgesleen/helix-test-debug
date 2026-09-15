;; helix-test-debug: what ctest knows about a project's tests. See
;; docs/specs/ctest-discovery.md.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require-builtin steel/json)
(require "../paths.scm")

(provide ctest-tests
         ctest-test-name
         ctest-test-executable
         ctest-test-arguments
         ctest-test-directory
         matching-tests
         build-directory
         project-root
         *build-directory-names*)

(define (json-or-false text)
  (call-with-exception-handler (lambda (failure) #f)
                               (lambda () (string->jsexpr text))))

(define (working-directory properties)
  (if (not (list? properties))
      #f
      (let loop ([remaining properties])
        (cond [(empty? remaining) #f]
              [(and (hash? (car remaining))
                    (equal? (hash-try-get (car remaining) 'name) "WORKING_DIRECTORY"))
               (hash-try-get (car remaining) 'value)]
              [else (loop (cdr remaining))]))))

;; One ctest entry as (name executable arguments working-directory). The
;; command is absent until the target is built, and the name is still real,
;; so the entry survives without it.
(define (ctest-test entry)
  (let* ([name (hash-try-get entry 'name)]
         [command (hash-try-get entry 'command)]
         [runnable (if (list? command) command '())])
    (if (not (string? name))
        #f
        (list name
              (if (empty? runnable) #f (car runnable))
              (if (empty? runnable) '() (cdr runnable))
              (working-directory (hash-try-get entry 'properties))))))

;; Tests ctest reported. Malformed JSON yields nothing rather than failing,
;; because a build directory can be half configured.
(define (ctest-tests text)
  (let ([document (json-or-false text)])
    (if (not (hash? document))
        '()
        (let ([entries (hash-try-get document 'tests)])
          (if (not (list? entries))
              '()
              (filter (lambda (test) (not (equal? test #f)))
                      (map (lambda (entry) (if (hash? entry) (ctest-test entry) #f)) entries)))))))

(define (ctest-test-name test) (list-ref test 0))
(define (ctest-test-executable test) (list-ref test 1))
(define (ctest-test-arguments test) (list-ref test 2))
(define (ctest-test-directory test) (list-ref test 3))

;; Tests a cursor candidate refers to. An exact match stands alone; failing
;; that, a parameterized or typed test registers as Suite.Name/0, so the
;; prefixed siblings are the answer. Nothing matching is the signal to offer
;; the picker, not an error.
(define (matching-tests candidate tests)
  (if (not (string? candidate))
      '()
      (let ([exact (filter (lambda (test) (equal? (ctest-test-name test) candidate)) tests)])
        (if (not (empty? exact))
            exact
            (filter (lambda (test)
                      (starts-with? (ctest-test-name test) (string-append candidate "/")))
                    tests)))))

;; Directory names a configured build is looked for in, in order.
(define *build-directory-names* '("build" "cmake-build-debug" "cmake-build-release"))

;; The configured build directory under a project root, or #f. A cache file
;; is what distinguishes configured from merely present.
(define (build-directory root exists?)
  (let loop ([names *build-directory-names*])
    (cond [(empty? names) #f]
          [(exists? (join-path (join-path root (car names)) "CMakeCache.txt"))
           (join-path root (car names))]
          [else (loop (cdr names))])))

;; Nearest ancestor directory of a file holding a CMakeLists.txt, or #f.
(define (project-root path exists?)
  (let loop ([dir (parent-directory path)])
    (cond [(equal? dir "") #f]
          [(exists? (join-path dir "CMakeLists.txt")) dir]
          [else (loop (parent-directory dir))])))
