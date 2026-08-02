(library (soda editor tui-projection)
  (export tui-ensure-session-text-projection!
          tui-ensure-buffer-text-projection!
          tui-focused-accessibility
          tui-focused-copy-bytes)
  (import (rnrs)
          (soda editor buffer)
          (soda editor edit)
          (soda editor state)
          (soda editor tui-application)
          (soda tui application))

  (define (projection-bytes definition model context)
    (let ([project
            (tui-application-definition-text-projection definition)])
      (and
        project
        (let ([value (project model context)])
          (cond
            [(string? value) (string->utf8 value)]
            [(bytevector? value) value]
            [else
             (assertion-violation
               'tui.text-projection
               "text projection must return a string or bytevector"
               (tui-application-definition-name definition)
               value)])))))

  (define (tui-ensure-session-text-projection! editor session)
    (require-open-editor 'tui-ensure-session-text-projection! editor)
    (unless (tui-session? session)
      (assertion-violation
        'tui-ensure-session-text-projection!
        "expected a TuiSession"
        session))
    (unless (= (tui-session-projection-generation session)
               (tui-session-generation session))
      (let* ([buffer
               (editor-buffer-ref editor (tui-session-buffer-id session))]
             [bytes
               (projection-bytes
                 (tui-session-definition session)
                 (tui-session-model session)
                 (make-tui-application-context
                   editor
                   (tui-session-id session)
                   (tui-session-buffer-id session)
                   #f
                   (tui-session-arguments session)))])
        (when bytes
          (buffer-replace-range-internal!
            buffer 0 (buffer-byte-size buffer) bytes))
        (tui-session-set-projection-generation!
          session
          (tui-session-generation session))))
    session)

  (define (tui-ensure-buffer-text-projection! editor buffer)
    (require-open-editor 'tui-ensure-buffer-text-projection! editor)
    (unless (buffer? buffer)
      (assertion-violation
        'tui-ensure-buffer-text-projection!
        "expected a Buffer"
        buffer))
    (let ([session
            (editor-tui-session-for-buffer editor (buffer-id buffer))])
      (when session
        (tui-ensure-session-text-projection! editor session))
      buffer))

  (define (focused-node editor session view-id)
    (let* ([state (tui-session-view-state session view-id)]
           [key (and state (tui-view-state-focused-node state))])
      (and
        key
        (let ([node
                ((tui-application-definition-view
                   (tui-session-definition session))
                 (tui-session-model session)
                 (make-tui-application-context
                   editor
                   (tui-session-id session)
                   (tui-session-buffer-id session)
                   view-id
                   (tui-session-arguments session)
                   state))])
          (unless (tui-node? node)
            (assertion-violation
              'tui-focused-accessibility
              "application view must return a TuiNode"
              (tui-application-definition-name
                (tui-session-definition session))
              node))
          (tui-node-find node key)))))

  (define (tui-focused-accessibility editor view-id)
    (require-open-editor 'tui-focused-accessibility editor)
    (let* ([view (editor-view-ref editor view-id)]
           [session
             (editor-tui-session-for-buffer
               editor
               (buffer-id (view-buffer view)))]
           [node (and session (focused-node editor session view-id))])
      (and node (tui-node-accessibility node))))

  (define (copy-bytevector value)
    (let ([copy (make-bytevector (bytevector-length value))])
      (bytevector-copy! value 0 copy 0 (bytevector-length value))
      copy))

  (define (tui-focused-copy-bytes editor view-id)
    (let ([metadata (tui-focused-accessibility editor view-id)])
      (and
        metadata
        (let ([value (tui-accessibility-copy-value metadata)])
          (cond
            [(string? value) (string->utf8 value)]
            [(bytevector? value) (copy-bytevector value)]
            [else #f]))))))
