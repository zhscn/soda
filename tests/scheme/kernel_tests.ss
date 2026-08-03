#!r6rs
(import (rnrs)
        (soda kernel change)
        (soda kernel extension)
        (soda kernel selection)
        (soda kernel state)
        (soda host command)
        (soda host dispatch)
        (soda host buffer)
        (soda host input)
        (soda host runtime)
        (soda host state)
        (soda host surface)
        (soda host value)
        (soda host view)
        (soda host window)
        (soda kernel document)
        (soda ffi cpp-analysis)
        (soda ffi indentation)
        (soda ffi tree-sitter))

(define selection
  (make-selection
    (list (make-selection-range 1 4 'after 'character '(primary . #t))
          (make-selection-range 8 8))
    1))
(unless (= (selection-primary selection) 1)
  (error 'kernel-tests "selection primary differs"))
(unless (equal? (selection-range-from (selection-primary-range selection)) 8)
  (error 'kernel-tests "selection range differs"))

(define changes
  (make-change-set
    12
    (list (make-text-change 2 4 "abc")
          (make-text-change 8 8 "x"))))
(unless (= (change-set-new-length changes) 14)
  (error 'kernel-tests "change set length differs"))
(unless (= (change-set-map-offset changes 10 'after) 12)
  (error 'kernel-tests "change mapping differs"))
(unless (equal? (change-set-map-range changes 2 8 'after) (cons 5 10))
  (error 'kernel-tests "range mapping differs"))
(let ([applied
        (change-set-apply
          (make-change-set
            5
            (list (make-text-change 1 2 "XYZ")
                  (make-text-change 4 5 "!")))
          (string->utf8 "abcde")
          #t)])
  (unless (string=? applied "aXYZcd!")
    (error 'kernel-tests "change set application differs")))
(let* ([base (string->utf8 "abcde")]
       [forward (make-change-set 5 (list (make-text-change 1 3 "XYZ")))]
       [inverse (change-set-invert forward base)])
  (unless (string=? (change-set-apply inverse (change-set-apply forward base) #t) "abcde")
    (error 'kernel-tests "change set inversion differs")))
(let* ([base (string->utf8 "abcde")]
       [first (make-change-set 5 (list (make-text-change 1 2 "XYZ")))]
       [second (make-change-set 7 (list (make-text-change 6 7 "!")))]
       [composed (change-set-compose first second base)])
  (unless (string=? (change-set-apply composed base #t) "aXYZcd!")
    (error 'kernel-tests "change set composition differs")))

(define history-field
  (make-state-field
    'history 'buffer
    (lambda (state) 'empty)
    (lambda (value transaction) value)))
(define read-only
  (make-facet 'read-only #f (lambda (values) (and (pair? values) (car values)))))
(define configuration
  (make-configuration
    (list history-field
          (make-facet-provider read-only #t 'high))))
(unless (eq? (car (configuration-fields configuration 'buffer)) history-field)
  (error 'kernel-tests "state field configuration differs"))
(unless (configuration-facet configuration read-only)
  (error 'kernel-tests "facet configuration differs"))

(define buffer-snapshot
  (make-buffer-state 'document configuration (list (cons history-field 'empty))))
(define view-snapshot
  (make-view-state 0 selection '(0 . 20) 'insert configuration))
(define spec (make-transaction-spec 0 changes))
(unless (and (= (transaction-spec-buffer-id spec) 0)
             (eq? (buffer-state-field buffer-snapshot history-field) 'empty)
             (= (view-state-buffer-id view-snapshot) 0))
  (error 'kernel-tests "state protocol differs"))

;; State effects are authored against the transaction's starting document and
;; are mapped before they reach the realized transaction.
(define position-effect
  (make-state-effect
    'position
    8
    (lambda (offset description)
      (change-desc-map-offset description offset 'after))))
(define mapped-transaction
  (make-transaction buffer-snapshot #f changes #f (list position-effect) '()))
(unless (= (state-effect-value (car (transaction-effects mapped-transaction))) 10)
  (error 'kernel-tests "state effect mapping differs"))

(define mode-field
  (make-state-field
    'mode 'buffer
    (lambda (state) 'mode)
    (lambda (value transaction) value)))
(define mode-compartment (make-compartment 'mode))
(define configurable-state
  (make-buffer-state
    'document
    (make-configuration
      (list (make-compartment-entry mode-compartment history-field)))))
(define reconfigured-transaction
  (make-transaction
    configurable-state #f changes #f
    (list (make-compartment-reconfigure-effect mode-compartment mode-field))
    '()))
(define reconfigured-state
  (transaction-new-buffer-state reconfigured-transaction))
(unless (eq? (buffer-state-field reconfigured-state mode-field) 'mode)
  (error 'kernel-tests "compartment reconfiguration differs"))

(define host (make-host-state))
(define owner (make-owner 'kernel-test))
(define document (make-document "hello"))
(define buffer
  (buffer-service-create!
    (host-state-buffers host) owner "*kernel*" document configuration))
(define view
  (view-service-create!
    (host-state-views host) owner buffer configuration))
(define leaf (make-leaf-window (view-id view) '(0 0 80 24)))
(define surface (make-surface leaf '(80 . 24)))
(surface-set-selected-window! surface leaf)
(unless (and (eq? (surface-selected-window surface) leaf)
             (= (buffer-id buffer) (view-state-buffer-id (view-state view))))
  (error 'kernel-tests "host state protocol differs"))

(define test-keymap (make-keymap 'test))
(keymap-bind! test-keymap '(control-x control-s) 'save-buffer)
(unless (equal? (keymap-lookup test-keymap '(control-x control-s)) 'save-buffer)
  (error 'kernel-tests "keymap lookup differs"))
(unless (eq? (car (resolve-key-sequence
                    (list (make-input-layer 'global test-keymap))
                    '(control-x control-s)))
             'command)
  (error 'kernel-tests "keymap resolver differs"))
(define input-service (make-input-service))
(define input-context
  (make-input-context
    0 0 (list (make-input-layer 'global test-keymap #f 'ignore))
    (view-state-input-state (view-state view))))
(unless (eq? (input-disposition-kind
               (input-service-dispatch
                 input-service input-context
                 (make-input-event 'key 'control-x)))
             'consume)
  (error 'kernel-tests "pending prefix was not retained"))
(define pending-result
  (input-service-dispatch
    input-service input-context (make-input-event 'key 'control-s)))
(unless (and (eq? (input-disposition-kind pending-result) 'command)
             (eq? (input-disposition-value pending-result) 'save-buffer))
  (error 'kernel-tests "pending command was not resolved"))

(define runtime (make-runtime))
(define request (runtime-enqueue-request! runtime owner 'buffer 0 'payload))
(unless (and (runtime-request? request) (= (runtime-request-id request) 1))
  (error 'kernel-tests "runtime request identity differs"))
(define drained '())
(runtime-drain! runtime (lambda (message) (set! drained (cons message drained))))
(unless (and (= (length drained) 1)
             (eq? (runtime-request-payload (car drained)) 'payload))
  (error 'kernel-tests "runtime queue order differs"))

;; Dispatch is the only host publication path.  It applies the kernel change
;; set to the native document, maps the view selection, and advances both
;; immutable state generations atomically.
(define dispatch-spec
  (make-transaction-spec
    (buffer-id buffer) (view-id view) (buffer-state-generation (buffer-state buffer))
    (make-change-set
      (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
      (list (make-text-change 5 5 " world")))
    #f '() '()))
(define update
  (dispatcher-dispatch!
    (host-state-dispatch host)
    dispatch-spec))
(unless (and (editor-update? update)
             (= (buffer-state-generation (buffer-state buffer)) 1)
             (= (view-state-generation (view-state view)) 1)
             (string=?
               (snapshot-string (buffer-state-document (buffer-state buffer)))
               "hello world"))
  (error 'kernel-tests "dispatcher did not publish an atomic update"))
(host-state-close! host)
