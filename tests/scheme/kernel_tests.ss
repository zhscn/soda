#!r6rs
(import (rnrs)
        (soda kernel change)
        (soda kernel extension)
        (soda kernel range-set)
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
(let ([empty-change-set
       (make-change-set 5 (list (make-text-change 2 2 "")))])
  (unless (and (change-set-empty? empty-change-set)
               (= (change-set-new-length empty-change-set) 5))
    (error 'kernel-tests "empty text change was not normalized")))
(unless (= (change-set-map-offset changes 10 'after) 12)
  (error 'kernel-tests "change mapping differs"))
(unless (equal? (change-set-map-range changes 2 8 'after) (cons 5 10))
  (error 'kernel-tests "range mapping differs"))
(let* ([selection-before
        (make-selection (list (make-selection-range 2 2 'after 'character '())))]
       [selection-after
        (selection-map-change selection-before (change-set-change-desc changes))])
  (unless (= (selection-range-head (selection-primary-range selection-after)) 5)
    (error 'kernel-tests "Selection ChangeDesc mapping differs")))
(let ([replacement
        (make-change-set
          5
          (list (make-text-change 1 4 "xx")))])
  (unless (and (= (change-set-map-offset replacement 1 'before) 1)
               (= (change-set-map-offset replacement 4 'before) 1)
               (= (change-set-map-offset replacement 1 'after) 3)
               (= (change-set-map-offset replacement 4 'after) 3))
    (error 'kernel-tests "replacement boundary affinity differs")))
(let ([adjacent-insertions
        (make-change-set
          4
          (list (make-text-change 1 1 "a")
                (make-text-change 1 1 "b")))])
  (unless (and (= (change-set-map-offset adjacent-insertions 1 'before) 1)
               (= (change-set-map-offset adjacent-insertions 1 'after) 3))
    (error 'kernel-tests "adjacent insertion mapping differs")))
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
(let* ([base (string->utf8 "abcde")]
       [first (make-change-set 5 (list (make-text-change 1 1 "X")))]
       [second (make-change-set 6 (list (make-text-change 5 5 "Y")))]
       [composed (change-set-compose first second base)])
  (unless (and (= (length (change-set-changes composed)) 2)
               (string=? (change-set-apply composed base #t) "aXbcdYe")
               (= (change-set-map-offset composed 2 'after) 3))
    (error 'kernel-tests "distant change composition differs")))
(let* ([base (string->utf8 "abcde")]
       [first (make-change-set 5 (list (make-text-change 1 1 "X")))]
       [second (make-change-set 5 (list (make-text-change 4 4 "Y")))]
       [merged (change-set-merge first second)]
       [mapped-second (change-set-map second first)]
       [sequential (change-set-compose first mapped-second base)])
  (unless (and (string=? (change-set-apply merged base #t) "aXbcdYe")
               (string=? (change-set-apply sequential base #t) "aXbcdYe"))
    (error 'kernel-tests "simultaneous change merge differs")))
(let* ([base (string->utf8 "abcde")]
       [first-spec
        (make-transaction-spec
          0 #f #f
          (make-change-set 5 (list (make-text-change 1 1 "X")))
          #f '() '() 'first #f)]
       [second-spec
        (make-transaction-spec
          0 #f #f
          (make-change-set 5 (list (make-text-change 4 4 "Y")))
          #f '() '() 'second #f)]
       [resolved
        (resolve-transaction-specs (list first-spec second-spec) base)]
       [sequential-spec
        (make-transaction-spec
          0 #f #f
          (make-change-set 6 (list (make-text-change 2 2 "Y")))
          #f '() '() #f #f #t)]
       [sequential-resolved
        (resolve-transaction-specs
          (list first-spec sequential-spec)
          base)])
(unless (and (string=?
                 (change-set-apply
                   (resolved-transaction-changes resolved) base #t)
                 "aXbcdYe")
               (string=?
                 (change-set-apply
                   (resolved-transaction-changes sequential-resolved) base #t)
                 "aXYbcde")
               (eq? (resolved-transaction-scroll-request resolved) 'second))
    (error 'kernel-tests "transaction spec resolution differs")))
(unless
    (guard (condition [else #t])
      (resolve-transaction-specs
        (list
          (make-transaction-spec
            0 #f #f
            (make-change-set 5 '())
            (make-selection (list (make-selection-range 6 6)))
            '() '()))
        (string->utf8 "abcde"))
      #f)
  (error 'kernel-tests "out-of-range transaction selection was accepted"))
(let* ([base (string->utf8 "abcde")]
       [first-spec
        (make-transaction-spec
          0 #f #f
          (make-change-set 5 (list (make-text-change 1 1 "X")))
          #f '() '() #f #f)]
       [second-spec
        (make-transaction-spec
          0 #f #f
          (make-change-set 5 (list (make-text-change 4 4 "Y")))
          (make-selection (list (make-selection-range 5 5 'after 'character '())))
          (list
            (make-state-effect
              'position 5
              (lambda (offset description)
                (change-desc-map-offset description offset 'after))))
          '() #f #f)]
       [resolved (resolve-transaction-specs (list first-spec second-spec) base)])
  (unless (and (= (selection-range-head
                    (selection-primary-range
                      (resolved-transaction-selection resolved)))
                  6)
               (= (state-effect-value
                    (car (resolved-transaction-effects resolved)))
                  6))
    (error 'kernel-tests "non-sequential selection/effect mapping differs")))

(define first-range
  (make-range-value 1 3 'first 'before 'after))
(define second-range
  (make-range-value 6 8 'second 'after 'before))
(define ranges (make-range-set (list first-range second-range)))
(unless (and (eq? (range-value-value first-range) 'first)
             (eq? (range-value-start-affinity first-range) 'before)
             (eq? (range-value-end-affinity first-range) 'after)
             (eq? (car (range-set-query ranges 2 7)) first-range)
             (eq? (car (range-set-cursor ranges 6 9)) second-range)
             (eq? (range-cursor-current
                    (range-set-sweep-cursor ranges 6 9))
                  second-range))
  (error 'kernel-tests "range set query differs"))
(let ([cursor (range-set-sweep-cursor ranges 0 9)])
  (unless (and (eq? (range-cursor-current cursor) first-range)
               (eq? (range-cursor-next! cursor) second-range)
               (not (range-cursor-next! cursor))
               (range-cursor-done? cursor))
    (error 'kernel-tests "range cursor traversal differs")))
(let* ([outer (make-range-value 1 6 'outer)]
       [inner (make-range-value 3 4 'inner)]
       [overlapping (make-range-set (list outer inner))]
       [matches (range-set-query overlapping 3 4)])
  (unless (and (= (length matches) 2)
               (eq? (car matches) outer)
               (eq? (cadr matches) inner))
    (error 'kernel-tests "overlapping range query differs")))
(let* ([outer (make-range-value 1 6 'outer)]
       [point (make-range-value 3 3 'point)]
       [point-set (make-range-set (list outer point))]
       [matches (range-set-query-point point-set 3)])
  (unless (and (= (length matches) 2)
               (eq? (car matches) outer)
               (eq? (cadr matches) point))
    (error 'kernel-tests "point range query differs")))
(let* ([builder (make-range-set-builder)]
       [_ (range-set-builder-add! builder first-range)]
       [_ (range-set-builder-add! builder second-range)]
       [built (range-set-builder-finish! builder)])
  (unless (and (eq? (range-set-builder-finish! builder) built)
               (equal? (range-set-ranges built) (range-set-ranges ranges)))
    (error 'kernel-tests "range set builder differs")))
(let* ([point (make-range-value 3 3 'point 'after 'after 'retain #t)]
       [updated (range-set-update ranges (list point))]
       [spans (range-set-spans updated 0 9)]
       [point-span
        (let loop ([items spans])
          (cond
            [(null? items) #f]
            [(pair? (range-span-points (car items))) (car items)]
            [else (loop (cdr items))]))])
  (unless (and (range-value-point? point)
               point-span
               (= (range-span-from point-span) 3)
               (eq? (range-value-value
                      (car (range-span-points point-span)))
                    'point))
    (error 'kernel-tests "range set spans differs")))
(let ([filtered (range-set-update ranges '()
                                  (lambda (range)
                                    (not (eq? (range-value-value range) 'first))))])
  (unless (and (= (length (range-set-ranges filtered)) 1)
               (eq? (range-value-value
                      (car (range-set-ranges filtered)))
                    'second))
    (error 'kernel-tests "range set filter update differs")))
(let ([mapped
        (range-set-map-change
          ranges
          (make-change-set
            10
            (list (make-text-change 1 1 "xx"))))])
  (let ([mapped-ranges (range-set-ranges mapped)])
    (unless (and (= (range-value-from (car mapped-ranges)) 1)
                 (= (range-value-to (car mapped-ranges)) 5)
                 (= (range-value-from (cadr mapped-ranges)) 8)
                 (= (range-value-to (cadr mapped-ranges)) 10))
      (error 'kernel-tests "range set mapping differs"))))
(let ([mapped
        (range-set-map-change
          ranges
          (change-set-change-desc
            (make-change-set
              10
              (list (make-text-change 1 1 "xx")))))])
  (unless (= (range-value-to (car (range-set-ranges mapped))) 5)
    (error 'kernel-tests "range ChangeDesc mapping differs")))
(let ([collapsed
        (range-set-map-change
          (make-range-set
            (list (make-range-value 1 9 'deleted 'after 'before)))
          (make-change-set
            10
            (list (make-text-change 1 9 "x"))))])
  (let ([range (car (range-set-ranges collapsed))])
    (unless (and (= (range-value-from range) 1)
                 (= (range-value-to range) 1))
      (error 'kernel-tests "range deletion affinity differs"))))
(let ([mapped
        (range-set-map-change
          (make-range-set
            (list (make-range-value 1 4 'drop 'before 'after 'drop)
                  (make-range-value 7 9 'retain 'before 'after 'retain)))
          (make-change-set
            10
            (list (make-text-change 2 6 "x"))))])
  (let ([mapped-ranges (range-set-ranges mapped)])
    (unless (and (= (length mapped-ranges) 1)
                 (eq? (range-value-value (car mapped-ranges)) 'retain)
                 (eq? (range-value-map-mode (car mapped-ranges)) 'retain))
      (error 'kernel-tests "range deletion policy differs"))))
(let ([empty-changes (make-change-set 10 '())])
  (unless (and (eq? (range-set-map-change ranges empty-changes) ranges)
               (eq? (range-set-map ranges (lambda (range) range)) ranges))
    (error 'kernel-tests "range set no-op mapping did not preserve identity")))

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
(unless (= (length (configuration-fields
                    (make-configuration (list history-field history-field))
                    'buffer))
           1)
  (error 'kernel-tests "duplicate state field was not normalized"))
(unless (configuration-facet configuration read-only)
  (error 'kernel-tests "facet configuration differs"))
(define view-only-facet
  (make-facet
    'view-only 'view #f
    (lambda (values) (car values))
    eq?))
(define view-only-configuration
  (make-configuration
    (list (make-facet-provider view-only-facet #t))))
(unless (and (not (configuration-facet view-only-configuration view-only-facet 'buffer))
             (configuration-facet view-only-configuration view-only-facet 'view))
  (error 'kernel-tests "facet scope differs"))

(define buffer-snapshot
  (make-buffer-state 'document configuration (list (cons history-field 'empty))))
(define view-snapshot
  (make-view-state 0 0 selection '(0 . 20) 'insert configuration))
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

(let* ([field
        (make-state-field
          'stable 'buffer
          (lambda (state) (vector 1))
          (lambda (value transaction) (vector (vector-ref value 0)))
          equal?)]
       [old-value (vector 1)]
       [state
        (make-buffer-state
          'document
          (make-configuration (list field))
          (list (cons field old-value)))]
       [transaction
        (make-transaction
          state #f (make-change-set 0 '()) #f '() '() 'document)])
  (unless (eq? (buffer-state-field (transaction-new-buffer-state transaction) field)
               old-value)
    (error 'kernel-tests "StateField.compare did not preserve equal state")))

(define mode-field
  (make-state-field
    'mode 'buffer
    (lambda (state) 'mode)
    (lambda (value transaction) value)))
(define mode-compartment (make-compartment 'mode))
(unless (and (compartment-entry? (compartment-of mode-compartment mode-field))
             (state-effect? (compartment-reconfigure mode-compartment mode-field)))
  (error 'kernel-tests "compartment convenience protocol differs"))
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
(let* ([new-compartment (make-compartment 'new-mode)]
       [new-configuration
        (configuration-apply-effects
          (make-configuration '())
          (list (make-compartment-reconfigure-effect
                  new-compartment mode-field)))])
  (unless (and (= (length (configuration-fields new-configuration 'buffer)) 1)
               (eq? (state-field-name
                      (car (configuration-fields new-configuration 'buffer)))
                    'mode))
    (error 'kernel-tests "absent compartment reconfiguration differs")))
(define reconfigured-with-view
  (make-transaction
    configurable-state view-snapshot changes #f
    (list (make-compartment-reconfigure-effect mode-compartment mode-field))
    '()))
(unless (not (pair?
              (filter
                compartment-entry?
                (configuration-extensions
                  (view-state-configuration
                    (transaction-new-view-state reconfigured-with-view))))))
  (error 'kernel-tests "compartment leaked into view configuration"))
(let* ([view-field
        (make-state-field
          'view-mode 'view
          (lambda (state) 'view-mode)
          (lambda (value transaction) value))]
       [view-compartment (make-compartment 'view-mode 'view)]
       [view-configuration
        (make-configuration
          (list (make-compartment-entry view-compartment '())))]
       [view-start
        (make-view-state
          0 0 selection '(0 . 20) 'insert view-configuration)]
       [view-transaction
        (make-transaction
          buffer-snapshot view-start
          (make-change-set 12 '()) #f
          (list
            (make-compartment-reconfigure-effect
              view-compartment view-field))
          '()
          'document)]
       [origin-state (transaction-new-view-state view-transaction)]
       [shared-state
        (view-state-advance view-start selection view-transaction #f)])
  (unless (and (= (length (configuration-fields
                            (view-state-configuration origin-state)
                            'view))
                  1)
               (null? (configuration-fields
                        (view-state-configuration shared-state)
                        'view)))
    (error 'kernel-tests "view-scoped effect leaked to shared view")))

(define provided-facet (make-facet 'provided #f (lambda (values) (car values))))
(define provider-field
  (make-state-field
    'provider 'buffer
    (lambda (state) 'provider)
    (lambda (value transaction) value)
    eq?
    (lambda (field)
      (make-facet-provider provided-facet 'from-state-field))))
(unless (eq?
          (configuration-facet
            (make-configuration (list provider-field))
            provided-facet)
          'from-state-field)
  (error 'kernel-tests "state field provider differs"))
(let* ([ordered
        (make-facet 'ordered '() (lambda (values) (apply append values)))]
       [ordered-configuration
        (make-configuration
          (list
            (make-facet-provider ordered (list 'first))
            (make-facet-provider ordered (list 'second))))])
  (unless (equal? (configuration-facet ordered-configuration ordered)
                  '(first second))
    (error 'kernel-tests "facet provider order differs")))

(let ([drop-effect
        (make-state-effect
          'drop
          'value
          (lambda (value description) #f))])
  (unless (not (state-effect-map-value
                drop-effect
                (change-set-change-desc changes)))
    (error 'kernel-tests "deleted state effect was not retired")))

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
(define publication-consistent? #f)
(dispatcher-set-listener!
  (host-state-dispatch host)
  (lambda (update)
    (set!
      publication-consistent?
      (= (buffer-state-generation (editor-update-new-buffer-state update))
         (view-state-buffer-generation
           (cdr (car (editor-update-views update))))))))
(define update
  (dispatcher-dispatch!
    (host-state-dispatch host)
    dispatch-spec))
(unless (and (editor-update? update)
             (= (buffer-state-generation (buffer-state buffer)) 1)
             (= (view-state-generation (view-state view)) 1)
             (= (view-state-buffer-generation (view-state view)) 1)
             publication-consistent?
             (string=?
               (snapshot-string (buffer-state-document (buffer-state buffer)))
               "hello world"))
  (error 'kernel-tests "dispatcher did not publish an atomic update"))

;; A batch dispatch resolves simultaneous specs against one starting snapshot
;; and publishes one buffer generation/update.
(define batch-generation (buffer-state-generation (buffer-state buffer)))
(define batch-length (snapshot-byte-size (buffer-state-document (buffer-state buffer))))
(define batch-update
  (dispatcher-dispatch-specs!
    (host-state-dispatch host)
    (list
      (make-transaction-spec
        (buffer-id buffer) (view-id view) batch-generation
        (make-change-set
          batch-length
          (list (make-text-change 0 0 "A")))
        #f '() '())
      (make-transaction-spec
        (buffer-id buffer) #f batch-generation
        (make-change-set
          batch-length
          (list (make-text-change batch-length batch-length "B")))
        #f '() '()))))
(unless (and (editor-update? batch-update)
             (= (buffer-state-generation (buffer-state buffer)) 2)
             (= (change-set-old-length (editor-update-changes batch-update))
                batch-length)
             (= (change-set-new-length (editor-update-changes batch-update))
                (+ batch-length 2))
             (string=?
               (snapshot-string (buffer-state-document (buffer-state buffer)))
               "Ahello worldB"))
  (error 'kernel-tests "dispatcher did not resolve a batch update"))

(let* ([reject-filter
        (lambda (value)
          (unless (resolved-transaction? value)
            (error 'kernel-tests "transaction filter did not receive resolved state"))
          #f)]
       [reject-configuration
        (make-configuration
          (list
            (make-facet-provider
              transaction-filters-facet
              (list reject-filter))))]
       [reject-document (make-document "hello")]
       [reject-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*reject*" reject-document
          reject-configuration)]
       [reject-view
        (view-service-create!
          (host-state-views host) owner reject-buffer reject-configuration)]
       [rejected
        (dispatcher-dispatch!
          (host-state-dispatch host)
          (make-transaction-spec
            (buffer-id reject-buffer) (view-id reject-view) 0
            (make-change-set 5 (list (make-text-change 5 5 "!")))
            #f '() '()))]
       [allowed
        (dispatcher-dispatch!
          (host-state-dispatch host)
          (make-transaction-spec
            (buffer-id reject-buffer) (view-id reject-view) 0
            (make-change-set 5 (list (make-text-change 5 5 "!")))
            #f '() '() #f #t))])
  (unless (and (not rejected)
               allowed
               (= (buffer-state-generation (buffer-state reject-buffer)) 1)
               (string=? (snapshot-string
                           (buffer-state-document (buffer-state reject-buffer)))
                         "hello!"))
    (error 'kernel-tests "transaction filter policy differs")))

(define second-view
  (view-service-create!
    (host-state-views host) owner buffer configuration))
(define second-view-state (view-state second-view))
(view-publish-state!
  second-view
  (make-view-state
    (view-state-buffer-id second-view-state)
    0
    (view-state-selection second-view-state)
    (view-state-viewport second-view-state)
    (view-state-input-state second-view-state)
    (view-state-configuration second-view-state)
    (view-state-fields second-view-state)))
(define stale-view-rejected?
  (guard (condition [else #t])
    (dispatcher-dispatch!
      (host-state-dispatch host)
      (make-transaction-spec
        (buffer-id buffer) (view-id view)
        (buffer-state-generation (buffer-state buffer))
        (make-change-set
          (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
          (list (make-text-change
                  (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
                  (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
                  "!")))
        #f '() '()))
    #f))
(unless stale-view-rejected?
  (error 'kernel-tests "stale shared view was not rejected"))
(host-state-close! host)
