(library (soda editor workspace-edit-preview)
  (export install-workspace-edit-preview!
          editor-show-workspace-edit-preview!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor effect)
          (soda editor editable-projection)
          (soda editor event)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor location-results)
          (soda editor result-edit)
          (soda editor state)
          (soda editor workspace-edit))

  (define-record-type workspace-edit-preview
    (fields (mutable projections)
            description
            after-apply
            (mutable accepted?)))

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
              (lambda () (utf8->string (text-subbytevector text start end)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (single-line value)
    (list->string
      (map
        (lambda (character)
          (if (or (char=? character #\newline)
                  (char=? character #\return)
                  (char=? character #\tab))
              #\space
              character))
        (string->list value))))

  (define (edit-location-item editor edit)
    (let ([buffer
            (editor-buffer-for-resource
              editor (workspace-text-edit-resource edit))])
      (unless buffer
        (assertion-violation
          'editor-show-workspace-edit-preview!
          "workspace edit target is not open"
          (workspace-text-edit-resource edit)))
      (make-location-item
        (buffer-id buffer)
        (workspace-text-edit-resource edit)
        (workspace-text-edit-revision edit)
        (workspace-text-edit-start edit)
        (workspace-text-edit-end edit)
        (single-line
          (buffer-substring
            buffer
            (workspace-text-edit-start edit)
            (workspace-text-edit-end edit)))
        edit)))

  (define (preview-row item edit)
    (let ([prefix
            (string-append
              "  "
              (single-line (or (location-item-excerpt item) ""))
              "  =>  ")]
          [replacement (workspace-text-edit-text edit)])
      (values prefix replacement (string-append prefix replacement "\n"))))

  (define (append-resource-heading! editor buffer resource)
    (let* ([base (buffer-size buffer)]
           [heading (string-append resource "\n")]
           [end (+ base (bytevector-length (string->utf8 heading)))])
      (editor-append-result-text! editor buffer heading '())
      (buffer-add-text-properties!
        buffer
        base
        end
        `((face . application.heading)
          (result-group . ,resource)))))

  (define (install-edit-guard! buffer preview)
    (buffer-install-projection-edit-guard!
      buffer
      (workspace-edit-preview-projections preview)
      'workspace-edit
      "Only replacement text is editable"))

  (define (editor-show-workspace-edit-preview!
            editor origin-view-id edits description after-apply)
    (unless (and (editor? editor)
                 (integer? origin-view-id) (exact? origin-view-id)
                 (list? edits) (pair? edits)
                 (for-all workspace-text-edit? edits)
                 (string? description)
                 (procedure? after-apply))
      (assertion-violation
        'editor-show-workspace-edit-preview!
        "invalid workspace edit preview"
        editor origin-view-id edits description after-apply))
    (let* ([items (map (lambda (edit) (edit-location-item editor edit)) edits)]
           [locations (make-location-list 'workspace-edit-preview '())]
           [preview (make-workspace-edit-preview '() description after-apply #f)]
           [buffer
             (editor-open-result-buffer!
               editor
               "*Workspace Edit Preview*"
               'workspace-edit-preview-mode
               (string-append description " preview")
               locations
               origin-view-id
               'workspace-edit
               'workspace-edit.discard
               preview)])
      (let ([last-resource #f])
        (for-each
          (lambda (item edit)
            (let ([resource (location-item-resource item)])
              (unless (equal? resource last-resource)
                (append-resource-heading! editor buffer resource)
                (set! last-resource resource)))
            (let-values ([(prefix replacement row) (preview-row item edit)])
              (let* ([base (buffer-size buffer)]
                     [replacement-start
                       (+ base (bytevector-length (string->utf8 prefix)))]
                     [replacement-end
                       (+ replacement-start
                          (bytevector-length (string->utf8 replacement)))])
                (editor-append-result-text!
                  editor buffer row
                  (list
                    (list 0 (bytevector-length (string->utf8 row)) item)))
                (workspace-edit-preview-projections-set!
                  preview
                  (append
                    (workspace-edit-preview-projections preview)
                    (list
                      (make-editable-projection!
                        buffer edit replacement-start replacement-end)))))))
          items edits))
      (buffer-set-local! buffer 'workspace-edit-preview preview)
      (install-edit-guard! buffer preview)
      (let ([ranges (buffer-text-property-ranges buffer 'result-index)])
        (when (pair? ranges)
          (view-set-caret! (editor-active-view editor) (caar ranges))))
      (editor-set-status-message!
        editor
        (string-append
          description ": review " (number->string (length edits))
          (if (= (length edits) 1) " change" " changes")))
      buffer))

  (define (active-preview context who)
    (let ([preview
            (buffer-local-ref
              (view-buffer (command-context-view context))
              'workspace-edit-preview #f)])
      (unless (workspace-edit-preview? preview)
        (editor-user-error who "Current Buffer is not a workspace edit preview"))
      preview))

  (define (apply-workspace-edit-preview
            context buffer preview projections)
    (let* ([editor (command-context-editor context)]
           [edits
             (map
               (lambda (projection)
                 (let ([edit (editable-projection-source projection)])
                   (make-workspace-text-edit
                     (workspace-text-edit-resource edit)
                     (workspace-text-edit-revision edit)
                     (workspace-text-edit-start edit)
                     (workspace-text-edit-end edit)
                     (editable-projection-text buffer projection))))
               projections)])
      (workspace-text-edits-apply! editor edits)
      (workspace-edit-preview-accepted?-set! preview #t)
      (editor-set-status-message!
        editor
        (string-append
          (workspace-edit-preview-description preview)
          " in " (number->string (length edits))
          (if (= (length edits) 1) " place" " places")))
      (append
        ((workspace-edit-preview-after-apply preview) editor)
        (list
          (make-command-effect
            'command.invoke
            (make-command-message 'buffer-item.quit #f))))))

  (define (accept-workspace-edit-preview context)
    (let ([buffer (view-buffer (command-context-view context))])
      (if (buffer-projection-edit-active? buffer)
          (accept-projection-edit context)
          (let ([preview (active-preview context 'workspace-edit.accept)])
            (apply-workspace-edit-preview
              context
              buffer
              preview
              (workspace-edit-preview-projections preview))))))

  (define (edit-workspace-edit-preview context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))])
      (active-preview context 'workspace-edit.edit)
      (let ([projections
              (workspace-edit-preview-projections
                (active-preview context 'workspace-edit.edit))])
        (editor-begin-projection-edit!
          editor
          buffer
          projections
          "Edit replacement text; C-c C-c applies, C-c C-k discards"
          (lambda (accept-context edited-buffer edited-projections)
            (apply-workspace-edit-preview
              accept-context
              edited-buffer
              (active-preview accept-context 'workspace-edit.accept)
              edited-projections))
          (lambda (discard-context edited-buffer edited-projections)
            (list
              (make-command-effect
                'command.invoke
                (make-command-message 'buffer-item.quit #f))))))
      '()))

  (define (discard-workspace-edit-preview context)
    (let ([preview (command-context-argument context)])
      (when (workspace-edit-preview? preview)
        (editor-set-status-message!
          (command-context-editor context)
          (if (workspace-edit-preview-accepted? preview)
              (let ([count
                      (length
                        (workspace-edit-preview-projections preview))])
                (string-append
                  (workspace-edit-preview-description preview)
                  " in " (number->string count)
                  (if (= count 1) " place" " places")))
              (string-append
                (workspace-edit-preview-description preview) " discarded"))))
      '()))

  (define (install-workspace-edit-preview! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'workspace-edit-preview-mode
        'location-results-mode
        #f
        'interface
        'workspace-edit-preview-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\a) 0))
        'workspace-edit.accept)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\e) 0))
        'workspace-edit.edit)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\c) 4))
        'workspace-edit.accept)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'workspace-edit-preview-mode-map
        keymap))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'workspace-edit.accept
        accept-workspace-edit-preview
        "Apply every change in the current workspace edit preview."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'workspace-edit.edit
        edit-workspace-edit-preview
        "Edit replacement text in the current workspace edit preview."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'workspace-edit.discard
        discard-workspace-edit-preview
        "Discard a workspace edit preview."))
    editor)
)
