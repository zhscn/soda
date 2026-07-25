(library (soda editor state)
  (export make-editor-state
          editor?
          require-open-editor
          editor-close!
          editor-closed?
          editor-buffers
          editor-buffer-ref
          editor-add-buffer!
          editor-create-buffer!
          editor-remove-buffer!
          editor-views
          editor-view-ref
          editor-open-view!
          editor-close-view!
          editor-active-view
          editor-set-active-view!
          editor-set-view-buffer!
          editor-interactions
          editor-interaction-ref
          editor-interaction-for-buffer
          editor-register-interaction!
          editor-command-registry
          editor-keymap-catalog
          editor-language-catalog
          editor-register-language-profile!
          editor-register-major-mode!
          editor-keymap
          editor-pending-keys
          editor-set-pending-keys!
          editor-status-message
          editor-set-status-message!
          view?
          view-id
          view-buffer
          view-caret
          view-preferred-column
          view-first-line
          view-viewport-rows
          view-viewport-columns
          view-keymap-layers
          view-input-states
          view-current-input-state
          view-push-input-state!
          view-pop-input-state!
          view-reset-input-states!
          view-set-caret!
          view-set-vertical-caret!
          view-set-first-line!
          view-set-viewport!
          view-set-keymap-layers!
          ensure-view-visible!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor input-state)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor language))

  (define-record-type (view %make-view view?)
    (fields
      (immutable id view-id)
      (mutable buffer view-buffer view-buffer-set!)
      (mutable caret view-caret view-caret-set!)
      (mutable preferred-column
               view-preferred-column
               view-preferred-column-set!)
      (mutable first-line view-first-line view-first-line-set!)
      (mutable viewport-rows
               view-viewport-rows
               view-viewport-rows-set!)
      (mutable viewport-columns
               view-viewport-columns
               view-viewport-columns-set!)
      (mutable keymap-layers view-keymap-layers view-keymap-layers-set!)
      (mutable input-states view-input-states view-input-states-set!)
      (mutable pending-keys view-pending-keys view-pending-keys-set!)))

  (define-record-type (editor %make-editor editor?)
    (fields
      (immutable buffer-table editor-buffer-table)
      (mutable buffer-ids editor-buffer-ids editor-buffer-ids-set!)
      (mutable next-buffer-id
               editor-next-buffer-id
               editor-next-buffer-id-set!)
      (immutable view-table editor-view-table)
      (mutable view-ids editor-view-ids editor-view-ids-set!)
      (mutable active-view-id
               editor-active-view-id
               editor-active-view-id-set!)
      (mutable next-view-id editor-next-view-id editor-next-view-id-set!)
      (immutable interaction-table editor-interaction-table)
      (mutable interaction-ids
               editor-interaction-ids
               editor-interaction-ids-set!)
      (mutable next-interaction-id
               editor-next-interaction-id
               editor-next-interaction-id-set!)
      (immutable commands editor-command-registry)
      (immutable keymaps editor-keymap-catalog)
      (immutable languages editor-language-catalog)
      (mutable status-message
               editor-status-message
               editor-status-message-set!)
      (mutable closed? editor-closed? editor-closed?-set!)))

  (define (require-open-editor who value)
    (unless (editor? value)
      (assertion-violation who "expected an editor" value))
    (when (editor-closed? value)
      (assertion-violation who "editor is closed" value)))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (table-values table ids)
    (map (lambda (id) (hashtable-ref table id #f)) ids))

  (define (editor-buffers value)
    (require-open-editor 'editor-buffers value)
    (table-values
      (editor-buffer-table value)
      (editor-buffer-ids value)))

  (define (editor-buffer-ref value id)
    (require-open-editor 'editor-buffer-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-buffer-ref
        "buffer id must be a non-negative exact integer"
        id))
    (or (hashtable-ref (editor-buffer-table value) id #f)
        (assertion-violation
          'editor-buffer-ref
          "unknown buffer id"
          id)))

  (define (editor-add-buffer! value buffer)
    (require-open-editor 'editor-add-buffer! value)
    (unless (buffer? buffer)
      (assertion-violation
        'editor-add-buffer!
        "expected a buffer"
        buffer))
    (when (buffer-closed? buffer)
      (assertion-violation
        'editor-add-buffer!
        "buffer is closed"
        buffer))
    (unless (eq? (buffer-language-catalog buffer)
                 (editor-language-catalog value))
      (assertion-violation
        'editor-add-buffer!
        "buffer belongs to another language catalog"
        buffer))
    (let ([id (buffer-id buffer)])
      (when (hashtable-contains? (editor-buffer-table value) id)
        (assertion-violation
          'editor-add-buffer!
          "buffer id is already registered"
          id))
      (hashtable-set! (editor-buffer-table value) id buffer)
      (editor-buffer-ids-set!
        value
        (append (editor-buffer-ids value) (list id)))
      (when (>= id (editor-next-buffer-id value))
        (editor-next-buffer-id-set! value (+ id 1)))
      buffer))

  (define (editor-create-buffer! value resource mode-name bytes)
    (require-open-editor 'editor-create-buffer! value)
    (unless (or (not resource) (string? resource))
      (assertion-violation
        'editor-create-buffer!
        "resource must be a string or #f"
        resource))
    (unless (symbol? mode-name)
      (assertion-violation
        'editor-create-buffer!
        "mode name must be a symbol"
        mode-name))
    (unless (or (string? bytes) (bytevector? bytes))
      (assertion-violation
        'editor-create-buffer!
        "initial text must be a string or bytevector"
        bytes))
    (let* ([id (editor-next-buffer-id value)]
           [new-document-id
             (+ 1
                (fold-left
                  (lambda (maximum buffer)
                    (max
                      maximum
                      (document-id (buffer-document buffer))))
                  0
                  (editor-buffers value)))]
           [document (make-document bytes new-document-id)]
           [buffer
             (make-buffer
               id
               document
               resource
               mode-name
               (editor-language-catalog value))])
      (editor-add-buffer! value buffer)))

  (define (editor-remove-buffer! value id)
    (require-open-editor 'editor-remove-buffer! value)
    (let ([buffer (editor-buffer-ref value id)])
      (when
        (exists
          (lambda (session)
            (= (interaction-session-buffer-id session) id))
          (table-values
            (editor-interaction-table value)
            (editor-interaction-ids value)))
        (assertion-violation
          'editor-remove-buffer!
          "buffer belongs to an interaction session"
          id))
      (when
        (exists
          (lambda (view) (eq? (view-buffer view) buffer))
          (table-values
            (editor-view-table value)
            (editor-view-ids value)))
        (assertion-violation
          'editor-remove-buffer!
          "buffer is displayed by a view"
          id))
      (hashtable-delete! (editor-buffer-table value) id)
      (editor-buffer-ids-set!
        value
        (filter
          (lambda (registered-id) (not (= registered-id id)))
          (editor-buffer-ids value)))
      (buffer-close! buffer)))

  (define (editor-interactions value)
    (require-open-editor 'editor-interactions value)
    (table-values
      (editor-interaction-table value)
      (editor-interaction-ids value)))

  (define (editor-interaction-ref value id)
    (require-open-editor 'editor-interaction-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-interaction-ref
        "interaction id must be a non-negative exact integer"
        id))
    (or
      (hashtable-ref (editor-interaction-table value) id #f)
      (assertion-violation
        'editor-interaction-ref
        "unknown interaction id"
        id)))

  (define (editor-interaction-for-buffer value buffer-id)
    (require-open-editor 'editor-interaction-for-buffer value)
    (unless (exact-non-negative-integer? buffer-id)
      (assertion-violation
        'editor-interaction-for-buffer
        "buffer id must be a non-negative exact integer"
        buffer-id))
    (find
      (lambda (session)
        (= (interaction-session-buffer-id session) buffer-id))
      (editor-interactions value)))

  (define (editor-register-interaction!
            value
            kind
            name
            buffer-id
            evaluator
            prompt
            input-start)
    (require-open-editor 'editor-register-interaction! value)
    (editor-buffer-ref value buffer-id)
    (when (editor-interaction-for-buffer value buffer-id)
      (assertion-violation
        'editor-register-interaction!
        "buffer already belongs to an interaction session"
        buffer-id))
    (let* ([id (editor-next-interaction-id value)]
           [session
             (make-interaction-session
               id
               kind
               name
               buffer-id
               evaluator
               prompt
               input-start)])
      (hashtable-set!
        (editor-interaction-table value)
        id
        session)
      (editor-interaction-ids-set!
        value
        (append (editor-interaction-ids value) (list id)))
      (editor-next-interaction-id-set! value (+ id 1))
      session))

  (define (editor-views value)
    (require-open-editor 'editor-views value)
    (table-values (editor-view-table value) (editor-view-ids value)))

  (define (editor-view-ref value id)
    (require-open-editor 'editor-view-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-view-ref
        "view id must be a non-negative exact integer"
        id))
    (or (hashtable-ref (editor-view-table value) id #f)
        (assertion-violation 'editor-view-ref "unknown view id" id)))

  (define (editor-open-view! value buffer-id)
    (require-open-editor 'editor-open-view! value)
    (let* ([buffer (editor-buffer-ref value buffer-id)]
           [id (editor-next-view-id value)]
           [view
             (%make-view
               id
               buffer
               0
               #f
               0
               1
               1
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               '())])
      (hashtable-set! (editor-view-table value) id view)
      (editor-view-ids-set!
        value
        (append (editor-view-ids value) (list id)))
      (editor-next-view-id-set! value (+ id 1))
      view))

  (define (editor-close-view! value id)
    (require-open-editor 'editor-close-view! value)
    (editor-view-ref value id)
    (when (= (length (editor-view-ids value)) 1)
      (assertion-violation
        'editor-close-view!
        "an open editor requires at least one view"
        id))
    (hashtable-delete! (editor-view-table value) id)
    (let ([remaining
            (filter
              (lambda (registered-id) (not (= registered-id id)))
              (editor-view-ids value))])
      (editor-view-ids-set! value remaining)
      (when (= (editor-active-view-id value) id)
        (editor-active-view-id-set! value (car remaining)))))

  (define (editor-active-view value)
    (require-open-editor 'editor-active-view value)
    (editor-view-ref value (editor-active-view-id value)))

  (define (editor-set-active-view! value id)
    (require-open-editor 'editor-set-active-view! value)
    (editor-view-ref value id)
    (editor-active-view-id-set! value id))

  (define (editor-set-view-buffer! value view-id buffer-id)
    (require-open-editor 'editor-set-view-buffer! value)
    (let ([view (editor-view-ref value view-id)]
          [buffer (editor-buffer-ref value buffer-id)])
      (view-buffer-set! view buffer)
      (view-set-caret! view 0)
      (view-first-line-set! view 0)
      (view-reset-input-states! view)
      (view-pending-keys-set! view '())))

  (define (editor-keymap value)
    (require-open-editor 'editor-keymap value)
    (keymap-catalog-ref (editor-keymap-catalog value) 'editor.default))

  (define (refresh-buffers! value)
    (for-each
      buffer-refresh-language!
      (table-values
        (editor-buffer-table value)
        (editor-buffer-ids value))))

  (define (editor-register-language-profile! value profile)
    (require-open-editor 'editor-register-language-profile! value)
    (let ([registered
            (register-language-profile!
              (editor-language-catalog value)
              profile)])
      (refresh-buffers! value)
      registered))

  (define (editor-register-major-mode! value mode)
    (require-open-editor 'editor-register-major-mode! value)
    (let ([registered
            (register-major-mode!
              (editor-language-catalog value)
              mode)])
      (refresh-buffers! value)
      registered))

  (define (editor-pending-keys value)
    (view-pending-keys (editor-active-view value)))

  (define (editor-set-pending-keys! value sequence)
    (require-open-editor 'editor-set-pending-keys! value)
    (view-pending-keys-set! (editor-active-view value) sequence))

  (define (editor-set-status-message! value message)
    (require-open-editor 'editor-set-status-message! value)
    (unless (or (not message) (string? message))
      (assertion-violation
        'editor-set-status-message!
        "status message must be a string or #f"
        message))
    (editor-status-message-set! value message))

  (define (view-set-caret! value offset)
    (unless (view? value)
      (assertion-violation 'view-set-caret! "expected a view" value))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-caret!
        "offset must be a non-negative exact integer"
        offset))
    (view-caret-set! value offset)
    (view-preferred-column-set! value #f))

  (define (view-set-vertical-caret! value offset column)
    (unless (view? value)
      (assertion-violation
        'view-set-vertical-caret!
        "expected a view"
        value))
    (unless (and (exact-non-negative-integer? offset)
                 (exact-non-negative-integer? column))
      (assertion-violation
        'view-set-vertical-caret!
        "offset and column must be non-negative exact integers"
        offset
        column))
    (view-caret-set! value offset)
    (view-preferred-column-set! value column))

  (define (view-set-first-line! value line)
    (unless (view? value)
      (assertion-violation
        'view-set-first-line!
        "expected a view"
        value))
    (unless (exact-non-negative-integer? line)
      (assertion-violation
        'view-set-first-line!
        "line must be a non-negative exact integer"
        line))
    (view-first-line-set! value line))

  (define (view-set-viewport! value rows columns)
    (unless (view? value)
      (assertion-violation 'view-set-viewport! "expected a view" value))
    (unless (and (exact-non-negative-integer? rows)
                 (positive? rows)
                 (exact-non-negative-integer? columns)
                 (positive? columns))
      (assertion-violation
        'view-set-viewport!
        "rows and columns must be positive exact integers"
        rows
        columns))
    (view-viewport-rows-set! value rows)
    (view-viewport-columns-set! value columns))

  (define (view-set-keymap-layers! value layers)
    (unless (view? value)
      (assertion-violation
        'view-set-keymap-layers!
        "expected a view"
        value))
    (unless (and (list? layers)
                 (for-all
                   (lambda (layer)
                     (or (symbol? layer) (keymap? layer)))
                   layers))
      (assertion-violation
        'view-set-keymap-layers!
        "layers must be a list of keymaps or keymap names"
        layers))
    (view-keymap-layers-set! value layers))

  (define (view-current-input-state value)
    (unless (view? value)
      (assertion-violation
        'view-current-input-state
        "expected a view"
        value))
    (car (view-input-states value)))

  (define (view-push-input-state! value state)
    (unless (view? value)
      (assertion-violation
        'view-push-input-state!
        "expected a view"
        value))
    (unless (input-state? state)
      (assertion-violation
        'view-push-input-state!
        "expected an input state"
        state))
    (view-input-states-set!
      value
      (cons state (view-input-states value)))
    (view-pending-keys-set! value '())
    state)

  (define (view-pop-input-state! value)
    (unless (view? value)
      (assertion-violation
        'view-pop-input-state!
        "expected a view"
        value))
    (let ([states (view-input-states value)])
      (if (null? (cdr states))
          #f
          (begin
            (view-input-states-set! value (cdr states))
            (view-pending-keys-set! value '())
            (car states)))))

  (define (last-input-state states)
    (if (null? (cdr states))
        (car states)
        (last-input-state (cdr states))))

  (define (view-reset-input-states! value)
    (unless (view? value)
      (assertion-violation
        'view-reset-input-states!
        "expected a view"
        value))
    (view-input-states-set!
      value
      (list (last-input-state (view-input-states value))))
    (view-pending-keys-set! value '()))

  (define (with-document-text document procedure)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (ensure-view-visible! view)
    (unless (view? view)
      (assertion-violation
        'ensure-view-visible!
        "expected a view"
        view))
    (let* ([document (buffer-document (view-buffer view))]
           [caret-line
             (with-document-text
               document
               (lambda (text)
                 (car (text-position text (view-caret view)))))]
           [first-line (view-first-line view)]
           [rows (max 1 (view-viewport-rows view))])
      (cond
        [(< caret-line first-line)
         (view-first-line-set! view caret-line)]
        [(>= caret-line (+ first-line rows))
         (view-first-line-set! view (- caret-line (- rows 1)))])))

  (define (make-editor-state buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'make-editor-state
        "expected a buffer"
        buffer))
    (when (buffer-closed? buffer)
      (assertion-violation 'make-editor-state "buffer is closed" buffer))
    (let* ([buffers (make-eqv-hashtable)]
           [views (make-eqv-hashtable)]
           [interactions (make-eqv-hashtable)]
           [keymaps (make-keymap-catalog)]
           [view
             (%make-view
               1
               buffer
               0
               #f
               0
               1
               1
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               '())]
           [value
             (%make-editor
               buffers
               (list (buffer-id buffer))
               (+ (buffer-id buffer) 1)
               views
               '(1)
               1
               2
               interactions
               '()
               1
               (make-command-registry)
               keymaps
               (buffer-language-catalog buffer)
               #f
               #f)])
      (hashtable-set! buffers (buffer-id buffer) buffer)
      (hashtable-set! views 1 view)
      (keymap-catalog-register! keymaps 'editor.override (make-keymap))
      (keymap-catalog-register! keymaps 'editor.default (make-keymap))
      value))

  (define (editor-close! value)
    (when (and (editor? value) (not (editor-closed? value)))
      (for-each
        interaction-session-close!
        (table-values
          (editor-interaction-table value)
          (editor-interaction-ids value)))
      (for-each
        (lambda (buffer)
          (unless (buffer-closed? buffer)
            (buffer-close! buffer)))
        (table-values
          (editor-buffer-table value)
          (editor-buffer-ids value)))
      (for-each
        (lambda (view) (view-pending-keys-set! view '()))
        (table-values (editor-view-table value) (editor-view-ids value)))
      (editor-closed?-set! value #t))))
