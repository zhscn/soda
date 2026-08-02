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
          (soda editor event)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor location-results)
          (soda editor state)
          (soda editor workspace-edit))

  (define-record-type workspace-edit-preview
    (fields (mutable projections)
            description
            after-apply
            (mutable accepted?)))

  (define-record-type workspace-edit-projection
    (fields edit start-anchor end-anchor))

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
              (location-item-resource item)
              ": "
              (single-line (or (location-item-excerpt item) ""))
              "  =>  ")]
          [replacement (workspace-text-edit-text edit)])
      (values prefix replacement (string-append prefix replacement "\n"))))

  (define (projection-range buffer projection)
    (let ([document (buffer-document buffer)])
      (cons
        (document-anchor-offset
          document (workspace-edit-projection-start-anchor projection))
        (document-anchor-offset
          document (workspace-edit-projection-end-anchor projection)))))

  (define (install-edit-guard! buffer preview)
    (buffer-set-local!
      buffer
      'edit-guard
      (lambda (guarded-buffer start end bytes)
        (unless
          (exists
            (lambda (projection)
              (let ([range (projection-range guarded-buffer projection)])
                (and (<= (car range) start)
                     (<= end (cdr range)))))
            (workspace-edit-preview-projections preview))
          (editor-user-error
            'workspace-edit "Only replacement text is editable" start end)))))

  (define (make-projection! buffer edit start end)
    (let ([document (buffer-document buffer)])
      (make-workspace-edit-projection
        edit
        (document-create-anchor! document start anchor-before-insertion)
        (document-create-anchor! document end anchor-after-insertion))))

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
      (for-each
        (lambda (item edit)
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
                    (make-projection!
                      buffer edit replacement-start replacement-end)))))))
        items edits)
      (buffer-set-local! buffer 'workspace-edit-preview preview)
      (install-edit-guard! buffer preview)
      (let ([ranges (buffer-text-property-ranges buffer 'location-index)])
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

  (define (accept-workspace-edit-preview context)
    (let* ([editor (command-context-editor context)]
           [preview (active-preview context 'workspace-edit.accept)]
           [buffer (view-buffer (command-context-view context))]
           [edits
             (map
               (lambda (projection)
                 (let* ([edit (workspace-edit-projection-edit projection)]
                        [range (projection-range buffer projection)])
                   (make-workspace-text-edit
                     (workspace-text-edit-resource edit)
                     (workspace-text-edit-revision edit)
                     (workspace-text-edit-start edit)
                     (workspace-text-edit-end edit)
                     (buffer-substring buffer (car range) (cdr range)))))
               (workspace-edit-preview-projections preview))])
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

  (define (edit-workspace-edit-preview context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))])
      (active-preview context 'workspace-edit.edit)
      (buffer-set-major-mode! buffer 'workspace-edit-mode)
      (buffer-set-local-setting! buffer 'read-only? #f)
      (let ([projections
              (workspace-edit-preview-projections
                (active-preview context 'workspace-edit.edit))])
        (when (pair? projections)
          (view-set-caret!
            (command-context-view context)
            (car (projection-range buffer (car projections))))))
      (editor-set-status-message!
        editor "Edit replacement text; C-c C-c applies, C-c C-k discards")
      (editor-invalidate! editor 'chrome)
      '()))

  (define (discard-workspace-edit-preview context)
    (let ([preview (command-context-argument context)])
      (when (and (workspace-edit-preview? preview)
                 (not (workspace-edit-preview-accepted? preview)))
        (editor-set-status-message!
          (command-context-editor context)
          (string-append
            (workspace-edit-preview-description preview) " discarded")))
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
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'workspace-edit-mode
        'fundamental-mode
        #f
        'editing
        'workspace-edit-mode-map
        '((track-modified? . #f) (read-only? . #f))))
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
    (let ([keymap (make-keymap)]
          [control-c
            (make-key-stroke 'character (char->integer #\c) 4)])
      (keymap-bind!
        keymap
        (list control-c control-c)
        'workspace-edit.accept)
      (keymap-bind!
        keymap
        (list control-c
              (make-key-stroke 'character (char->integer #\k) 4))
        'buffer-item.quit)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'workspace-edit-mode-map
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
