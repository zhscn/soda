#!r6rs
(import (rnrs)
        (soda kernel transaction)
        (soda kernel extension)
        (soda kernel selection)
        (soda kernel state)
        (soda host command)
        (soda host buffer)
        (soda host input)
        (soda host state)
        (soda host surface)
        (soda host value)
        (soda host view)
        (soda host window)
        (soda kernel document))

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
    0 0 (list (make-input-layer 'global test-keymap #f 'ignore))))
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
(host-state-close! host)
