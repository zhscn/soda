(library (soda editor result-edit)
  (export install-result-edit!
          editor-begin-projection-edit!
          buffer-projection-edit-active?
          accept-projection-edit)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor editable-projection)
          (soda editor effect)
          (soda editor event)
          (soda editor keymap)
          (soda editor location)
          (soda editor minor-mode)
          (soda editor minor-mode-runtime)
          (soda editor resource-resolver)
          (soda editor result-buffer)
          (soda editor state)
          (soda editor workspace-edit))

  (define-record-type result-edit-session
    (fields original-read-only? projections accept discard))

  (define (buffer-projection-edit-active? buffer)
    (and
      (buffer? buffer)
      (result-edit-session?
        (buffer-local-ref buffer 'result-edit-session #f))))

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

  (define (buffer-substring buffer start end)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (utf8->string (text-subbytevector text start end)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (target-ranges buffer)
    (buffer-text-property-ranges buffer 'result-target))

  (define (result-item-count buffer)
    (length (buffer-text-property-ranges buffer 'result-index)))

  (define (target-resources ranges)
    (reverse
      (fold-left
        (lambda (resources range)
          (let ([resource (location-item-resource (caddr range))])
            (if (member resource resources)
                resources
                (cons resource resources))))
        '()
        ranges)))

  (define (make-target-projection! editor result-buffer range)
    (let* ([item (caddr range)]
           [resource (location-item-resource item)]
           [source-buffer
             (and resource
                  (editor-buffer-for-resource editor resource))]
           [source-start (location-item-start item)]
           [source-end (location-item-end item)]
           [shown
             (buffer-substring result-buffer (car range) (cadr range))])
      (unless (and source-buffer
                   (<= 0 source-start source-end
                       (buffer-size source-buffer)))
        (editor-user-error
          'result-edit.begin "Result target cannot be resolved" resource))
      (unless
        (string=?
          shown
          (buffer-substring source-buffer source-start source-end))
        (editor-user-error
          'result-edit.begin
          "Source changed since the result was produced"
          resource))
      (make-editable-projection!
        result-buffer
        (make-workspace-text-edit
          resource
          (buffer-revision source-buffer)
          source-start source-end shown)
        (car range)
        (cadr range))))

  (define (editor-begin-projection-edit!
            editor buffer projections status accept discard)
    (unless
      (and
        (editor? editor)
        (buffer? buffer)
        (buffer-result-interface-ref buffer)
        (list? projections)
        (pair? projections)
        (for-all editable-projection? projections)
        (string? status)
        (procedure? accept)
        (procedure? discard))
      (assertion-violation
        'editor-begin-projection-edit!
        "invalid projection edit session"
        buffer projections status))
    (when (buffer-local-ref buffer 'result-edit-session #f)
      (editor-user-error
        'editor-begin-projection-edit!
        "Result Buffer is already being edited"))
    (let ([session
            (make-result-edit-session
              (buffer-setting-ref buffer 'read-only? #f)
              projections
              accept
              discard)])
      (buffer-set-local! buffer 'result-edit-session session)
      (buffer-set-local! buffer 'result-edit-active? #t)
      (buffer-install-projection-edit-guard!
        buffer projections 'result-edit
        "Only projected source text is editable")
      (editor-enable-minor-mode! editor buffer 'result-edit-mode)
      (buffer-set-local-setting! buffer 'read-only? #f)
      (let ([view
              (find
                (lambda (candidate) (eq? (view-buffer candidate) buffer))
                (editor-views editor))])
        (when view
          (view-set-caret!
            view
            (car (editable-projection-range buffer (car projections))))))
      (editor-set-status-message! editor status)
      (editor-invalidate! editor 'chrome)
      session))

  (define (activate-result-edit! editor buffer pending-session)
    (when
      (and
        (exists (lambda (candidate) (eq? candidate buffer))
                (editor-buffers editor))
        (eq? (buffer-local-ref buffer 'result-edit-pending #f)
             pending-session))
      (let ([projections
              (map
                (lambda (range)
                  (make-target-projection! editor buffer range))
                (target-ranges buffer))])
        (buffer-clear-local! buffer 'result-edit-pending)
        (editor-begin-projection-edit!
          editor
          buffer
          projections
          "Edit targets; C-c C-c applies, C-c C-k discards"
          (lambda (context edited-buffer edited-projections)
            (workspace-text-edits-apply!
              (command-context-editor context)
              (map
                (lambda (projection)
                  (projection-edit edited-buffer projection))
                edited-projections))
            (editor-set-status-message!
              (command-context-editor context)
              (string-append
                "Updated " (number->string (length edited-projections))
                " result targets"))
            (list
              (make-command-effect
                'command.invoke
                (make-command-message 'buffer-item.quit #f))))
          (lambda (context edited-buffer edited-projections)
            (refresh-buffer-items context))))))

  (define (begin-result-edit context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [ranges (target-ranges buffer)])
      (unless (buffer-result-interface-ref buffer)
        (editor-user-error
          'result-edit.begin "Current Buffer is not a result Buffer"))
      (unless (buffer-result-refreshable? buffer)
        (editor-user-error
          'result-edit.begin "Result producer cannot regenerate this Buffer"))
      (let ([ready? (buffer-local-ref buffer 'result-edit-ready? #t)])
        (let ([status (if (procedure? ready?) (ready?) ready?)])
          (unless (eq? status #t)
            (editor-user-error
              'result-edit.begin
              (if (string? status)
                  status
                  "Result Buffer is not ready for editing")))))
      (when (or (buffer-local-ref buffer 'result-edit-session #f)
                (buffer-local-ref buffer 'result-edit-pending #f))
        (editor-user-error
          'result-edit.begin "Result Buffer is already being edited"))
      (when (null? ranges)
        (editor-user-error
          'result-edit.begin "Result Buffer has no editable targets"))
      (unless (= (length ranges) (result-item-count buffer))
        (editor-user-error
          'result-edit.begin
          "Some result targets are unresolved; preview them and refresh first"))
      (let ([pending-session (list 'result-edit-pending)])
        (buffer-set-local! buffer 'result-edit-pending pending-session)
        (editor-resolve-resources!
          editor
          (target-resources ranges)
          (lambda (resolved-editor buffers)
            (activate-result-edit!
              resolved-editor buffer pending-session))
          (lambda (resolved-editor resource status)
            (when
              (eq? (buffer-local-ref buffer 'result-edit-pending #f)
                   pending-session)
              (buffer-clear-local! buffer 'result-edit-pending)
              (editor-set-status-message!
                resolved-editor
                (string-append
                  "Cannot edit results: failed to read " resource))))))))

  (define (active-result-edit context who)
    (let* ([buffer (view-buffer (command-context-view context))]
           [session (buffer-local-ref buffer 'result-edit-session #f)])
      (unless (result-edit-session? session)
        (editor-user-error who "Current Buffer has no result edit session"))
      (values buffer session)))

  (define (projection-edit buffer projection)
    (let ([source (editable-projection-source projection)])
      (make-workspace-text-edit
        (workspace-text-edit-resource source)
        (workspace-text-edit-revision source)
        (workspace-text-edit-start source)
        (workspace-text-edit-end source)
        (editable-projection-text buffer projection))))

  (define (finish-result-edit! editor buffer session)
    (buffer-clear-local! buffer 'edit-guard)
    (buffer-clear-local! buffer 'result-edit-active?)
    (buffer-clear-local! buffer 'result-edit-session)
    (editor-disable-minor-mode! editor buffer 'result-edit-mode)
    (buffer-set-local-setting!
      buffer
      'read-only?
      (result-edit-session-original-read-only? session)))

  (define (accept-projection-edit context)
    (let-values ([(buffer session)
                  (active-result-edit context 'result-edit.accept)])
      (let ([projections (result-edit-session-projections session)])
        (let ([effects
                ((result-edit-session-accept session)
                 context buffer projections)])
        (finish-result-edit!
          (command-context-editor context) buffer session)
          effects))))

  (define (discard-result-edit context)
    (let-values ([(buffer session)
                  (active-result-edit context 'result-edit.discard)])
      (finish-result-edit!
        (command-context-editor context) buffer session)
      ((result-edit-session-discard session)
       context buffer (result-edit-session-projections session))))

  (define (install-result-edit! editor)
    (let ([keymap (make-keymap)]
          [control-c
            (make-key-stroke 'character (char->integer #\c) 4)])
      (keymap-bind!
        keymap (list control-c control-c) 'result-edit.accept)
      (keymap-bind!
        keymap
        (list control-c
              (make-key-stroke 'character (char->integer #\k) 4))
        'result-edit.discard)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'result-edit-mode-map keymap))
    (editor-register-minor-mode!
      editor
      (make-minor-mode-definition
        'result-edit-mode
        "Edit source targets through a Result Buffer projection."
        'buffer
        " Edit"
        'result-edit-mode-map
        (lambda (editor buffer) #f)
        (lambda (editor buffer) #f)))
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'result-edit.begin begin-result-edit
              "Edit the source targets projected into this result Buffer.")
        (list 'result-edit.accept accept-projection-edit
              "Apply edits from the current result projection.")
        (list 'result-edit.discard discard-result-edit
              "Discard result projection edits and rerun its producer.")))
    editor)
)
