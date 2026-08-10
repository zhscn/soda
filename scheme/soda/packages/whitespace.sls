(library (soda packages whitespace)
  (export make-whitespace-service!
          whitespace-service?
          whitespace-keymap
          whitespace-view-extension
          whitespace-policy)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel document)
          (soda kernel range-set)
          (soda kernel state)
          (soda kernel view-state)
          (soda host buffer)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host package)
          (soda host setting)
          (soda host value)
          (soda host view)
          (soda view decoration)
          (soda view display)
          (soda view plugin))

  (define-record-type
    (whitespace-service %make-whitespace-service whitespace-service?)
    (fields (immutable keymap whitespace-keymap)
            (immutable plugin whitespace-service-plugin)))

  (define (first-value values default)
    (if (null? values) default (car values)))

  (define whitespace-policy-facet
    (make-facet 'whitespace-policy 'view 'none
                (lambda (values) (first-value values 'none)) eq? eq?))
  (define whitespace-compartment
    (make-compartment 'whitespace-policy 'view))

  (define (whitespace-policy configuration)
    (configuration-facet configuration whitespace-policy-facet 'view))

  (define (policy-extension policy)
    (make-facet-provider whitespace-policy-facet policy 'highest))

  (define (view-policy view)
    (whitespace-policy (view-state-configuration (view-state view))))

  (define (trailing-whitespace-ranges snapshot)
    (let ([bytes (snapshot-bytevector snapshot)]
          [face (make-face-decoration 'whitespace.trailing 30)])
      (let loop ([index 0] [run #f] [ranges '()])
        (cond
          [(= index (bytevector-length bytes))
           (reverse
             (if (and run (< run index))
                 (cons (make-range-value run index face) ranges)
                 ranges))]
          [else
           (let ([byte (bytevector-u8-ref bytes index)])
             (cond
               [(or (= byte #x20) (= byte #x09))
                (loop (+ index 1) (or run index) ranges)]
               [(= byte #x0a)
                (loop (+ index 1) #f
                      (if (and run (< run index))
                          (cons (make-range-value run index face) ranges)
                          ranges))]
               [else (loop (+ index 1) #f ranges)]))]))))

  (define (trailing-offsets snapshot)
    (let ([offsets (make-eqv-hashtable)])
      (for-each
        (lambda (range)
          (let loop ([offset (range-value-from range)])
            (when (< offset (range-value-to range))
              (hashtable-set! offsets offset #t)
              (loop (+ offset 1)))))
        (trailing-whitespace-ranges snapshot))
      offsets))

  (define (marker-fragment fragment policy trailing)
    (if (not (display-text? fragment))
        fragment
        (let* ([text (display-text-text fragment)]
               [offset (display-text-from fragment)]
               [trailing? (hashtable-ref trailing offset #f)]
               [mark-tab?
                (and (string=? text "\t")
                     (or (memq policy '(tabs all))
                         (and (eq? policy 'trailing) trailing?)))]
               [mark-space?
                (and (string=? text " ")
                     (or (eq? policy 'all)
                         (and (eq? policy 'trailing) trailing?)))])
          (define (marker-face)
            (let ([face (display-text-face fragment)])
              (cond [(not face) 'whitespace.marker]
                    [(list? face) (append face (list 'whitespace.marker))]
                    [else (list face 'whitespace.marker)])))
          (cond
            [mark-tab?
             (make-display-grapheme
               "→" (display-text-from fragment) (display-text-to fragment)
               (marker-face) (display-text-source fragment) 1)]
            [mark-space?
             (make-display-grapheme
               "·" (display-text-from fragment) (display-text-to fragment)
               (marker-face) (display-text-source fragment) 1)]
            [else fragment]))))

  (define (make-whitespace-plugin)
    (make-view-plugin
      'whitespace
      (lambda (view) view)
      #f #f
      (lambda (view)
        (let ([policy (view-policy view)])
          (if (memq policy '(trailing all))
              (make-decoration-set
                (trailing-whitespace-ranges
                  (buffer-state-document (buffer-state (view-buffer view)))))
              (make-decoration-set '()))))
      #f
      (lambda (view)
        (let* ([policy (view-policy view)]
               [snapshot
                (buffer-state-document (buffer-state (view-buffer view)))]
               [trailing (trailing-offsets snapshot)])
          (and (not (eq? policy 'none))
               (lambda (stream)
                 (make-display-stream
                   (map
                     (lambda (fragment)
                       (marker-fragment fragment policy trailing))
                     (display-stream-fragments stream)))))))))

  (define (whitespace-view-extension service)
    (unless (whitespace-service? service)
      (assertion-violation 'whitespace-view-extension
                           "expected a WhitespaceService" service))
    (make-facet-provider view-plugins-facet
                         (list (whitespace-service-plugin service))))

  (define (parse-policy input)
    (let ([value
           (cond [(symbol? input) input]
                 [(string? input) (string->symbol (string-downcase input))]
                 [else 'invalid])])
      (if (memq value '(none tabs trailing all)) value 'invalid)))

  (define (next-policy policy)
    (case policy
      [(none) 'tabs]
      [(tabs) 'trailing]
      [(trailing) 'all]
      [else 'none]))

  (define (toggle-whitespace context)
    (let* ([state (command-context-view-state context)]
           [next
            (next-policy
              (whitespace-policy (view-state-configuration state)))]
           [transaction
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f
              (list
                (make-compartment-reconfigure-effect
                  whitespace-compartment (policy-extension next)))
              '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list transaction
                (make-set-surface-message-operation
                  surface-id
                  (string-append "Whitespace display: " (symbol->string next))))
          transaction)))

  (define (make-whitespace-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-whitespace-service!
                           "expected a PackageHost and Owner" host owner))
    (owner-assert-active 'make-whitespace-service! owner)
    (let* ([keymap (make-keymap 'whitespace)]
           [service
            (%make-whitespace-service keymap (make-whitespace-plugin))])
      (package-host-register-setting-schema!
        host owner
        (make-setting-schema
          'editor.whitespace 'symbol 'none '(view) parse-policy #f
          (lambda (value scope) (policy-extension value))))
      (define-command
        (package-host-command-runtime host) owner 'whitespace.toggle (context)
        (documentation "Cycle tab, trailing-whitespace, and space visualization.")
        (class 'display)
        (undo 'ignore)
        (toggle-whitespace context))
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\P) 2))
        'whitespace.toggle)
      service))
)
