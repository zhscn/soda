(library (soda editor result-buffer)
  (export make-result-buffer-interface
          result-buffer-interface?
          result-buffer-interface-cyclic?
          result-buffer-interface-item-key
          make-result-action
          result-action?
          result-action-name
          result-action-label
          result-action-batch-invoke
          make-result-panel-action
          result-panel-action?
          result-panel-action-name
          result-panel-action-label
          buffer-register-result-action!
          buffer-register-result-panel-action!
          buffer-result-actions-at
          buffer-result-panel-actions
          buffer-result-marked-indices
          buffer-result-marked-items
          buffer-result-item-marked?
          buffer-set-result-item-marked!
          buffer-clear-result-marks!
          buffer-reconcile-result-selection!
          invoke-buffer-item-action
          invoke-result-panel-action
          buffer-set-result-refresh!
          buffer-result-refreshable?
          buffer-set-result-producer-state!
          buffer-result-producer-state
          buffer-result-producer-stop-invoked?
          buffer-set-result-producer-stop-invoked!
          buffer-result-current-index
          buffer-set-result-current-index!
          editor-finish-result-producer!
          buffer-capture-result-group-folds!
          editor-reconcile-result-group-folds!
          refresh-buffer-items
          buffer-set-result-interface!
          buffer-clear-result-interface!
          buffer-result-interface-ref
          editor-note-result-buffer!
          editor-present-result-buffer!
          editor-dismiss-result-buffer!
          editor-append-result-items!
          editor-append-result-message!
          buffer-result-base-resource
          buffer-result-workbench-id
          install-result-buffer-commands!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor condition)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor fold)
          (soda editor prompt)
          (soda editor resource-context)
          (soda editor state)
          (soda editor window)
          (soda editor window-runtime)
          (soda editor workbench))

  (define editor-result-buffers (make-weak-eq-hashtable))

  (define-record-type
    (result-buffer-interface
      %make-result-buffer-interface
      result-buffer-interface?)
    (fields cyclic?
            item-key
            activate
            quit))

  (define-record-type
    (result-buffer-state %make-result-buffer-state result-buffer-state?)
    (fields (mutable interface)
            (mutable current-index)
            (mutable actions)
            (mutable panel-actions)
            (mutable marked-indices)
            (mutable refresh)
            (mutable producer-state)
            (mutable producer-stop-invoked?)
            (mutable base-resource)
            (mutable workbench-id)
            (mutable display-restoration)
            (mutable restore-current-key)
            (mutable restore-current-index)
            (mutable restore-mark-keys)
            (mutable pending-collapsed-groups)))

  (define (buffer-result-state-ref buffer)
    (buffer-local-ref buffer 'result-buffer-state #f))

  (define (require-result-state buffer who)
    (let ([state (buffer-result-state-ref buffer)])
      (unless (result-buffer-state? state)
        (assertion-violation who "Buffer has no result state" buffer))
      state))

  (define-record-type result-display-restoration
    (fields action
            view-id
            previous-buffer-id
            previous-resource-context))

  (define make-result-buffer-interface
    (case-lambda
      [(cyclic? activate quit)
       (make-result-buffer-interface
         cyclic?
         (lambda (buffer item index) index)
         activate
         quit)]
      [(cyclic? item-key activate quit)
       (unless (and (boolean? cyclic?)
                    (procedure? item-key)
                    (procedure? activate)
                    (procedure? quit))
         (assertion-violation
           'make-result-buffer-interface
           "invalid Buffer navigation interface"
           cyclic? item-key activate quit))
       (%make-result-buffer-interface cyclic? item-key activate quit)]))

  (define-record-type
    (result-action %make-result-action result-action?)
    (fields name label applicable? invoke batch-invoke))

  (define make-result-action
    (case-lambda
      [(name label applicable? invoke)
       (make-result-action name label applicable? invoke #f)]
      [(name label applicable? invoke batch-invoke)
       (unless (and (symbol? name)
                    (string? label)
                    (procedure? applicable?)
                    (procedure? invoke)
                    (or (not batch-invoke) (procedure? batch-invoke)))
         (assertion-violation
           'make-result-action
           "invalid result action"
           name label applicable? invoke batch-invoke))
       (%make-result-action
         name label applicable? invoke batch-invoke)]))

  (define-record-type
    (result-panel-action %make-result-panel-action result-panel-action?)
    (fields name label applicable? invoke))

  (define (make-result-panel-action name label applicable? invoke)
    (unless (and (symbol? name)
                 (string? label)
                 (procedure? applicable?)
                 (procedure? invoke))
      (assertion-violation
        'make-result-panel-action
        "invalid Result Buffer panel action"
        name label applicable? invoke))
    (%make-result-panel-action name label applicable? invoke))

  (define (buffer-set-result-interface! buffer interface)
    (unless (and (buffer? buffer)
                 (result-buffer-interface? interface))
      (assertion-violation
        'buffer-set-result-interface!
        "expected a Buffer and navigation interface"
        buffer interface))
    (let ([state (buffer-result-state-ref buffer)])
      (if state
          (begin
            (result-buffer-state-interface-set! state interface)
            (result-buffer-state-current-index-set! state #f)
            (result-buffer-state-actions-set! state '())
            (result-buffer-state-panel-actions-set! state '())
            (result-buffer-state-marked-indices-set! state '())
            (result-buffer-state-refresh-set! state #f)
            (result-buffer-state-producer-state-set! state 'idle)
            (result-buffer-state-producer-stop-invoked?-set! state #f))
          (buffer-set-local!
            buffer
            'result-buffer-state
            (%make-result-buffer-state
              interface #f '() '() '() #f 'idle #f
              (buffer-resource buffer) #f #f #f #f '() '()))))
    buffer)

  (define (buffer-clear-result-interface! buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-clear-result-interface! "expected a Buffer" buffer))
    (buffer-clear-local! buffer 'result-buffer-state)
    buffer)

  (define (buffer-result-marked-indices buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-marked-indices "expected a Buffer" buffer))
    (result-buffer-state-marked-indices
      (require-result-state buffer 'buffer-result-marked-indices)))

  (define (buffer-result-item-marked? buffer index)
    (unless (and (buffer? buffer)
                 (integer? index) (exact? index)
                 (not (negative? index)))
      (assertion-violation
        'buffer-result-item-marked?
        "expected a Buffer and result index"
        buffer index))
    (and (memv index (buffer-result-marked-indices buffer)) #t))

  (define (buffer-set-result-item-marked! buffer index marked?)
    (unless (and (buffer? buffer)
                 (integer? index) (exact? index)
                 (not (negative? index))
                 (boolean? marked?))
      (assertion-violation
        'buffer-set-result-item-marked!
        "invalid result mark mutation"
        buffer index marked?))
    (unless (exists
              (lambda (range) (= (caddr range) index))
              (buffer-text-property-ranges buffer 'result-index))
      (editor-user-error
        'buffer-item.mark "Result item no longer exists" index))
    (let ([marks
            (filter
              (lambda (candidate) (not (= candidate index)))
              (buffer-result-marked-indices buffer))])
      (result-buffer-state-marked-indices-set!
        (require-result-state buffer 'buffer-set-result-item-marked!)
        (if marked?
            (list-sort < (cons index marks))
            marks)))
    marked?)

  (define (buffer-clear-result-marks! buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-clear-result-marks! "expected a Buffer" buffer))
    (result-buffer-state-marked-indices-set!
      (require-result-state buffer 'buffer-clear-result-marks!) '())
    buffer)

  (define (buffer-result-marked-items buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-marked-items "expected a Buffer" buffer))
    (fold-right
      (lambda (range items)
        (let ([index (caddr range)])
          (if (buffer-result-item-marked? buffer index)
              (let ([item
                      (buffer-text-property-ref
                        buffer (car range) 'result-item #f)])
                (if item (cons (cons index item) items) items))
              items)))
      '()
      (buffer-text-property-ranges buffer 'result-index)))

  (define (result-entry-key interface buffer range)
    (let* ([index (caddr range)]
           [item
             (buffer-text-property-ref
               buffer (car range) 'result-item #f)])
      (and item
           (list
             index
             (car range)
             item
             ((result-buffer-interface-item-key interface)
              buffer item index)))))

  (define (result-entries buffer interface)
    (fold-right
      (lambda (range entries)
        (let ([entry (result-entry-key interface buffer range)])
          (if entry (cons entry entries) entries)))
      '()
      (buffer-text-property-ranges buffer 'result-index)))

  (define (capture-result-selection buffer interface)
    (let* ([entries (result-entries buffer interface)]
           [current-index
             (buffer-result-current-index buffer)]
           [current
             (and current-index
                  (find
                    (lambda (entry) (= (car entry) current-index))
                    entries))]
           [marks (buffer-result-marked-indices buffer)])
      (list
        (and current (list-ref current 3))
        current-index
        (fold-right
          (lambda (entry keys)
            (if (memv (car entry) marks)
                (cons (list-ref entry 3) keys)
                keys))
          '()
          entries))))

  (define (%buffer-reconcile-result-selection! editor buffer finalize?)
    (unless (and (editor? editor) (buffer? buffer))
      (assertion-violation
        'buffer-reconcile-result-selection!
        "expected an Editor and Buffer"
        editor buffer))
    (let ([interface (buffer-result-interface-ref buffer)])
      (unless interface
        (editor-user-error
          'buffer-reconcile-result-selection!
          "Buffer has no result interface"))
      (let* ([entries (result-entries buffer interface)]
             [state
               (require-result-state
                 buffer 'buffer-reconcile-result-selection!)]
             [current-key
               (result-buffer-state-restore-current-key state)]
             [old-index
               (result-buffer-state-restore-current-index state)]
             [mark-keys
               (result-buffer-state-restore-mark-keys state)]
             [matched-current
               (and current-key
                    (find
                      (lambda (entry)
                        (equal? (list-ref entry 3) current-key))
                      entries))]
             [current
               (or
                 matched-current
                 (and finalize?
                      old-index
                      (pair? entries)
                      (list-ref
                        entries
                        (min old-index (- (length entries) 1)))))]
             [marked-indices
               (fold-right
                 (lambda (entry indices)
                   (if (exists
                         (lambda (key)
                           (equal? (list-ref entry 3) key))
                         mark-keys)
                       (cons (car entry) indices)
                       indices))
                 '()
                 entries)])
        (unless (null? mark-keys)
          (result-buffer-state-marked-indices-set!
            (require-result-state
              buffer 'buffer-reconcile-result-selection!)
            marked-indices))
        (when finalize?
          (result-buffer-state-restore-mark-keys-set! state '()))
        (when current
          (let ([index (car current)] [position (cadr current)])
            (buffer-set-result-current-index! buffer index)
            (result-buffer-state-restore-current-key-set! state #f)
            (result-buffer-state-restore-current-index-set! state #f)
            (for-each
              (lambda (view)
                (when (eq? (view-buffer view) buffer)
                  (view-set-caret! view position)
                  (ensure-view-visible! view)))
              (editor-views editor))))
        (and current #t))))

  (define buffer-reconcile-result-selection!
    (case-lambda
      [(editor buffer)
       (%buffer-reconcile-result-selection! editor buffer #f)]
      [(editor buffer finalize?)
       (unless (boolean? finalize?)
         (assertion-violation
           'buffer-reconcile-result-selection!
           "finalize flag must be a boolean"
           finalize?))
       (%buffer-reconcile-result-selection!
         editor buffer finalize?)]))

  (define result-producer-states
    '(idle running ready failed cancelled))

  (define (buffer-set-result-producer-state! buffer state)
    (unless (and (buffer? buffer) (memq state result-producer-states))
      (assertion-violation
        'buffer-set-result-producer-state!
        "expected a Result producer state"
        buffer state))
    (unless (buffer-result-interface-ref buffer)
      (assertion-violation
        'buffer-set-result-producer-state!
        "Buffer has no result interface"
        buffer))
    (when (eq? state 'running)
      (buffer-set-result-producer-stop-invoked! buffer #f))
    (result-buffer-state-producer-state-set!
      (require-result-state buffer 'buffer-set-result-producer-state!)
      state)
    state)

  (define (buffer-result-producer-state buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-producer-state "expected a Buffer" buffer))
    (result-buffer-state-producer-state
      (require-result-state buffer 'buffer-result-producer-state)))

  (define (buffer-result-producer-stop-invoked? buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-producer-stop-invoked? "expected a Buffer" buffer))
    (result-buffer-state-producer-stop-invoked?
      (require-result-state
        buffer 'buffer-result-producer-stop-invoked?)))

  (define (buffer-set-result-producer-stop-invoked! buffer value)
    (unless (and (buffer? buffer) (boolean? value))
      (assertion-violation
        'buffer-set-result-producer-stop-invoked!
        "expected a Buffer and boolean"
        buffer value))
    (result-buffer-state-producer-stop-invoked?-set!
      (require-result-state
        buffer 'buffer-set-result-producer-stop-invoked!)
      value)
    value)

  (define (buffer-result-current-index buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-current-index "expected a Buffer" buffer))
    (result-buffer-state-current-index
      (require-result-state buffer 'buffer-result-current-index)))

  (define (buffer-set-result-current-index! buffer index)
    (unless (and (buffer? buffer)
                 (or (not index)
                     (and (integer? index) (exact? index)
                          (not (negative? index)))))
      (assertion-violation
        'buffer-set-result-current-index!
        "expected a Buffer and optional non-negative index"
        buffer index))
    (result-buffer-state-current-index-set!
      (require-result-state buffer 'buffer-set-result-current-index!)
      index)
    index)

  (define terminal-result-producer-states
    '(ready failed cancelled))

  (define editor-finish-result-producer!
    (case-lambda
      [(editor buffer state)
       (editor-finish-result-producer!
         editor buffer state #f #f)]
      [(editor buffer state message severity)
       (unless
         (and (editor? editor)
              (buffer? buffer)
              (memq state terminal-result-producer-states)
              (or
                (and (not message)
                     (or (not severity)
                         (memq severity '(info warning error))))
                (and (string? message)
                     (positive? (string-length message))
                     (memq severity '(info warning error)))))
         (assertion-violation
           'editor-finish-result-producer!
           "invalid Result producer outcome"
           editor buffer state message severity))
       (when message
         (editor-append-result-message!
           editor buffer message severity))
       (buffer-reconcile-result-selection! editor buffer #t)
       (buffer-set-result-producer-state! buffer state)
       (editor-invalidate! editor 'chrome)
       buffer]))

  (define (buffer-set-result-refresh! buffer refresh)
    (unless (and (buffer? buffer)
                 (or (not refresh) (procedure? refresh)))
      (assertion-violation
        'buffer-set-result-refresh!
        "expected a Buffer and optional refresh procedure"
        buffer refresh))
    (unless (buffer-result-interface-ref buffer)
      (assertion-violation
        'buffer-set-result-refresh!
        "Buffer has no result interface"
        buffer))
    (result-buffer-state-refresh-set!
      (require-result-state buffer 'buffer-set-result-refresh!) refresh)
    buffer)

  (define (buffer-result-refreshable? buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-refreshable? "expected a Buffer" buffer))
    (procedure?
      (result-buffer-state-refresh
        (require-result-state buffer 'buffer-result-refreshable?))))

  (define (buffer-register-result-action! buffer action)
    (unless (and (buffer? buffer) (result-action? action))
      (assertion-violation
        'buffer-register-result-action!
        "expected a result Buffer and ResultAction"
        buffer action))
    (unless (buffer-result-interface-ref buffer)
      (assertion-violation
        'buffer-register-result-action!
        "Buffer has no result interface"
        buffer))
    (when (memq (result-action-name action) '(refresh close))
      (assertion-violation
        'buffer-register-result-action!
        "action name is reserved by the Result Buffer interface"
        (result-action-name action)))
    (when
      (exists
        (lambda (candidate)
          (eq? (result-panel-action-name candidate)
               (result-action-name action)))
        (result-buffer-state-panel-actions
          (require-result-state buffer 'buffer-register-result-action!)))
      (assertion-violation
        'buffer-register-result-action!
        "item action name conflicts with a panel action"
        (result-action-name action)))
    (result-buffer-state-actions-set!
      (require-result-state buffer 'buffer-register-result-action!)
      (cons
        action
        (filter
          (lambda (candidate)
            (not (eq? (result-action-name candidate)
                      (result-action-name action))))
          (result-buffer-state-actions
            (require-result-state buffer 'buffer-register-result-action!)))))
    action)

  (define (buffer-register-result-panel-action! buffer action)
    (unless (and (buffer? buffer) (result-panel-action? action))
      (assertion-violation
        'buffer-register-result-panel-action!
        "expected a result Buffer and ResultPanelAction"
        buffer action))
    (unless (buffer-result-interface-ref buffer)
      (assertion-violation
        'buffer-register-result-panel-action!
        "Buffer has no result interface"
        buffer))
    (when (memq (result-panel-action-name action) '(refresh close))
      (assertion-violation
        'buffer-register-result-panel-action!
        "action name is reserved by the Result Buffer interface"
        (result-panel-action-name action)))
    (when
      (exists
        (lambda (candidate)
          (eq? (result-action-name candidate)
               (result-panel-action-name action)))
        (result-buffer-state-actions
          (require-result-state buffer 'buffer-register-result-panel-action!)))
      (assertion-violation
        'buffer-register-result-panel-action!
        "panel action name conflicts with an item action"
        (result-panel-action-name action)))
    (result-buffer-state-panel-actions-set!
      (require-result-state buffer 'buffer-register-result-panel-action!)
      (cons
        action
        (filter
          (lambda (candidate)
            (not (eq? (result-panel-action-name candidate)
                      (result-panel-action-name action))))
          (result-buffer-state-panel-actions
            (require-result-state
              buffer 'buffer-register-result-panel-action!)))))
    action)

  (define (registered-result-panel-actions buffer)
    (filter
      (lambda (action)
        ((result-panel-action-applicable? action) buffer))
      (reverse
        (result-buffer-state-panel-actions
          (require-result-state buffer 'buffer-result-panel-actions)))))

  (define (buffer-result-panel-actions buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-panel-actions "expected a Buffer" buffer))
    (unless (buffer-result-interface-ref buffer)
      (assertion-violation
        'buffer-result-panel-actions
        "Buffer has no result interface"
        buffer))
    (append
      (registered-result-panel-actions buffer)
      (if (buffer-result-refreshable? buffer)
          (list
            (make-result-panel-action
              'refresh
              (case (buffer-result-producer-state buffer)
                [(failed) "Retry task"]
                [(cancelled) "Run task again"]
                [(running) "Restart task"]
                [else "Refresh results"])
              (lambda (candidate) #t)
              (lambda (context candidate)
                (refresh-buffer-items context))))
          '())
      (list
        (make-result-panel-action
          'close
          (if (eq? (buffer-result-producer-state buffer) 'running)
              "Cancel and close"
              "Close results")
          (lambda (candidate) #t)
          (lambda (context candidate)
            (quit-buffer-items context))))))

  (define (buffer-result-actions-at buffer position)
    (unless (and (buffer? buffer)
                 (integer? position) (exact? position)
                 (not (negative? position)))
      (assertion-violation
        'buffer-result-actions-at
        "expected a Buffer and non-negative position"
        buffer position))
    (let ([item
            (buffer-text-property-ref
              buffer position 'result-item #f)])
      (if item
          (filter
            (lambda (action)
              ((result-action-applicable? action) buffer item))
            (reverse
              (result-buffer-state-actions
                (require-result-state buffer 'buffer-result-actions-at))))
          '())))

  (define (buffer-result-interface-ref buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-interface-ref "expected a Buffer" buffer))
    (let ([state (buffer-result-state-ref buffer)])
      (and state (result-buffer-state-interface state))))

  (define (editor-note-result-buffer! editor buffer)
    (unless (and (editor? editor) (buffer? buffer)
                 (result-buffer-interface?
                   (buffer-result-interface-ref buffer)))
      (assertion-violation
        'editor-note-result-buffer!
        "expected an Editor and navigable Buffer"
        editor buffer))
    (let ([id (buffer-id buffer)])
      (hashtable-set!
        editor-result-buffers
        editor
        (cons
          id
          (filter
            (lambda (candidate) (not (= candidate id)))
            (hashtable-ref editor-result-buffers editor '())))))
    buffer)

  (define (available-navigation-buffer editor)
    (let ([workbench-id
            (workbench-id (editor-active-workbench editor))])
      (let loop ([ids (hashtable-ref editor-result-buffers editor '())]
                 [retained '()])
        (if (null? ids)
            (begin
              (hashtable-set!
                editor-result-buffers editor (reverse retained))
              #f)
            (let ([buffer
                    (guard (condition [else #f])
                      (editor-buffer-ref editor (car ids)))])
              (if (and buffer
                       (buffer-result-interface-ref buffer)
                       (equal?
                         (buffer-result-workbench-id buffer)
                         workbench-id))
                  (begin
                    (hashtable-set!
                      editor-result-buffers
                      editor
                      (append (reverse retained) ids))
                    buffer)
                  (loop (cdr ids) retained)))))))

  (define (require-interface context who)
    (let* ([buffer (view-buffer (command-context-view context))]
           [interface (buffer-result-interface-ref buffer)])
      (unless (result-buffer-interface? interface)
        (editor-user-error who "Current Buffer is not navigable"))
      (values buffer interface)))

  (define (property-positions buffer)
    (map
      (lambda (range) (cons (car range) (caddr range)))
      (buffer-text-property-ranges buffer 'result-index)))

  (define (editor-append-result-items! editor buffer value ranges)
    (unless
      (and (editor? editor)
           (buffer? buffer)
           (result-buffer-interface? (buffer-result-interface-ref buffer))
           (string? value)
           (list? ranges)
           (for-all
             (lambda (range)
               (and (list? range)
                    (= (length range) 3)
                    (integer? (car range)) (exact? (car range))
                    (integer? (cadr range)) (exact? (cadr range))
                    (<= 0 (car range) (cadr range))
                    (caddr range)))
             ranges))
      (assertion-violation
        'editor-append-result-items!
        "invalid attributed result text"
        editor buffer value ranges))
    (let* ([base (buffer-byte-size buffer)]
           [bytes (string->utf8 value)]
           [size (bytevector-length bytes)]
           [start-index
             (length (buffer-text-property-ranges buffer 'result-index))])
      (for-each
        (lambda (range)
          (unless (<= (cadr range) size)
            (assertion-violation
              'editor-append-result-items!
              "result range exceeds appended text"
              range size)))
        ranges)
      (buffer-replace-range-internal! buffer base base bytes)
      (let loop ([pending ranges] [index start-index])
        (unless (null? pending)
          (let ([range (car pending)])
            (buffer-add-text-properties!
              buffer
              (+ base (car range))
              (+ base (cadr range))
              `((result-item . ,(caddr range))
                (result-index . ,index))))
          (loop (cdr pending) (+ index 1))))
      (editor-invalidate! editor 'document)
      buffer))

  (define (editor-append-result-message! editor buffer message severity)
    (unless
      (and (editor? editor)
           (buffer? buffer)
           (result-buffer-interface? (buffer-result-interface-ref buffer))
           (string? message)
           (positive? (string-length message))
           (memq severity '(info warning error)))
      (assertion-violation
        'editor-append-result-message!
        "invalid Result Buffer message"
        editor buffer message severity))
    (let* ([base (buffer-byte-size buffer)]
           [length (string-length message)]
           [text
             (if (char=? (string-ref message (- length 1)) #\newline)
                 message
                 (string-append message "\n"))])
      (editor-append-result-items! editor buffer text '())
      (buffer-add-text-properties!
        buffer
        base
        (+ base (bytevector-length (string->utf8 text)))
        `((result-message . ,severity)
          (face . ,(case severity
                     [(warning) 'status.warning]
                     [(error) 'status.error]
                     [else 'status.info]))))
      (editor-invalidate! editor 'document)
      buffer))

  (define (buffer-result-base-resource buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-base-resource "expected a Buffer" buffer))
    (let ([state (buffer-result-state-ref buffer)])
      (if state
          (result-buffer-state-base-resource state)
          (buffer-resource buffer))))

  (define (buffer-result-workbench-id buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-workbench-id "expected a Buffer" buffer))
    (let ([state (buffer-result-state-ref buffer)])
      (and state (result-buffer-state-workbench-id state))))

  (define (result-buffer-for-scope editor resource workbench-id)
    (find
      (lambda (candidate)
        (and
          (buffer-result-interface-ref candidate)
          (equal? (buffer-result-base-resource candidate) resource)
          (equal? (buffer-result-workbench-id candidate) workbench-id)))
      (editor-buffers editor)))

  (define (allocate-result-resource editor base)
    (if (not (editor-buffer-for-resource editor base))
        base
        (let loop ([suffix 2])
          (let ([candidate
                  (string-append
                    base "<" (number->string suffix) ">")])
            (if (editor-buffer-for-resource editor candidate)
                (loop (+ suffix 1))
                candidate)))))

  (define (editor-present-result-buffer!
            editor resource mode text origin-view-id interface)
    (unless (and (editor? editor)
                 (string? resource) (positive? (string-length resource))
                 (symbol? mode)
                 (string? text)
                 (integer? origin-view-id) (exact? origin-view-id)
                 (positive? origin-view-id)
                 (result-buffer-interface? interface))
      (assertion-violation
        'editor-present-result-buffer!
        "invalid result Buffer presentation"
        editor resource mode text origin-view-id interface))
    (let* ([origin-workbench
             (editor-workbench-for-view editor origin-view-id)]
           [workbench-id (workbench-id origin-workbench)]
           [existing
             (result-buffer-for-scope editor resource workbench-id)]
           [buffer
             (cond
               [(not existing)
                (let ([created
                        (editor-create-buffer!
                          editor
                          (allocate-result-resource editor resource)
                          mode
                          ""
                          (editor-view-resource-context
                            editor origin-view-id))])
                  created)]
               [(buffer-result-interface-ref existing) existing]
               [else
                (editor-user-error
                  'editor-present-result-buffer!
                  "Result resource belongs to another Buffer"
                  resource)])]
           [preserved
             (and
               existing
               (buffer-result-interface-ref existing)
               (capture-result-selection
                 existing (buffer-result-interface-ref existing)))])
      (when existing
        (buffer-capture-result-group-folds! editor buffer))
      (buffer-set-major-mode! buffer mode)
      (buffer-clear-text-properties! buffer)
      (buffer-replace-range-internal!
        buffer 0 (buffer-byte-size buffer) (string->utf8 text))
      (buffer-set-result-interface! buffer interface)
      (let ([state
              (require-result-state
                buffer 'editor-present-result-buffer!)])
        (result-buffer-state-base-resource-set! state resource)
        (result-buffer-state-workbench-id-set! state workbench-id))
      (when preserved
        (let ([state
                (require-result-state
                  buffer 'editor-present-result-buffer!)])
          (result-buffer-state-restore-current-key-set!
            state (car preserved))
          (result-buffer-state-restore-current-index-set!
            state (cadr preserved))
          (result-buffer-state-restore-mark-keys-set!
            state (caddr preserved))))
      (editor-note-result-buffer! editor buffer)
      (let* ([request
               (make-display-request
                 (buffer-id buffer) 'tools origin-view-id #f
                 (editor-view-resource-context editor origin-view-id))]
             [plan (editor-plan-display editor request)]
             [visible-before?
               (exists
                 (lambda (candidate)
                   (eq? (view-buffer candidate) buffer))
                 (editor-views editor))]
             [target-workbench
               (editor-workbench-ref
                 editor (display-plan-workbench-id plan))]
             [target-leaf
               (window-node-find
                 (workbench-layout target-workbench)
                 (display-plan-window-id plan))]
             [target-view
               (and
                 (window-leaf? target-leaf)
                 (editor-view-ref
                   editor (window-leaf-view-id target-leaf)))]
             [previous-buffer-id
               (and target-view (buffer-id (view-buffer target-view)))]
             [previous-context
               (and target-view (view-resource-context target-view))]
             [view (editor-display-buffer! editor request)])
        (unless visible-before?
          (result-buffer-state-display-restoration-set!
            (require-result-state
              buffer 'editor-present-result-buffer!)
            (make-result-display-restoration
              (display-plan-action plan)
              (view-id view)
              previous-buffer-id
              previous-context)))
        (view-set-caret! view 0)
        (ensure-view-visible! view))
      (editor-invalidate! editor 'document)
      buffer))

  (define (editor-buffer-if-present editor id)
    (and id
         (find
           (lambda (buffer) (= (buffer-id buffer) id))
           (editor-buffers editor))))

  (define (editor-dismiss-result-buffer! editor buffer origin-view)
    (unless (and (editor? editor) (buffer? buffer)
                 (or (not origin-view) (view? origin-view)))
      (assertion-violation
        'editor-dismiss-result-buffer!
        "expected an Editor, result Buffer, and optional origin View"
        editor buffer origin-view))
    (let* ([result-view
             (find
               (lambda (view) (eq? (view-buffer view) buffer))
               (editor-views editor))]
           [restoration
             (result-buffer-state-display-restoration
               (require-result-state
                 buffer 'editor-dismiss-result-buffer!))]
           [restorable?
             (and
               result-view
               (result-display-restoration? restoration)
               (= (view-id result-view)
                  (result-display-restoration-view-id restoration)))])
      (cond
        [(and restorable?
              (eq? (result-display-restoration-action restoration) 'replace)
              (editor-buffer-if-present
                editor
                (result-display-restoration-previous-buffer-id restoration)))
         =>
         (lambda (previous-buffer)
           (editor-set-view-buffer!
             editor
             (view-id result-view)
             (buffer-id previous-buffer))
           (editor-set-view-resource-context!
             editor
             (view-id result-view)
             (result-display-restoration-previous-resource-context
               restoration)))]
        [(and restorable?
              (eq? (result-display-restoration-action restoration) 'split)
              (> (length (editor-window-leaves editor)) 1))
         (editor-select-view-window! editor (view-id result-view))
         (editor-delete-window! editor)]
        [(and restorable?
              (eq? (result-display-restoration-action restoration) 'split)
              (editor-buffer-if-present
                editor
                (result-display-restoration-previous-buffer-id restoration)))
         =>
         (lambda (previous-buffer)
           (editor-set-view-buffer!
             editor
             (view-id result-view)
             (buffer-id previous-buffer))
           (editor-set-view-resource-context!
             editor
             (view-id result-view)
             (result-display-restoration-previous-resource-context
               restoration)))]
        [result-view
         (if (> (length (editor-window-leaves editor)) 1)
             (begin
               (editor-select-view-window! editor (view-id result-view))
               (editor-delete-window! editor))
             (when origin-view
               (editor-set-view-buffer!
                 editor
                 (view-id result-view)
                 (buffer-id (view-buffer origin-view)))))])
      (when (and origin-view
                 (exists (lambda (view) (eq? view origin-view))
                         (editor-views editor)))
        (editor-select-view-window! editor (view-id origin-view)))
      (unless
        (exists
          (lambda (view) (eq? (view-buffer view) buffer))
          (editor-views editor))
        (editor-remove-buffer! editor (buffer-id buffer)))))

  (define (property-starts buffer property)
    (map car (buffer-text-property-ranges buffer property)))

  (define (result-group-ranges buffer)
    (let ([groups
            (buffer-text-property-ranges buffer 'result-group)]
          [size (buffer-byte-size buffer)])
      (let loop ([remaining groups] [result '()])
        (if (null? remaining)
            (reverse result)
            (let* ([group (car remaining)]
                   [next (and (pair? (cdr remaining)) (cadr remaining))])
              (loop
                (cdr remaining)
                (cons
                  (list
                    (car group)
                    (cadr group)
                    (if next (car next) size)
                    (caddr group))
                  result)))))))

  (define (result-group-fold? fold)
    (and (fold? fold)
         (eq? (fold-capture fold) 'result-group)))

  (define (result-group-folded? view group)
    (exists
      (lambda (fold)
        (and (result-group-fold? fold)
             (= (fold-start fold) (cadr group))
             (= (fold-end fold) (caddr group))))
      (view-folds view)))

  (define (result-position-visible? view position)
    (or (not view)
        (not
          (exists
            (lambda (fold)
              (and (result-group-fold? fold)
                   (<= (fold-start fold) position)
                   (< position (fold-end fold))))
            (view-folds view)))))

  (define (visible-property-positions buffer view)
    (filter
      (lambda (entry)
        (result-position-visible? view (car entry)))
      (property-positions buffer)))

  (define (result-group-at buffer position)
    (let loop ([groups (result-group-ranges buffer)] [found #f])
      (cond
        [(null? groups) found]
        [(< position (caar groups)) found]
        [(< position (caddar groups)) (car groups)]
        [else (loop (cdr groups) (car groups))])))

  (define (result-group-labels-for-view buffer view)
    (fold-right
      (lambda (group labels)
        (if (result-group-folded? view group)
            (cons (cadddr group) labels)
            labels))
      '()
      (result-group-ranges buffer)))

  (define (buffer-capture-result-group-folds! editor buffer)
    (result-buffer-state-pending-collapsed-groups-set!
      (require-result-state
        buffer 'buffer-capture-result-group-folds!)
      (fold-right
        (lambda (view entries)
          (if (eq? (view-buffer view) buffer)
              (cons
                (cons
                  (view-id view)
                  (result-group-labels-for-view buffer view))
                entries)
              entries))
        '()
        (editor-views editor))))

  (define (replace-result-group-folds! editor buffer view labels)
    (let* ([groups (result-group-ranges buffer)]
           [retained
             (filter
               (lambda (fold) (not (result-group-fold? fold)))
               (view-folds view))]
           [folds
             (fold-right
               (lambda (group result)
                 (if (and (member (cadddr group) labels)
                          (< (cadr group) (caddr group)))
                     (cons
                       (make-fold
                         (buffer-document buffer)
                         (cadr group)
                         (caddr group)
                         'result-group
                         'result-group)
                       result)
                     result))
               retained
               groups)])
      (editor-replace-view-folds! editor (view-id view) folds)))

  (define (editor-reconcile-result-group-folds! editor buffer)
    (let ([pending
            (result-buffer-state-pending-collapsed-groups
              (require-result-state
                buffer 'editor-reconcile-result-group-folds!))])
      (for-each
        (lambda (entry)
          (let ([view
                  (find
                    (lambda (candidate)
                      (= (view-id candidate) (car entry)))
                    (editor-views editor))])
            (when (and view (eq? (view-buffer view) buffer))
              (replace-result-group-folds!
                editor buffer view (cdr entry)))))
        pending)
      (result-buffer-state-pending-collapsed-groups-set!
        (require-result-state
          buffer 'editor-reconcile-result-group-folds!)
        '())))

  (define (selected-item context who)
    (let-values ([(buffer interface) (require-interface context who)])
      (let* ([position (view-caret (command-context-view context))]
             [item
               (buffer-text-property-ref
                 buffer position 'result-item #f)]
             [index
               (buffer-text-property-ref
                 buffer position 'result-index #f)])
        (unless (and item (integer? index) (exact? index))
          (editor-user-error who "Point is not on a navigable item"))
        (buffer-set-result-current-index! buffer index)
        (values buffer interface item index))))

  (define (current-result-entry buffer view)
    (let ([item
            (buffer-text-property-ref
              buffer (view-caret view) 'result-item #f)]
          [index
            (buffer-text-property-ref
              buffer (view-caret view) 'result-index #f)])
      (and item
           (integer? index) (exact? index)
           (cons index item))))

  (define (action-applicable-to-entry? action buffer entry)
    ((result-action-applicable? action) buffer (cdr entry)))

  (define (available-actions context who)
    (let-values ([(buffer interface) (require-interface context who)])
      (let* ([view (command-context-view context)]
             [current (current-result-entry buffer view)]
             [marked (buffer-result-marked-items buffer)]
             [actions
               (filter
                 (lambda (action)
                   (let ([batch (result-action-batch-invoke action)])
                     (if (and batch (pair? marked))
                         (for-all
                           (lambda (entry)
                             (action-applicable-to-entry?
                               action buffer entry))
                           marked)
                         (and current
                              (action-applicable-to-entry?
                                action buffer current)))))
                   (reverse
                     (result-buffer-state-actions
                       (require-result-state
                         buffer 'buffer-item.actions))))])
        (values buffer current marked actions))))

  (define (invoke-buffer-item-action context name)
    (unless (symbol? name)
      (assertion-violation
        'invoke-buffer-item-action "action name must be a symbol" name))
    (let-values ([(buffer current marked actions)
                  (available-actions context 'buffer-item.action)])
      (let ([action
              (find
                (lambda (candidate)
                  (eq? (result-action-name candidate) name))
                actions)])
        (unless action
          (editor-user-error
            'buffer-item.action
            "Action is not available for the item at point"
            name))
        (let ([batch (result-action-batch-invoke action)])
          (if (and batch (pair? marked))
              (batch context buffer marked)
              ((result-action-invoke action)
               context buffer (cdr current) (car current)))))))

  (define (invoke-result-panel-action context name)
    (unless (symbol? name)
      (assertion-violation
        'invoke-result-panel-action "action name must be a symbol" name))
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-panel.action)])
      (let ([action
              (find
                (lambda (candidate)
                  (eq? (result-panel-action-name candidate) name))
                (buffer-result-panel-actions buffer))])
        (unless action
          (editor-user-error
            'buffer-panel.action
            "Action is not available for the current result Buffer"
            name))
        ((result-panel-action-invoke action) context buffer))))

  (define (stop-result-producer context)
    (invoke-result-panel-action context 'stop))

  (define (set-selected-item-mark! context marked?)
    (let-values ([(buffer interface item index)
                  (selected-item context 'buffer-item.mark)])
      (buffer-set-result-item-marked! buffer index marked?)
      (editor-invalidate! (command-context-editor context) 'overlay)
      '()))

  (define (toggle-selected-item-mark! context)
    (let-values ([(buffer interface item index)
                  (selected-item context 'buffer-item.toggle-mark)])
      (buffer-set-result-item-marked!
        buffer index (not (buffer-result-item-marked? buffer index)))
      (editor-invalidate! (command-context-editor context) 'overlay)
      '()))

  (define (clear-item-marks! context)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.unmark-all)])
      (buffer-clear-result-marks! buffer)
      (editor-invalidate! (command-context-editor context) 'overlay)
      '()))

  (define (result-action-name* action)
    (if (result-panel-action? action)
        (result-panel-action-name action)
        (result-action-name action)))

  (define (result-action-label* action)
    (if (result-panel-action? action)
        (result-panel-action-label action)
        (result-action-label action)))

  (define (result-action-choice-source actions)
    (let ([items
            (map
              (lambda (action)
                (let* ([name (result-action-name* action)]
                       [label (result-action-label* action)])
                  (make-completion-item
                    name
                    'result-action
                    label
                    label
                    label
                    (symbol->string name)
                    #f
                    name)))
              actions)])
      (make-choice-source
        'result-action
        '((category . result-action)
          (styles . (fzf))
          (preselect . #t))
        (lambda (input point) (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (item)
              (string=? value (completion-item-insert-text item)))
            items))
        (lambda (generation) #f))))

  (define result-action-reader
    (interactive-completing-read
      "Action: "
      (lambda (context)
        (let-values ([(buffer current marked item-actions)
                      (available-actions context 'buffer-item.actions)])
          (result-action-choice-source
            (append
              item-actions
              (buffer-result-panel-actions buffer)))))
      'must-match
      'result-action
      ""
      #f
      (lambda (context result)
        (let ([candidate (prompt-result-candidate result)])
          (unless (and candidate
                       (symbol? (completion-item-payload candidate)))
            (editor-user-error
              'buffer-item.actions "No result action was selected"))
          (list (completion-item-payload candidate))))))

  (define-command (choose-buffer-item-action context name)
    "Choose and invoke an action for the result item or result Buffer."
    (interactive result-action-reader)
    (let* ([buffer (view-buffer (command-context-view context))]
           [panel-action
             (find
               (lambda (candidate)
                 (eq? (result-panel-action-name candidate) name))
               (buffer-result-panel-actions buffer))])
      (if panel-action
          (invoke-result-panel-action context name)
          (invoke-buffer-item-action context name))))

  (define (refresh-buffer-items context)
    (let* ([buffer (view-buffer (command-context-view context))]
           [refresh
             (result-buffer-state-refresh
               (require-result-state buffer 'buffer-item.refresh))])
      (when (or (buffer-local-ref buffer 'result-edit-active? #f)
                (buffer-local-ref buffer 'result-edit-pending #f))
        (editor-user-error
          'buffer-item.refresh
          "Finish or discard Result Buffer edits before refreshing"))
      (unless (procedure? refresh)
        (editor-user-error
          'buffer-item.refresh "Current result Buffer cannot be refreshed"))
      (refresh context buffer)))

  (define (activate-selected context disposition)
    (let-values ([(buffer interface item index)
                  (selected-item context 'buffer-item.activate)])
      (editor-note-result-buffer! (command-context-editor context) buffer)
      ((result-buffer-interface-activate interface)
       context buffer item index disposition)))

  (define (bounded-index current delta size cyclic?)
    (let ([candidate (+ current delta)])
      (cond
        [cyclic? (mod candidate size)]
        [(< candidate 0) 0]
        [(>= candidate size) (- size 1)]
        [else candidate])))

  (define (move-buffer-item context buffer interface view delta)
      (let ([positions (visible-property-positions buffer view)])
        (if (null? positions)
            (begin
              (editor-set-status-message!
                (command-context-editor context) "No navigable items")
              '())
            (let* ([current
                     (if view
                         (buffer-text-property-ref
                           buffer (view-caret view) 'result-index #f)
                         (buffer-result-current-index buffer))]
                   [current-visible-index
                     (and
                       current
                       (let loop ([remaining positions] [index 0])
                         (cond
                           [(null? remaining) #f]
                           [(= (cdar remaining) current) index]
                           [else
                            (loop (cdr remaining) (+ index 1))])))]
                   [base
                     (cond
                       [current-visible-index current-visible-index]
                       [(and view (positive? delta))
                        (let loop
                          ([remaining positions]
                           [index 0]
                           [last -1])
                          (cond
                            [(null? remaining) last]
                            [(<= (caar remaining) (view-caret view))
                             (loop
                               (cdr remaining) (+ index 1) index)]
                            [else last]))]
                       [(and view (negative? delta))
                        (let loop ([remaining positions] [index 0])
                          (cond
                            [(null? remaining) (length positions)]
                            [(>= (caar remaining) (view-caret view)) index]
                            [else
                             (loop (cdr remaining) (+ index 1))]))]
                       [else
                        (if (positive? delta) -1 (length positions))])]
                   [target
                     (bounded-index
                       base delta (length positions)
                       (result-buffer-interface-cyclic? interface))]
                   [entry (list-ref positions target)]
                   [position (car entry)]
                   [index (cdr entry)]
                   [item
                     (buffer-text-property-ref
                       buffer position 'result-item #f)])
              (when view
                (view-set-caret! view position)
                (ensure-view-visible! view))
              (buffer-set-result-current-index! buffer index)
              ((result-buffer-interface-activate interface)
               context buffer item index 'preview)))))

  (define (move-item context delta)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.next)])
      (editor-note-result-buffer! (command-context-editor context) buffer)
      (move-buffer-item
        context buffer interface (command-context-view context) delta)))

  (define (index-of-position positions position)
    (let loop ([items positions] [index 0] [found #f])
      (cond
        [(null? items) found]
        [(<= (car items) position)
         (loop (cdr items) (+ index 1) index)]
        [else found])))

  (define (first-item-after positions position limit)
    (find
      (lambda (entry)
        (and (> (car entry) position)
             (or (not limit) (< (car entry) limit))))
      positions))

  (define (move-buffer-group context buffer interface view direction)
    (let* ([groups (property-starts buffer 'result-group)]
           [items (visible-property-positions buffer view)])
      (if (or (null? groups) (null? items))
          (begin
            (editor-set-status-message!
              (command-context-editor context) "No result groups")
            '())
          (let* ([position
                   (if view
                       (view-caret view)
                       (let ([index
                               (buffer-result-current-index buffer)])
                         (if (and index (< index (length items)))
                             (car (list-ref items index))
                             0)))]
                 [current (index-of-position groups position)]
                 [base
                   (if current
                       current
                       (if (positive? direction) -1 (length groups)))]
                 [target
                   (bounded-index
                     base direction (length groups)
                     (result-buffer-interface-cyclic? interface))]
                 [group-start (list-ref groups target)]
                 [group-limit
                   (and (< (+ target 1) (length groups))
                        (list-ref groups (+ target 1)))]
                 [entry
                   (first-item-after items group-start group-limit)])
            (if (not entry)
                (begin
                  (editor-set-status-message!
                    (command-context-editor context)
                    "Result group contains no items")
                  '())
                (let* ([item-position (car entry)]
                       [index (cdr entry)]
                       [item
                         (buffer-text-property-ref
                           buffer item-position 'result-item #f)])
                  (when view
                    (view-set-caret! view item-position)
                    (ensure-view-visible! view))
                  (buffer-set-result-current-index! buffer index)
                  ((result-buffer-interface-activate interface)
                   context buffer item index 'preview)))))))

  (define (move-group context direction)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.next-group)])
      (editor-note-result-buffer! (command-context-editor context) buffer)
      (move-buffer-group
        context buffer interface (command-context-view context) direction)))

  (define (quit-buffer-items context)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.quit)])
      (when (buffer-local-ref buffer 'result-edit-active? #f)
        (editor-user-error
          'buffer-item.quit
          "Apply or discard Result Buffer edits before quitting"))
      ((result-buffer-interface-quit interface) context buffer)))

  (define (set-result-group-folded! context folded?)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-group.toggle)])
      (let* ([editor (command-context-editor context)]
             [view (command-context-view context)]
             [group (result-group-at buffer (view-caret view))])
        (unless group
          (editor-user-error
            'buffer-group.toggle "Point is not in a result group"))
        (let* ([label (cadddr group)]
               [labels (result-group-labels-for-view buffer view)]
               [next-labels
                 (if folded?
                     (if (member label labels)
                         labels
                         (cons label labels))
                     (filter
                       (lambda (candidate)
                         (not (equal? candidate label)))
                       labels))])
          (replace-result-group-folds!
            editor buffer view next-labels)
          (view-set-caret! view (car group))
          (ensure-view-visible! view)
          '()))))

  (define (toggle-result-group context)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-group.toggle)])
      (let* ([view (command-context-view context)]
             [group (result-group-at buffer (view-caret view))])
        (unless group
          (editor-user-error
            'buffer-group.toggle "Point is not in a result group"))
        (set-result-group-folded!
          context (not (result-group-folded? view group))))))

  (define (set-all-result-groups-folded! context folded?)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-group.fold-all)])
      (let ([editor (command-context-editor context)]
            [view (command-context-view context)])
        (replace-result-group-folds!
          editor
          buffer
          view
          (if folded?
              (map cadddr (result-group-ranges buffer))
              '()))
        '())))

  (define (visit-or-toggle-result-group context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)])
      (if (buffer-text-property-ref
            buffer (view-caret view) 'result-group #f)
          (toggle-result-group context)
          (activate-selected context 'select-and-close))))

  (define (global-navigation-context context)
    (let* ([editor (command-context-editor context)]
           [buffer (available-navigation-buffer editor)]
           [view
                   (and buffer
                        (find
                          (lambda (candidate)
                            (and
                              (=
                                (view-workbench-id candidate)
                                (buffer-result-workbench-id buffer))
                              (=
                                (buffer-id (view-buffer candidate))
                                (buffer-id buffer))))
                          (editor-views editor)))])
      (unless (and buffer
                   (buffer-result-interface-ref buffer))
        (editor-user-error
          'buffer-item.next-global
          "No navigable result Buffer"))
      (values buffer view)))

  (define (move-global-item context direction)
    (let ([active-buffer
            (view-buffer (command-context-view context))])
      (if (buffer-result-interface-ref active-buffer)
          (move-item context (* direction (command-context-count context)))
          (let-values ([(buffer view) (global-navigation-context context)])
            (move-buffer-item
              context
              buffer
              (buffer-result-interface-ref buffer)
              view
              (* direction (command-context-count context)))))))

  (define (install-result-buffer-commands! editor)
    (for-each
      (lambda (spec)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car spec) (cadr spec) (caddr spec))))
      (list
        (list 'buffer-item.next
              (lambda (context)
                (move-item context (command-context-count context)))
              "Move to and preview the next navigable Buffer item.")
        (list 'buffer-item.previous
              (lambda (context)
                (move-item context (- (command-context-count context))))
              "Move to and preview the previous navigable Buffer item.")
        (list 'buffer-item.next-group
              (lambda (context)
                (move-group context (command-context-count context)))
              "Move to and preview the next result group.")
        (list 'buffer-item.previous-group
              (lambda (context)
                (move-group context (- (command-context-count context))))
              "Move to and preview the previous result group.")
        (list 'buffer-item.activate
              (lambda (context) (activate-selected context 'select))
              "Activate the navigable Buffer item at point.")
        (list 'buffer-item.preview
              (lambda (context) (activate-selected context 'preview))
              "Preview the navigable Buffer item at point.")
        (list 'buffer-item.activate-and-close
              (lambda (context) (activate-selected context 'select-and-close))
              "Activate the item at point and close its presenting Buffer.")
        (list 'buffer-item.visit-or-toggle-group
              visit-or-toggle-result-group
              "Visit the item at point or toggle its result group.")
        (list 'buffer-group.toggle
              toggle-result-group
              "Toggle the result group containing point.")
        (list 'buffer-group.fold
              (lambda (context)
                (set-result-group-folded! context #t))
              "Collapse the result group containing point.")
        (list 'buffer-group.unfold
              (lambda (context)
                (set-result-group-folded! context #f))
              "Expand the result group containing point.")
        (list 'buffer-group.fold-all
              (lambda (context)
                (set-all-result-groups-folded! context #t))
              "Collapse every group in the current result Buffer.")
        (list 'buffer-group.unfold-all
              (lambda (context)
                (set-all-result-groups-folded! context #f))
              "Expand every group in the current result Buffer.")
        (list 'buffer-item.quit
              quit-buffer-items
              "Close the current navigable Buffer.")
        (list 'buffer-item.refresh
              refresh-buffer-items
              "Regenerate the current result Buffer from its producer.")
        (list 'buffer-item.actions
              choose-buffer-item-action
              "Choose an action available for the result item at point.")
        (list 'buffer-panel.stop
              stop-result-producer
              "Stop the producer for the current Result Buffer without closing it.")
        (list 'buffer-item.mark
              (lambda (context) (set-selected-item-mark! context #t))
              "Mark the result item at point.")
        (list 'buffer-item.unmark
              (lambda (context) (set-selected-item-mark! context #f))
              "Unmark the result item at point.")
        (list 'buffer-item.toggle-mark
              toggle-selected-item-mark!
              "Toggle the mark on the result item at point.")
        (list 'buffer-item.unmark-all
              clear-item-marks!
              "Clear all marks in the current result Buffer.")
        (list 'buffer-item.next-global
              (lambda (context) (move-global-item context 1))
              "Advance the most recent visible navigable Buffer.")
        (list 'buffer-item.previous-global
              (lambda (context) (move-global-item context -1))
              "Move backward in the most recent visible navigable Buffer.")
        (list 'xref.next-location
              (lambda (context) (move-global-item context 1))
              "Advance the most recent visible navigable Buffer.")
        (list 'xref.previous-location
              (lambda (context) (move-global-item context -1))
              "Move backward in the most recent visible navigable Buffer.")))
    editor)
)
