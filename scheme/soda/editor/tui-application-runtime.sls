(library (soda editor tui-application-runtime)
  (export tui-open!
          tui-close!
          tui-active-session)
  (import (rnrs)
          (soda editor buffer)
          (soda editor display-placement)
          (soda editor presentation)
          (soda editor state)
          (soda editor tui-application))

  (define (application-resource name id)
    (string-append
      "*tui:"
      (symbol->string name)
      ":"
      (number->string id)
      "*"))

  (define (definition-ref editor name)
    (or
      (tui-application-catalog-ref
        (editor-tui-application-catalog editor)
        name)
      (assertion-violation
        'tui-open!
        "unknown TUI application"
        name)))

  (define (initialize definition context arguments)
    (call-with-values
      (lambda ()
        ((tui-application-definition-init definition)
         context
         arguments))
      (lambda (model commands)
        (unless (list? commands)
          (assertion-violation
            'tui-open!
            "application init commands must be a list"
            (tui-application-definition-name definition)
            commands))
        (values model commands))))

  (define tui-open!
    (case-lambda
      [(editor name arguments)
       (let ([definition (definition-ref editor name)])
         (tui-open!
           editor
           name
           arguments
           (tui-application-definition-default-display-intent definition)
           (view-id (editor-active-view editor))))]
      [(editor name arguments intent)
       (tui-open!
         editor
         name
         arguments
         intent
         (view-id (editor-active-view editor)))]
      [(editor name arguments intent origin-view-id)
       (require-open-editor 'tui-open! editor)
       (let* ([definition (definition-ref editor name)]
              [registry (editor-tui-application-registry editor)]
              [session-id
                (tui-application-registry-allocate-session-id! registry)]
              [buffer
                (editor-create-buffer!
                  editor
                  (application-resource name session-id)
                  (tui-application-definition-default-mode definition)
                  "")]
              [registered? #f])
         (guard
           (condition
             [else
              (when registered?
                (editor-close-tui-session! editor session-id))
              (when
                (and
                  (not (buffer-closed? buffer))
                  (not
                    (exists
                      (lambda (view)
                        (eq? (view-buffer view) buffer))
                      (editor-views editor))))
                (editor-remove-buffer! editor (buffer-id buffer)))
              (raise condition)])
           (let* ([context
                    (make-tui-application-context
                      editor
                      session-id
                      (buffer-id buffer)
                      origin-view-id
                      arguments)])
             (call-with-values
               (lambda () (initialize definition context arguments))
               (lambda (model commands)
                 (let ([session
                         (make-tui-session
                           session-id
                           definition
                           (buffer-id buffer)
                           model)])
                   (tui-session-set-pending-commands! session commands)
                   (tui-application-registry-add! registry session)
                   (set! registered? #t)
                   (buffer-set-presentation!
                     buffer
                     (make-tui-presentation session-id))
                   (buffer-set-local-setting!
                     buffer 'track-modified? #f)
                   (buffer-set-local-setting! buffer 'read-only? #t)
                   (buffer-set-local-setting!
                     buffer 'confirm-on-exit? #f)
                   (buffer-set-local-setting!
                     buffer 'interaction-class 'interface)
                   (tui-session-set-state! session 'ready)
                   (editor-display-buffer!
                     editor
                     (make-display-request
                       (buffer-id buffer)
                       intent
                       origin-view-id
                       #f
                       #f))
                   (editor-invalidate! editor 'application)
                   buffer))))))]))

  (define (fallback-buffer editor target)
    (or
      (find
        (lambda (buffer) (not (eq? buffer target)))
        (editor-buffers editor))
      (editor-create-buffer!
        editor
        "*scratch*"
        'fundamental-mode
        "")))

  (define (tui-close! editor session-id)
    (require-open-editor 'tui-close! editor)
    (let* ([session (editor-tui-session-ref editor session-id)]
           [buffer
             (editor-buffer-ref editor (tui-session-buffer-id session))]
           [fallback (fallback-buffer editor buffer)])
      (for-each
        (lambda (view)
          (when (eq? (view-buffer view) buffer)
            (editor-set-view-buffer!
              editor
              (view-id view)
              (buffer-id fallback))))
        (editor-views editor))
      (editor-remove-buffer! editor (buffer-id buffer))
      (editor-invalidate! editor 'application)
      session))

  (define (tui-active-session editor)
    (require-open-editor 'tui-active-session editor)
    (editor-tui-session-for-buffer
      editor
      (buffer-id (view-buffer (editor-active-view editor))))))
