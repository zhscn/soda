(library (soda editor result-buffer)
  (export make-result-buffer-interface
          result-buffer-interface?
          result-buffer-interface-cyclic?
          make-result-action
          result-action?
          result-action-name
          result-action-label
          buffer-register-result-action!
          buffer-result-actions-at
          invoke-buffer-item-action
          buffer-set-result-interface!
          buffer-result-interface-ref
          editor-note-result-buffer!
          editor-present-result-buffer!
          editor-append-result-items!
          install-result-buffer-commands!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor resource-context)
          (soda editor state)
          (soda editor window-runtime))

  (define editor-result-buffers (make-weak-eq-hashtable))

  (define-record-type
    (result-buffer-interface
      %make-result-buffer-interface
      result-buffer-interface?)
    (fields cyclic?
            activate
            quit))

  (define (make-result-buffer-interface cyclic? activate quit)
    (unless (and (boolean? cyclic?)
                 (procedure? activate)
                 (procedure? quit))
      (assertion-violation
        'make-result-buffer-interface
        "invalid Buffer navigation interface"
        cyclic? activate quit))
    (%make-result-buffer-interface cyclic? activate quit))

  (define-record-type
    (result-action %make-result-action result-action?)
    (fields name label applicable? invoke))

  (define (make-result-action name label applicable? invoke)
    (unless (and (symbol? name)
                 (string? label)
                 (procedure? applicable?)
                 (procedure? invoke))
      (assertion-violation
        'make-result-action
        "invalid result action"
        name label applicable? invoke))
    (%make-result-action name label applicable? invoke))

  (define (buffer-set-result-interface! buffer interface)
    (unless (and (buffer? buffer)
                 (result-buffer-interface? interface))
      (assertion-violation
        'buffer-set-result-interface!
        "expected a Buffer and navigation interface"
        buffer interface))
    (buffer-set-local! buffer 'result-buffer-interface interface)
    (buffer-set-local! buffer 'result-current-index #f)
    (buffer-set-local! buffer 'result-actions '())
    buffer)

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
    (buffer-set-local!
      buffer
      'result-actions
      (cons
        action
        (filter
          (lambda (candidate)
            (not (eq? (result-action-name candidate)
                      (result-action-name action))))
          (buffer-local-ref buffer 'result-actions '()))))
    action)

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
            (reverse (buffer-local-ref buffer 'result-actions '())))
          '())))

  (define (buffer-result-interface-ref buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-result-interface-ref "expected a Buffer" buffer))
    (buffer-local-ref buffer 'result-buffer-interface #f))

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
            (if (and buffer (buffer-result-interface-ref buffer))
                (begin
                  (hashtable-set!
                    editor-result-buffers
                    editor
                    (append (reverse retained) ids))
                  buffer)
                (loop (cdr ids) retained))))))

  (define (require-interface context who)
    (let* ([buffer (view-buffer (command-context-view context))]
           [interface (buffer-result-interface-ref buffer)])
      (unless (result-buffer-interface? interface)
        (editor-user-error who "Current Buffer is not navigable"))
      (values buffer interface)))

  (define (property-positions buffer interface)
    (map
      (lambda (range) (cons (car range) (caddr range)))
      (buffer-text-property-ranges buffer 'result-index)))

  (define (buffer-size buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

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
    (let* ([base (buffer-size buffer)]
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
    (let* ([existing
             (or
               (editor-buffer-for-resource editor resource)
               (find
                 (lambda (candidate)
                   (and (buffer-result-interface-ref candidate)
                        (equal? (buffer-resource candidate) resource)))
                 (editor-buffers editor)))]
           [buffer
             (cond
               [(not existing)
                (editor-create-buffer! editor resource mode "")]
               [(buffer-result-interface-ref existing) existing]
               [else
                (editor-user-error
                  'editor-present-result-buffer!
                  "Result resource belongs to another Buffer"
                  resource)])])
      (buffer-set-major-mode! buffer mode)
      (buffer-clear-text-properties! buffer)
      (buffer-replace-range-internal!
        buffer 0 (buffer-size buffer) (string->utf8 text))
      (buffer-set-result-interface! buffer interface)
      (editor-note-result-buffer! editor buffer)
      (let ([view
              (editor-display-buffer!
                editor
                (make-display-request
                  (buffer-id buffer) 'tools origin-view-id #f
                  (editor-view-resource-context editor origin-view-id)))])
        (view-set-caret! view 0)
        (ensure-view-visible! view))
      (editor-invalidate! editor 'document)
      buffer))

  (define (property-starts buffer property)
    (map car (buffer-text-property-ranges buffer property)))

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
        (buffer-set-local! buffer 'result-current-index index)
        (values buffer interface item index))))

  (define (invoke-buffer-item-action context name)
    (unless (symbol? name)
      (assertion-violation
        'invoke-buffer-item-action "action name must be a symbol" name))
    (let-values ([(buffer interface item index)
                  (selected-item context 'buffer-item.action)])
      (let ([action
              (find
                (lambda (candidate)
                  (eq? (result-action-name candidate) name))
                (buffer-result-actions-at
                  buffer
                  (view-caret (command-context-view context))))])
        (unless action
          (editor-user-error
            'buffer-item.action
            "Action is not available for the item at point"
            name))
        ((result-action-invoke action) context buffer item index))))

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
      (let ([positions (property-positions buffer interface)])
        (if (null? positions)
            (begin
              (editor-set-status-message!
                (command-context-editor context) "No navigable items")
              '())
            (let* ([current
                     (if view
                         (buffer-text-property-ref
                           buffer (view-caret view) 'result-index #f)
                         (buffer-local-ref
                           buffer 'result-current-index #f))]
                   [base
                     (if current
                         current
                         (if (positive? delta) -1 (length positions)))]
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
              (buffer-set-local! buffer 'result-current-index index)
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
           [items (property-positions buffer interface)])
      (if (or (null? groups) (null? items))
          (begin
            (editor-set-status-message!
              (command-context-editor context) "No result groups")
            '())
          (let* ([position
                   (if view
                       (view-caret view)
                       (let ([index
                               (buffer-local-ref
                                 buffer 'result-current-index #f)])
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
                  (buffer-set-local! buffer 'result-current-index index)
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
      ((result-buffer-interface-quit interface) context buffer)))

  (define (global-navigation-context context)
    (let* ([editor (command-context-editor context)]
           [buffer (available-navigation-buffer editor)]
           [view
                   (and buffer
                        (find
                          (lambda (candidate)
                            (=
                              (buffer-id (view-buffer candidate))
                              (buffer-id buffer)))
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
        (list 'buffer-item.quit
              quit-buffer-items
              "Close the current navigable Buffer.")
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
