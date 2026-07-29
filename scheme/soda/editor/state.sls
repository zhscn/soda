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
          editor-base-view
          editor-prompts
          editor-active-prompt
          editor-open-prompt!
          editor-accept-prompt!
          editor-abort-prompt!
          editor-active-prompt-input
          editor-active-prompt-completion
          editor-active-completion
          editor-start-document-completion!
          editor-refresh-completion!
          editor-refresh-completion-after-command!
          editor-accept-completion!
          editor-cancel-completion!
          editor-completion-next!
          editor-completion-previous!
          editor-apply-completion-response!
          editor-completion-provider-catalog
          editor-register-completion-provider!
          editor-take-completion-effects!
          editor-refresh-prompt-completion!
          editor-prompt-completion-next!
          editor-prompt-completion-previous!
          editor-prompt-history-previous!
          editor-prompt-history-next!
          editor-history-entries
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
          editor-kill-ring
          editor-set-kill-ring!
          editor-last-yank
          editor-set-last-yank!
          editor-pending-prefix
          editor-set-pending-prefix!
          editor-clear-pending-prefix!
          editor-take-pending-prefix!
          editor-last-command-class
          editor-set-last-command-class!
          editor-quit-armed?
          editor-arm-quit!
          editor-disarm-quit!
          view?
          view-id
          view-buffer
          view-caret
          view-mark
          view-mark-active?
          view-set-mark!
          view-deactivate-mark!
          view-clear-mark!
          view-region
          view-preferred-column
          view-first-line
          view-first-column
          view-viewport-rows
          view-viewport-columns
          view-keymap-layers
          view-input-states
          view-completion
          view-current-input-state
          view-push-input-state!
          view-pop-input-state!
          view-reset-input-states!
          view-set-caret!
          view-set-vertical-caret!
          view-set-first-line!
          view-set-first-column!
          view-set-viewport!
          view-set-keymap-layers!
          ensure-view-visible!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor display)
          (soda editor event)
          (soda editor input-state)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor language)
          (soda editor prefix)
          (soda editor prompt))

  (define-record-type (view %make-view view?)
    (fields
      (immutable id view-id)
      (mutable buffer view-buffer view-buffer-set!)
      (mutable caret-anchor view-caret-anchor view-caret-anchor-set!)
      (mutable mark-anchor view-mark-anchor view-mark-anchor-set!)
      (mutable mark-active? view-mark-active? view-mark-active?-set!)
      (mutable preferred-column
               view-preferred-column
               view-preferred-column-set!)
      (mutable first-line view-first-line view-first-line-set!)
      (mutable first-column view-first-column view-first-column-set!)
      (mutable viewport-rows
               view-viewport-rows
               view-viewport-rows-set!)
      (mutable viewport-columns
               view-viewport-columns
               view-viewport-columns-set!)
      (mutable keymap-layers view-keymap-layers view-keymap-layers-set!)
      (mutable input-states view-input-states view-input-states-set!)
      (mutable completion view-completion view-completion-set!)
      (mutable pending-keys view-pending-keys view-pending-keys-set!)))

  (define-record-type (editor %make-editor editor?)
    (fields
      (immutable buffer-table editor-buffer-table)
      (mutable buffer-ids editor-buffer-ids editor-buffer-ids-set!)
      (mutable next-buffer-id
               editor-next-buffer-id
               editor-next-buffer-id-set!)
      (mutable next-document-id
               editor-next-document-id
               editor-next-document-id-set!)
      (immutable view-table editor-view-table)
      (mutable view-ids editor-view-ids editor-view-ids-set!)
      (mutable active-view-id
               editor-active-view-id
               editor-active-view-id-set!)
      (mutable next-view-id editor-next-view-id editor-next-view-id-set!)
      (immutable prompt-table editor-prompt-table)
      (mutable prompt-ids editor-prompt-ids editor-prompt-ids-set!)
      (mutable next-prompt-id
               editor-next-prompt-id
               editor-next-prompt-id-set!)
      (mutable next-completion-id
               editor-next-completion-id
               editor-next-completion-id-set!)
      (immutable prompt-histories editor-prompt-histories)
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
      (immutable completion-providers
                 editor-completion-provider-catalog)
      (mutable completion-effects
               editor-completion-effects
               editor-completion-effects-set!)
      (mutable status-message
               editor-status-message
               editor-status-message-set!)
      (mutable kill-ring editor-kill-ring editor-kill-ring-set!)
      (mutable last-yank editor-last-yank editor-last-yank-set!)
      (mutable pending-prefix
               editor-pending-prefix
               editor-pending-prefix-set!)
      (mutable last-command-class
               editor-last-command-class
               editor-last-command-class-set!)
      (mutable quit-armed?
               editor-quit-armed?
               editor-quit-armed?-set!)
      (mutable closed? editor-closed? editor-closed?-set!)))

  (define (require-open-editor who value)
    (unless (editor? value)
      (assertion-violation who "expected an editor" value))
    (when (editor-closed? value)
      (assertion-violation who "editor is closed" value)))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (editor-set-pending-prefix! editor prefix)
    (require-open-editor 'editor-set-pending-prefix! editor)
    (unless (or (not prefix) (prefix-argument? prefix))
      (assertion-violation
        'editor-set-pending-prefix!
        "expected a prefix argument or #f"
        prefix))
    (editor-pending-prefix-set! editor prefix))

  (define (editor-set-last-yank! editor state)
    (require-open-editor 'editor-set-last-yank! editor)
    (editor-last-yank-set! editor state))

  (define (editor-clear-pending-prefix! editor)
    (require-open-editor 'editor-clear-pending-prefix! editor)
    (editor-pending-prefix-set! editor #f))

  (define (editor-take-pending-prefix! editor)
    (require-open-editor 'editor-take-pending-prefix! editor)
    (let ([prefix (editor-pending-prefix editor)])
      (editor-pending-prefix-set! editor #f)
      prefix))

  (define (table-values table ids)
    (map (lambda (id) (hashtable-ref table id #f)) ids))

  (define (editor-register-completion-provider! value provider)
    (require-open-editor
      'editor-register-completion-provider!
      value)
    (completion-provider-catalog-register!
      (editor-completion-provider-catalog value)
      provider))

  (define (enqueue-completion-effect! value kind request)
    (editor-completion-effects-set!
      value
      (cons
        (make-command-effect kind request)
        (editor-completion-effects value))))

  (define (editor-take-completion-effects! value)
    (require-open-editor
      'editor-take-completion-effects!
      value)
    (let ([effects (reverse (editor-completion-effects value))])
      (editor-completion-effects-set! value '())
      effects))

  (define (queue-completion-generation! value completion)
    (call-with-values
      (lambda ()
        (completion-session-schedule-requests! completion))
      (lambda (cancelled started)
        (for-each
          (lambda (request)
            (enqueue-completion-effect!
              value
              'completion.cancel
              request))
          cancelled)
        (for-each
          (lambda (request)
            (enqueue-completion-effect!
              value
              'completion.request
              request))
          started))))

  (define (queue-completion-cancellation! value completion)
    (for-each
      (lambda (request)
        (enqueue-completion-effect!
          value
          'completion.cancel
          request))
      (completion-session-cancel-requests! completion)))

  (define (cancel-completion-requests-now! value completion)
    (for-each
      (lambda (request)
        (guard (condition [else #f])
          (completion-provider-cancel
            (completion-provider-catalog-ref
              (editor-completion-provider-catalog value)
              (completion-request-provider request))
            request)))
      (completion-session-cancel-requests! completion)))

  (define (cancel-queued-completion-effects-now! value)
    (for-each
      (lambda (effect)
        (when (eq? (command-effect-kind effect)
                   'completion.cancel)
          (let ([request (command-effect-payload effect)])
            (guard (condition [else #f])
              (completion-provider-cancel
                (completion-provider-catalog-ref
                  (editor-completion-provider-catalog value)
                  (completion-request-provider request))
                request)))))
      (reverse (editor-completion-effects value)))
    (editor-completion-effects-set! value '()))

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
      (let ([document-id (document-id (buffer-document buffer))])
        (when (>= document-id (editor-next-document-id value))
          (editor-next-document-id-set! value (+ document-id 1))))
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
           [new-document-id (editor-next-document-id value)]
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
    (let ([buffer (editor-buffer-ref value buffer-id)])
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
                 buffer
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
        session)))

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
               (document-create-anchor!
                 (buffer-document buffer)
                 0
                 anchor-after-insertion)
               #f
               #f
               #f
               0
               0
               1
               1
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               #f
               '())])
      (hashtable-set! (editor-view-table value) id view)
      (editor-view-ids-set!
        value
        (append (editor-view-ids value) (list id)))
      (editor-next-view-id-set! value (+ id 1))
      view))

  (define (prompt-for-view value id)
    (find
      (lambda (session) (= (prompt-session-view-id session) id))
      (table-values
        (editor-prompt-table value)
        (editor-prompt-ids value))))

  (define (close-view-unchecked! value id)
    (let ([view (editor-view-ref value id)])
      (when (= (length (editor-view-ids value)) 1)
        (assertion-violation
          'editor-close-view!
          "an open editor requires at least one view"
          id))
      (cancel-view-completion! value view)
      (when (view-mark-anchor view)
        (document-remove-anchor!
          (buffer-document (view-buffer view))
          (view-mark-anchor view)))
      (document-remove-anchor!
        (buffer-document (view-buffer view))
        (view-caret-anchor view)))
    (hashtable-delete! (editor-view-table value) id)
    (let ([remaining
            (filter
              (lambda (registered-id) (not (= registered-id id)))
              (editor-view-ids value))])
      (editor-view-ids-set! value remaining)
      (when (= (editor-active-view-id value) id)
        (editor-active-view-id-set! value (car remaining)))))

  (define (editor-close-view! value id)
    (require-open-editor 'editor-close-view! value)
    (when (prompt-for-view value id)
      (assertion-violation
        'editor-close-view!
        "prompt views are owned by their prompt session"
        id))
    (close-view-unchecked! value id))

  (define (editor-active-view value)
    (require-open-editor 'editor-active-view value)
    (editor-view-ref value (editor-active-view-id value)))

  (define (editor-set-active-view! value id)
    (require-open-editor 'editor-set-active-view! value)
    (editor-view-ref value id)
    (let ([session (editor-active-prompt value)])
      (when (and session (not (= id (prompt-session-view-id session))))
        (assertion-violation
          'editor-set-active-view!
          "the active prompt owns input focus"
          id)))
    (unless (= id (editor-active-view-id value))
      (cancel-view-completion! value (editor-active-view value)))
    (editor-active-view-id-set! value id))

  (define (editor-set-view-buffer! value view-id buffer-id)
    (require-open-editor 'editor-set-view-buffer! value)
    (when (prompt-for-view value view-id)
      (assertion-violation
        'editor-set-view-buffer!
        "a prompt view cannot change buffers"
        view-id))
    (let ([view (editor-view-ref value view-id)]
          [buffer (editor-buffer-ref value buffer-id)])
      (cancel-view-completion! value view)
      (let ([anchor
              (document-create-anchor!
                (buffer-document buffer)
                0
                anchor-after-insertion)])
        (document-remove-anchor!
          (buffer-document (view-buffer view))
          (view-caret-anchor view))
        (when (view-mark-anchor view)
          (document-remove-anchor!
            (buffer-document (view-buffer view))
            (view-mark-anchor view)))
        (view-buffer-set! view buffer)
        (view-caret-anchor-set! view anchor)
        (view-mark-anchor-set! view #f)
        (view-mark-active?-set! view #f))
      (view-first-line-set! view 0)
      (view-first-column-set! view 0)
      (view-reset-input-states! view)
      (view-pending-keys-set! view '())))

  (define (editor-prompts value)
    (require-open-editor 'editor-prompts value)
    (table-values
      (editor-prompt-table value)
      (editor-prompt-ids value)))

  (define (editor-active-prompt value)
    (require-open-editor 'editor-active-prompt value)
    (and
      (pair? (editor-prompt-ids value))
      (hashtable-ref
        (editor-prompt-table value)
        (car (editor-prompt-ids value))
        #f)))

  (define (last-prompt sessions)
    (if (null? (cdr sessions))
        (car sessions)
        (last-prompt (cdr sessions))))

  (define (editor-base-view value)
    (require-open-editor 'editor-base-view value)
    (let ([sessions (editor-prompts value)])
      (if (null? sessions)
          (editor-active-view value)
          (editor-view-ref
            value
            (prompt-session-origin-view-id
              (last-prompt sessions))))))

  (define (buffer-text-string buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (utf8->string (text->bytevector text)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (buffer-text-size buffer)
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

  (define (replace-buffer-text! buffer value)
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace!
                    transaction
                    0
                    (buffer-text-size buffer)
                    (string->utf8 value)))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (active-prompt-session who value)
    (or (editor-active-prompt value)
        (assertion-violation who "there is no active prompt")))

  (define (editor-active-prompt-input value)
    (require-open-editor 'editor-active-prompt-input value)
    (let* ([session
             (active-prompt-session
               'editor-active-prompt-input
               value)]
           [buffer
             (editor-buffer-ref
               value
               (prompt-session-buffer-id session))])
      (buffer-text-string buffer)))

  (define (editor-active-prompt-completion value)
    (require-open-editor 'editor-active-prompt-completion value)
    (let ([session (editor-active-prompt value)])
      (and session (prompt-session-completion session))))

  (define (editor-active-completion value)
    (require-open-editor 'editor-active-completion value)
    (or
      (editor-active-prompt-completion value)
      (view-completion (editor-active-view value))))

  (define (pop-completion-input-state! view)
    (when (eq? (input-state-name (view-current-input-state view))
               'completion)
      (view-pop-input-state! view)))

  (define (cancel-view-completion! value view)
    (let ([completion (view-completion view)])
      (when completion
        (queue-completion-cancellation! value completion)
        (choice-source-cancel!
          (completion-session-source completion)
          (completion-session-generation completion))
        (view-completion-set! view #f)
        (pop-completion-input-state! view))
      completion))

  (define (editor-cancel-completion! value)
    (require-open-editor 'editor-cancel-completion! value)
    (if (editor-active-prompt value)
        #f
        (cancel-view-completion!
          value
          (editor-active-view value))))

  (define (document-target-query
            value
            completion
            allow-revision-change?)
    (let* ([target (completion-session-target completion)]
           [view (editor-active-view value)])
      (if (or
            (not (document-completion-target? target))
            (not (= (view-id view)
                    (document-completion-target-view-id target)))
            (not (= (buffer-id (view-buffer view))
                    (document-completion-target-buffer-id target)))
            (not (= (document-id
                      (buffer-document (view-buffer view)))
                    (document-completion-target-document-id target)))
            (and
              (not allow-revision-change?)
              (not
                (=
                  (buffer-revision (view-buffer view))
                  (document-completion-target-revision target))))
            (< (view-caret view)
               (document-completion-target-start target)))
          #f
          (let* ([buffer (view-buffer view)]
                 [start
                   (document-completion-target-start target)]
                 [end (view-caret view)]
                 [snapshot
                   (document-snapshot (buffer-document buffer))])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let ([text (snapshot-text snapshot)])
                  (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (and
                        (<= end (text-size text))
                        (cons
                          (utf8->string
                            (text-subbytevector text start end))
                          (make-document-completion-target
                            (view-id view)
                            (buffer-id buffer)
                            (document-id (buffer-document buffer))
                            (buffer-revision buffer)
                            start
                            end))))
                    (lambda () (text-close! text)))))
              (lambda () (snapshot-close! snapshot)))))))

  (define (editor-refresh-document-completion!
            value
            allow-revision-change?)
    (let* ([view (editor-active-view value)]
           [completion (view-completion view)])
      (when completion
        (let ([query+target
                (document-target-query
                  value
                  completion
                  allow-revision-change?)])
          (if query+target
              (let ([generation
                      (completion-session-generation completion)])
                (completion-session-target-set!
                  completion
                  (cdr query+target))
                (completion-session-refresh!
                  completion
                  (car query+target))
                (unless
                  (= generation
                     (completion-session-generation completion))
                  (queue-completion-generation!
                    value
                    completion)))
              (cancel-view-completion! value view))))
      (view-completion view)))

  (define (editor-refresh-completion! value)
    (require-open-editor 'editor-refresh-completion! value)
    (if (editor-active-prompt value)
        (editor-refresh-prompt-completion! value)
        (editor-refresh-document-completion! value #f)))

  (define (editor-refresh-completion-after-command! value)
    (require-open-editor
      'editor-refresh-completion-after-command!
      value)
    (if (editor-active-prompt value)
        (editor-refresh-prompt-completion! value)
        (editor-refresh-document-completion! value #t)))

  (define editor-start-document-completion!
    (case-lambda
      [(value source start end)
       (editor-start-document-completion!
         value
         source
         start
         end
         '())]
      [(value source start end provider-names)
       (require-open-editor
         'editor-start-document-completion!
         value)
       (when (editor-active-prompt value)
         (assertion-violation
           'editor-start-document-completion!
           "document completion cannot start inside a prompt"))
       (unless (choice-source? source)
         (assertion-violation
           'editor-start-document-completion!
           "expected a choice source"
           source))
       (unless (and
                 (list? provider-names)
                 (for-all symbol? provider-names))
         (assertion-violation
           'editor-start-document-completion!
           "provider names must be a list of symbols"
           provider-names))
       (let loop ([remaining provider-names] [seen '()])
         (unless (null? remaining)
           (when (memq (car remaining) seen)
             (assertion-violation
               'editor-start-document-completion!
               "provider names must be unique"
               (car remaining)))
           (loop (cdr remaining) (cons (car remaining) seen))))
       (for-each
         (lambda (name)
           (completion-provider-catalog-ref
             (editor-completion-provider-catalog value)
             name))
         provider-names)
       (let* ([view (editor-active-view value)]
              [buffer (view-buffer view)]
              [document (buffer-document buffer)]
              [caret (view-caret view)])
         (unless (and (exact-non-negative-integer? start)
                      (exact-non-negative-integer? end)
                      (<= start end)
                      (= end caret))
           (assertion-violation
             'editor-start-document-completion!
             "completion range must end at the active caret"
             start
             end
             caret))
         (cancel-view-completion! value view)
         (let* ([id (editor-next-completion-id value)]
                [target
                  (make-document-completion-target
                    (view-id view)
                    (buffer-id buffer)
                    (document-id document)
                    (buffer-revision buffer)
                    start
                    end)]
                [completion
                  (make-completion-session
                    id
                    target
                    source
                    provider-names)])
           (editor-next-completion-id-set! value (+ id 1))
           (view-completion-set! view completion)
           (view-push-input-state!
             view
             (make-input-state
               'completion
               '(completion.menu)
               'accept))
           (editor-refresh-document-completion! value #f)
           completion))]))

  (define (replace-buffer-range! buffer start end bytes)
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace!
                    transaction
                    start
                    end
                    bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (editor-accept-completion! value)
    (require-open-editor 'editor-accept-completion! value)
    (when (editor-active-prompt value)
      (assertion-violation
        'editor-accept-completion!
        "prompt completion is accepted through its prompt"))
    (let* ([view (editor-active-view value)]
           [completion (view-completion view)]
           [item
             (and completion
                  (completion-session-selected-item completion))])
      (cond
        [(not completion) #f]
        [(not item)
         (editor-set-status-message! value "No completion candidate")
         #f]
        [else
         (let* ([target (completion-session-target completion)]
                [buffer (view-buffer view)]
                [document (buffer-document buffer)])
           (if (or
                 (not (document-completion-target? target))
                 (not (= (view-id view)
                         (document-completion-target-view-id target)))
                 (not (= (buffer-id buffer)
                         (document-completion-target-buffer-id target)))
                 (not (= (document-id document)
                         (document-completion-target-document-id target)))
                 (not (= (buffer-revision buffer)
                         (document-completion-target-revision target)))
                 (not (= (view-caret view)
                         (document-completion-target-end target))))
               (begin
                 (cancel-view-completion! value view)
                 (editor-set-status-message!
                   value
                   "Completion target changed")
                 #f)
               (let* ([start
                        (document-completion-target-start target)]
                      [end (document-completion-target-end target)]
                      [bytes
                        (string->utf8
                          (completion-item-insert-text item))])
                 (replace-buffer-range! buffer start end bytes)
                 (view-set-caret!
                   view
                   (+ start (bytevector-length bytes)))
                 (cancel-view-completion! value view)
                 item)))])))

  (define (editor-completion-next! value)
    (require-open-editor 'editor-completion-next! value)
    (let ([completion (editor-active-completion value)])
      (when completion
        (completion-session-select-next! completion))
      completion))

  (define (editor-completion-previous! value)
    (require-open-editor 'editor-completion-previous! value)
    (let ([completion (editor-active-completion value)])
      (when completion
        (completion-session-select-previous! completion))
      completion))

  (define (completion-response-target-matches?
            value
            completion
            message)
    (let ([target (completion-session-target completion)])
      (cond
        [(document-completion-target? target)
         (let ([view (editor-active-view value)])
           (and
             (= (view-id view)
                (document-completion-target-view-id target))
             (= (buffer-id (view-buffer view))
                (document-completion-target-buffer-id target))
             (= (document-id
                  (buffer-document (view-buffer view)))
                (document-completion-target-document-id target))
             (= (completion-response-message-target-id message)
                (document-completion-target-document-id target))
             (equal?
               (completion-response-message-target-revision message)
               (document-completion-target-revision target))
             (= (buffer-revision (view-buffer view))
                (document-completion-target-revision target))))]
        [(prompt-completion-target? target)
         (let ([prompt (editor-active-prompt value)])
           (and
             prompt
             (= (prompt-session-id prompt)
                (prompt-completion-target-prompt-id target))
             (= (completion-response-message-target-id message)
                (prompt-completion-target-prompt-id target))
             (not
               (completion-response-message-target-revision
                 message))))]
        [else #f])))

  (define (editor-apply-completion-response! value message)
    (require-open-editor
      'editor-apply-completion-response!
      value)
    (unless (completion-response-message? message)
      (assertion-violation
        'editor-apply-completion-response!
        "expected a completion response message"
        message))
    (let* ([completion (editor-active-completion value)]
           [accepted?
             (and
               completion
               (= (completion-response-message-session-id message)
                  (completion-session-id completion))
               (= (completion-response-message-generation message)
                  (completion-session-generation completion))
               (completion-response-target-matches?
                 value
                 completion
                 message)
               (completion-session-apply-response!
                 completion
                 (completion-response-message-generation message)
                 (completion-response-message-provider message)
                 (completion-response-message-items message)
                 (completion-response-message-complete? message)))])
      (when
        (and
          accepted?
          (document-completion-target?
            (completion-session-target completion))
          (null? (completion-session-items completion))
          (not (completion-session-pending? completion)))
        (cancel-view-completion!
          value
          (editor-active-view value))
        (editor-set-status-message! value "No completions"))
      accepted?))

  (define (editor-refresh-prompt-completion! value)
    (require-open-editor 'editor-refresh-prompt-completion! value)
    (let ([completion (editor-active-prompt-completion value)])
      (when completion
        (let ([input (editor-active-prompt-input value)]
              [generation
                (completion-session-generation completion)])
          (completion-session-target-set!
            completion
            (make-prompt-completion-target
              (prompt-session-id (editor-active-prompt value))
              0
              (bytevector-length (string->utf8 input))))
          (completion-session-refresh! completion input)
          (unless
            (= generation
               (completion-session-generation completion))
            (queue-completion-generation! value completion))))
      completion))

  (define (editor-prompt-completion-next! value)
    (editor-completion-next! value))

  (define (editor-prompt-completion-previous! value)
    (editor-completion-previous! value))

  (define (editor-open-prompt! value request)
    (require-open-editor 'editor-open-prompt! value)
    (unless (prompt-request? request)
      (assertion-violation
        'editor-open-prompt!
        "expected a prompt request"
        request))
    (unless (command-registered?
              (editor-command-registry value)
              (prompt-request-accept-command request))
      (assertion-violation
        'editor-open-prompt!
        "accept responder is not a registered command"
        (prompt-request-accept-command request)))
    (when (and
            (prompt-request-abort-command request)
            (not
              (command-registered?
                (editor-command-registry value)
                (prompt-request-abort-command request))))
      (assertion-violation
        'editor-open-prompt!
        "abort responder is not a registered command"
        (prompt-request-abort-command request)))
    (let* ([id (editor-next-prompt-id value)]
           [completion-id (editor-next-completion-id value)]
           [origin-view-id (editor-active-view-id value)]
           [origin-view (editor-active-view value)]
           [buffer
             (editor-create-buffer!
               value
               (string-append
                 " *Minibuf-"
                 (number->string id)
                 "*")
               'fundamental-mode
               (prompt-request-initial request))]
           [view (editor-open-view! value (buffer-id buffer))]
           [completion
             (and
               (prompt-request-completion-source request)
               (make-completion-session
                 completion-id
                 (make-prompt-completion-target
                   id
                   0
                   (bytevector-length
                     (string->utf8
                       (prompt-request-initial request))))
                 (prompt-request-completion-source request)))]
           [session
             (make-prompt-session
               id
               request
               (buffer-id buffer)
               (view-id view)
               origin-view-id
               'active
               #f
               (prompt-request-initial request)
               completion)])
      (cancel-view-completion! value origin-view)
      (buffer-set-local-setting! buffer 'track-modified? #f)
      (view-set-viewport!
        view
        1
        (max
          1
          (-
            (view-viewport-columns origin-view)
            (string-cell-width
              (prompt-request-prompt request)
              8))))
      (view-set-caret!
        view
        (buffer-text-size buffer))
      (view-push-input-state!
        view
        (make-input-state
          'minibuffer
          '(prompt.input)
          'accept))
      (ensure-view-visible! view)
      (hashtable-set! (editor-prompt-table value) id session)
      (editor-prompt-ids-set!
        value
        (cons id (editor-prompt-ids value)))
      (editor-next-prompt-id-set! value (+ id 1))
      (when completion
        (editor-next-completion-id-set!
          value
          (+ completion-id 1)))
      (editor-active-view-id-set! value (view-id view))
      (editor-set-status-message! value #f)
      (editor-refresh-prompt-completion! value)
      session))

  (define (history-for value id create?)
    (and
      id
      (or
        (hashtable-ref (editor-prompt-histories value) id #f)
        (and
          create?
          (let ([history (make-prompt-history id '())])
            (hashtable-set!
              (editor-prompt-histories value)
              id
              history)
            history)))))

  (define (editor-history-entries value id)
    (require-open-editor 'editor-history-entries value)
    (unless (symbol? id)
      (assertion-violation
        'editor-history-entries
        "history id must be a symbol"
        id))
    (let ([history (history-for value id #f)])
      (if history (prompt-history-entries history) '())))

  (define (record-history! value session input)
    (let* ([history-id
             (prompt-request-history-id
               (prompt-session-request session))]
           [history (history-for value history-id #t)])
      (when (and history
                 (positive? (string-length input))
                 (or (null? (prompt-history-entries history))
                     (not
                       (string=?
                         input
                         (car (prompt-history-entries history))))))
        (prompt-history-entries-set!
          history
          (cons input (prompt-history-entries history))))))

  (define (finish-prompt! value status input candidate command)
    (let* ([session
             (active-prompt-session 'finish-prompt! value)]
           [id (prompt-session-id session)]
           [view-id (prompt-session-view-id session)]
           [buffer-id (prompt-session-buffer-id session)]
           [origin-view-id (prompt-session-origin-view-id session)]
           [result
             (make-prompt-result
               id
               status
               input
               origin-view-id
               candidate
               (prompt-request-data
                 (prompt-session-request session)))])
      (when (prompt-session-completion session)
        (queue-completion-cancellation!
          value
          (prompt-session-completion session))
        (choice-source-cancel!
          (completion-session-source
            (prompt-session-completion session))
          (completion-session-generation
            (prompt-session-completion session))))
      (prompt-session-state-set! session status)
      (editor-prompt-ids-set! value (cdr (editor-prompt-ids value)))
      (hashtable-delete! (editor-prompt-table value) id)
      (editor-active-view-id-set! value origin-view-id)
      (close-view-unchecked! value view-id)
      (editor-remove-buffer! value buffer-id)
      (editor-set-status-message! value #f)
      (and command (make-prompt-reply command result))))

  (define (editor-accept-prompt! value)
    (require-open-editor 'editor-accept-prompt! value)
    (let* ([session
             (active-prompt-session
               'editor-accept-prompt!
               value)]
           [request (prompt-session-request session)]
           [input (editor-active-prompt-input value)]
           [input-or-default
             (if (and (zero? (string-length input))
                      (prompt-request-default request))
                 (prompt-request-default request)
                 input)]
           [completion (prompt-session-completion session)]
           [exact-candidate
             (and
               completion
               (find
                 (lambda (item)
                   (string=?
                     (completion-item-insert-text item)
                     input-or-default))
                 (completion-session-items completion)))]
           [candidate
             (and
               completion
               (or
                 exact-candidate
                 (completion-session-selected-item completion)))]
           [resolved
             (if (and
                   candidate
                   (eq? (prompt-request-accept-policy request)
                        'must-match))
                 (completion-item-insert-text candidate)
                 input-or-default)]
           [valid?
             (or
               (eq? (prompt-request-accept-policy request) 'free)
               ((prompt-request-validator request) resolved))])
      (if (not valid?)
          (begin
            (editor-set-status-message!
              value
              "Input does not match an available choice")
            #f)
          (begin
            (record-history! value session resolved)
            (finish-prompt!
              value
              'accepted
              resolved
              candidate
              (prompt-request-accept-command request))))))

  (define (editor-abort-prompt! value)
    (require-open-editor 'editor-abort-prompt! value)
    (let* ([session
             (active-prompt-session
               'editor-abort-prompt!
               value)]
           [request (prompt-session-request session)])
      (finish-prompt!
        value
        'aborted
        #f
        #f
        (prompt-request-abort-command request))))

  (define (set-active-prompt-input! value session input)
    (let* ([view
             (editor-view-ref value (prompt-session-view-id session))]
           [buffer (view-buffer view)])
      (replace-buffer-text! buffer input)
      (view-set-caret!
        view
        (buffer-text-size buffer))
      (ensure-view-visible! view)
      (editor-refresh-prompt-completion! value)
      input))

  (define (editor-prompt-history-previous! value)
    (require-open-editor 'editor-prompt-history-previous! value)
    (let* ([session
             (active-prompt-session
               'editor-prompt-history-previous!
               value)]
           [history-id
             (prompt-request-history-id
               (prompt-session-request session))]
           [history (history-for value history-id #f)]
           [entries
             (if history (prompt-history-entries history) '())]
           [current (prompt-session-history-index session)]
           [next-index
             (cond
               [(null? entries) #f]
               [(not current) 0]
               [(< (+ current 1) (length entries)) (+ current 1)]
               [else current])])
      (when (and next-index (not current))
        (prompt-session-history-draft-set!
          session
          (editor-active-prompt-input value)))
      (when next-index
        (prompt-session-history-index-set! session next-index)
        (set-active-prompt-input!
          value
          session
          (list-ref entries next-index)))))

  (define (editor-prompt-history-next! value)
    (require-open-editor 'editor-prompt-history-next! value)
    (let* ([session
             (active-prompt-session
               'editor-prompt-history-next!
               value)]
           [current (prompt-session-history-index session)])
      (cond
        [(not current) #f]
        [(zero? current)
         (prompt-session-history-index-set! session #f)
         (set-active-prompt-input!
           value
           session
           (prompt-session-history-draft session))]
        [else
         (let* ([history-id
                  (prompt-request-history-id
                    (prompt-session-request session))]
                [history (history-for value history-id #f)]
                [next-index (- current 1)])
           (prompt-session-history-index-set! session next-index)
           (set-active-prompt-input!
             value
             session
             (list-ref
               (prompt-history-entries history)
               next-index)))])))

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

  (define (editor-arm-quit! value)
    (require-open-editor 'editor-arm-quit! value)
    (editor-quit-armed?-set! value #t))

  (define (editor-disarm-quit! value)
    (require-open-editor 'editor-disarm-quit! value)
    (editor-quit-armed?-set! value #f))

  (define (view-caret value)
    (unless (view? value)
      (assertion-violation 'view-caret "expected a view" value))
    (document-anchor-offset
      (buffer-document (view-buffer value))
      (view-caret-anchor value)))

  (define (view-mark value)
    (unless (view? value)
      (assertion-violation 'view-mark "expected a view" value))
    (and
      (view-mark-anchor value)
      (document-anchor-offset
        (buffer-document (view-buffer value))
        (view-mark-anchor value))))

  (define (view-set-mark! value offset)
    (unless (view? value)
      (assertion-violation 'view-set-mark! "expected a view" value))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-mark!
        "offset must be a non-negative exact integer"
        offset))
    (let ([document (buffer-document (view-buffer value))])
      (when (view-mark-anchor value)
        (document-remove-anchor!
          document
          (view-mark-anchor value)))
      (view-mark-anchor-set!
        value
        (document-create-anchor!
          document
          offset
          anchor-before-insertion))
      (view-mark-active?-set! value #t))
    offset)

  (define (view-deactivate-mark! value)
    (unless (view? value)
      (assertion-violation
        'view-deactivate-mark!
        "expected a view"
        value))
    (view-mark-active?-set! value #f))

  (define (view-clear-mark! value)
    (unless (view? value)
      (assertion-violation 'view-clear-mark! "expected a view" value))
    (when (view-mark-anchor value)
      (document-remove-anchor!
        (buffer-document (view-buffer value))
        (view-mark-anchor value))
      (view-mark-anchor-set! value #f))
    (view-mark-active?-set! value #f))

  (define (view-region value)
    (unless (view? value)
      (assertion-violation 'view-region "expected a view" value))
    (let ([mark (and (view-mark-active? value) (view-mark value))])
      (and mark
           (let ([caret (view-caret value)])
             (cons (min mark caret) (max mark caret))))))

  (define (editor-set-last-command-class! value class)
    (require-open-editor 'editor-set-last-command-class! value)
    (unless (or (not class) (symbol? class))
      (assertion-violation
        'editor-set-last-command-class!
        "command class must be a symbol or #f"
        class))
    (editor-last-command-class-set! value class))

  (define (editor-set-kill-ring! value entries)
    (require-open-editor 'editor-set-kill-ring! value)
    (unless (and (list? entries) (for-all bytevector? entries))
      (assertion-violation
        'editor-set-kill-ring!
        "kill ring must be a list of bytevectors"
        entries))
    (editor-kill-ring-set! value entries))

  (define (replace-view-caret-anchor! value offset)
    (let* ([document (buffer-document (view-buffer value))]
           [anchor
             (document-create-anchor!
               document
               offset
               anchor-after-insertion)]
           [previous (view-caret-anchor value)])
      (document-remove-anchor! document previous)
      (view-caret-anchor-set! value anchor)))

  (define (view-set-caret! value offset)
    (unless (view? value)
      (assertion-violation 'view-set-caret! "expected a view" value))
    (unless (exact-non-negative-integer? offset)
      (assertion-violation
        'view-set-caret!
        "offset must be a non-negative exact integer"
        offset))
    (replace-view-caret-anchor! value offset)
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
    (replace-view-caret-anchor! value offset)
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

  (define (view-set-first-column! value column)
    (unless (view? value)
      (assertion-violation
        'view-set-first-column!
        "expected a view"
        value))
    (unless (exact-non-negative-integer? column)
      (assertion-violation
        'view-set-first-column!
        "column must be a non-negative exact integer"
        column))
    (view-first-column-set! value column))

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
    (let* ([buffer (view-buffer view)]
           [document (buffer-document buffer)]
           [tab-width
             (let ([setting (buffer-setting-ref buffer 'tab-width 8)])
               (if (and (integer? setting)
                        (exact? setting)
                        (positive? setting))
                   setting
                   8))]
           [caret-position
             (with-document-text
               document
               (lambda (text)
                 (cons
                   (car (text-position text (view-caret view)))
                   (text-cell-column
                     text
                     (view-caret view)
                     tab-width))))]
           [caret-line (car caret-position)]
           [caret-column (cdr caret-position)]
           [first-line (view-first-line view)]
           [rows (max 1 (view-viewport-rows view))]
           [first-column (view-first-column view)]
           [columns (max 1 (view-viewport-columns view))])
      (cond
        [(< caret-line first-line)
         (view-first-line-set! view caret-line)]
        [(>= caret-line (+ first-line rows))
         (view-first-line-set! view (- caret-line (- rows 1)))])
      (cond
        [(< caret-column first-column)
         (view-first-column-set! view caret-column)]
        [(>= caret-column (+ first-column columns))
         (view-first-column-set!
           view
           (- caret-column (- columns 1)))])))

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
           [prompts (make-eqv-hashtable)]
           [prompt-histories (make-eq-hashtable)]
           [keymaps (make-keymap-catalog)]
           [view
             (%make-view
               1
               buffer
               (document-create-anchor!
                 (buffer-document buffer)
                 0
                 anchor-after-insertion)
               #f
               #f
               #f
               0
               0
               1
               1
               '()
               (list
                 (make-input-state
                   'editing
                   '()
                   'accept))
               #f
               '())]
           [value
             (%make-editor
               buffers
               (list (buffer-id buffer))
               (+ (buffer-id buffer) 1)
               (+ (document-id (buffer-document buffer)) 1)
               views
               '(1)
               1
               2
               prompts
               '()
               1
               1
               prompt-histories
               interactions
               '()
               1
               (make-command-registry)
               keymaps
               (buffer-language-catalog buffer)
               (make-completion-provider-catalog)
               '()
               #f
               '()
               #f
               #f
               #f
               #f
               #f)])
      (hashtable-set! buffers (buffer-id buffer) buffer)
      (hashtable-set! views 1 view)
      (keymap-catalog-register! keymaps 'editor.override (make-keymap))
      (keymap-catalog-register! keymaps 'editor.default (make-keymap))
      value))

  (define (editor-close! value)
    (when (and (editor? value) (not (editor-closed? value)))
      (cancel-queued-completion-effects-now! value)
      (for-each
        (lambda (session)
          (when (prompt-session-completion session)
            (cancel-completion-requests-now!
              value
              (prompt-session-completion session))
            (choice-source-cancel!
              (completion-session-source
                (prompt-session-completion session))
              (completion-session-generation
                (prompt-session-completion session))))
          (prompt-session-state-set! session 'aborted))
        (editor-prompts value))
      (editor-prompt-ids-set! value '())
      (hashtable-clear! (editor-prompt-table value))
      (for-each
        interaction-session-close!
        (table-values
          (editor-interaction-table value)
          (editor-interaction-ids value)))
      (for-each
        (lambda (view)
          (when (view-completion view)
            (cancel-completion-requests-now!
              value
              (view-completion view))
            (choice-source-cancel!
              (completion-session-source
                (view-completion view))
              (completion-session-generation
                (view-completion view)))
            (view-completion-set! view #f))
          (view-pending-keys-set! view '())
          (when (view-mark-anchor view)
            (document-remove-anchor!
              (buffer-document (view-buffer view))
              (view-mark-anchor view))
            (view-mark-anchor-set! view #f))
          (document-remove-anchor!
            (buffer-document (view-buffer view))
            (view-caret-anchor view)))
        (table-values (editor-view-table value) (editor-view-ids value)))
      (for-each
        (lambda (buffer)
          (unless (buffer-closed? buffer)
            (buffer-close! buffer)))
        (table-values
          (editor-buffer-table value)
          (editor-buffer-ids value)))
      (editor-closed?-set! value #t))))
