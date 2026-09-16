;; helix-test-debug: finding a CMake project's firmware, through CMake's
;; own file API. See docs/specs/cmake-firmware.md.
;;
;; CMake is how most firmware is built -- Zephyr, ESP-IDF, the Pico SDK,
;; CubeMX output, hand-written cross builds -- so the question "which image
;; do I flash" is answered by asking CMake rather than by globbing for an
;; extension or knowing anything about a vendor.
;;
;; SPDX-License-Identifier: LGPL-3.0-or-later

(require-builtin steel/strings)
(require-builtin steel/json)
(require "../text.scm")

(provide build-type-debuggable?
         cmake-build-type
         cmake-cross-system?
         cmake-toolchain-file
         codemodel-reply
         codemodel-targets
         firmware-artifact)

(define (json-or-false text)
  (if (not (string? text))
      #f
      (call-with-exception-handler (lambda (failure) #f)
                                   (lambda () (string->jsexpr text)))))

;; A cache entry's value, or #f. The cache writes NAME:TYPE=VALUE, and the
;; type varies by entry, so the name is matched up to the colon.
(define (cache-value cache name)
  (let loop ([lines (source-lines cache)])
    (cond [(empty? lines) #f]
          [else
           (let ([line (trim (car lines))])
             (if (starts-with? line (string-append name ":"))
                 (let ([tail (text-after line "=")])
                   (if tail (trim tail) (loop (cdr lines))))
                 (loop (cdr lines))))])))

;; The value a CMakeSystem.cmake set() line assigns, or #f. Quotes are
;; optional: a hand-edited file may omit them.
(define (set-value text name)
  (let loop ([lines (source-lines text)])
    (cond [(empty? lines) #f]
          [else
           (let ([line (trim (car lines))])
             (if (starts-with? line (string-append "set(" name " "))
                 (let* ([tail (trim (text-after line (string-append "set(" name " ")))]
                        [without-quotes (if (starts-with? tail "\"")
                                            (identifier-prefix-until (text-after tail "\"") #\")
                                            (identifier-prefix-until tail #\)))])
                   (if (equal? (trim without-quotes) "") #f (trim without-quotes)))
                 (loop (cdr lines))))])))

;; CMAKE_CROSSCOMPILING is derived rather than cached, so it is not in
;; CMakeCache.txt at all. What is on disk is the pair CMake derives it
;; from, and comparing them is the same comparison CMake makes: no list of
;; systems is needed, only the fact that they differ.
(define (cmake-cross-system? system)
  (let ([target (set-value system "CMAKE_SYSTEM_NAME")]
        [host (set-value system "CMAKE_HOST_SYSTEM_NAME")])
    (and (string? target) (string? host) (not (equal? target host)))))

;; A second, independent signal: a build may name a system on the command
;; line with no toolchain file, or use one whose system matches the host.
(define (cmake-toolchain-file cache)
  (let ([value (cache-value cache "CMAKE_TOOLCHAIN_FILE")])
    (if (equal? value "") #f value)))

(define (cmake-build-type cache)
  (let ([value (cache-value cache "CMAKE_BUILD_TYPE")])
    (if (equal? value "") #f value)))

(define *debuggable-types* '("debug" "relwithdebinfo"))

;; Whether an image built this way carries line information. Read to say so
;; when it will not: an image with no line table reads as a breakpoint the
;; debugger ignored, which is the hardest failure to attribute.
(define (build-type-debuggable? type flags)
  (or (and (string? flags) (string-contains? flags "-g"))
      (and (string? type) (member? (string-downcase type) *debuggable-types*))))

(define (object-of-kind objects kind)
  (let loop ([remaining objects])
    (cond [(empty? remaining) #f]
          [(and (hash? (car remaining)) (equal? (hash-try-get (car remaining) 'kind) kind))
           (hash-try-get (car remaining) 'jsonFile)]
          [else (loop (cdr remaining))])))

(define (codemodel-reply index)
  (let ([parsed (json-or-false index)])
    (if (not (hash? parsed))
        #f
        (let ([objects (hash-try-get parsed 'objects)])
          (if (list? objects) (object-of-kind objects "codemodel") #f)))))

(define (targets-of-configuration configuration)
  (if (not (hash? configuration))
      '()
      (let ([targets (hash-try-get configuration 'targets)])
        (if (not (list? targets))
            '()
            (filter string?
                    (map (lambda (target)
                           (if (hash? target) (hash-try-get target 'jsonFile) #f))
                         targets))))))

(define (codemodel-targets codemodel)
  (let ([parsed (json-or-false codemodel)])
    (if (not (hash? parsed))
        '()
        (let ([configurations (hash-try-get parsed 'configurations)])
          (if (not (list? configurations))
              '()
              (let loop ([remaining configurations] [found '()])
                (if (empty? remaining)
                    found
                    (loop (cdr remaining)
                          (append found (targets-of-configuration (car remaining)))))))))))

;; Whether this target compiles the file under the cursor. CMake reports
;; project sources relative to the top-level source directory, which is the
;; same spelling path-within produces at the call site.
(define (target-has-source? parsed source)
  (let ([sources (hash-try-get parsed 'sources)])
    (if (not (list? sources))
        #f
        (let loop ([remaining sources])
          (cond [(empty? remaining) #f]
                [(and (hash? (car remaining))
                      (equal? (hash-try-get (car remaining) 'path) source))
                 #t]
                [else (loop (cdr remaining))])))))

(define (target-dependency-ids parsed)
  (let ([dependencies (hash-try-get parsed 'dependencies)])
    (if (not (list? dependencies))
        '()
        (filter string?
                (map (lambda (dependency)
                       (if (hash? dependency) (hash-try-get dependency 'id) #f))
                     dependencies)))))

(define (executable-target? parsed)
  (and (equal? (hash-try-get parsed 'type) "EXECUTABLE")
       (not (equal? (hash-try-get parsed 'imported) #t))))

(define (first-artifact parsed)
  (let ([artifacts (hash-try-get parsed 'artifacts)])
    (if (or (not (list? artifacts)) (empty? artifacts))
        #f
        (let ([first (car artifacts)])
          (if (hash? first) (hash-try-get first 'path) #f)))))

(define (index-by-id parsed-targets)
  (let loop ([remaining parsed-targets] [index (hash)])
    (if (empty? remaining)
        index
        (let ([id (hash-try-get (car remaining) 'id)])
          (loop (cdr remaining)
                (if (string? id) (hash-insert index id (car remaining)) index))))))

;; Whether this target compiles the source, or links something that does.
;; The walk is over CMake's own dependency graph, so it needs no notion of
;; components, libraries or frameworks. visited keeps a diamond in the
;; graph from being walked twice and a cycle from not terminating.
(define (links-source? parsed index source)
  (let loop ([pending (list parsed)] [visited '()])
    (cond
      [(empty? pending) #f]
      [else
       (let* ([target (car pending)]
              [id (hash-try-get target 'id)])
         (cond
           [(and (string? id) (member? id visited)) (loop (cdr pending) visited)]
           [(target-has-source? target source) #t]
           [else
            (let ([dependencies (filter hash?
                                        (map (lambda (dependency)
                                               (hash-try-get index dependency))
                                             (target-dependency-ids target)))])
              (loop (append (cdr pending) dependencies)
                    (if (string? id) (cons id visited) visited)))]))])))

;; The image to flash for the file under the cursor: the one non-imported
;; executable that compiles it, or that links whatever does.
;;
;; Ownership alone is not enough. An SDK's own executable tools and boot
;; stages have to be excluded, which ownership does. But a build system may
;; also put the user's own code in a library: ESP-IDF compiles main.c into
;; the __idf_main component and links it into an executable built from a
;; generated empty source, so nothing "owns" main.c there at all. Walking
;; the link graph covers both without naming either.
;;
;; #f for none, and #f for several: if two executables both reach the
;; source, flashing the wrong one means physically recovering the device,
;; so the caller says so instead of guessing.
(define (firmware-artifact targets source)
  (let* ([parsed (filter hash? (map json-or-false targets))]
         [index (index-by-id parsed)]
         [artifacts (filter string?
                            (map (lambda (target)
                                   (if (and (executable-target? target)
                                            (links-source? target index source))
                                       (first-artifact target)
                                       #f))
                                 parsed))])
    (if (equal? (length artifacts) 1) (car artifacts) #f)))
