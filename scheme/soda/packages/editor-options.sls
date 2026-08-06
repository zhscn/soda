(library (soda packages editor-options)
  (export make-editor-options-service!
          editor-options-service?
          editor-options-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base editing-options)
          (soda packages interaction)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host value)
          (soda view text-layout))

  ;; This package supplies interactive entry points for the configuration
  ;; contracts used by fundamental editing and text layout.  Option values
  ;; themselves stay in immutable Buffer/View configurations.
  (define-record-type
    (editor-options-service %make-editor-options-service editor-options-service?)
    (fields (immutable keymap editor-options-keymap)))

  (define (meta-stroke character)
    (make-key-stroke 'character (char->integer character) 2))

  (define (context-document-length context)
    (snapshot-byte-size
      (buffer-state-document (command-context-buffer-state context))))

  (define (option-message context text)
    (let ([surface-id (command-context-surface-id context)])
      (and (integer? surface-id) (exact? surface-id) (>= surface-id 0)
           (make-set-surface-message-operation surface-id text))))

  (define (result-with-message result context message)
    (let ([operation (option-message context message)])
      (if operation (list result operation) result)))

  (define (reconfigure-auto-indent context)
    (let* ([configuration
            (buffer-state-configuration (command-context-buffer-state context))]
           [enabled? (auto-indent-enabled? configuration)]
           [effect
            (make-compartment-reconfigure-effect
              auto-indent-compartment
              (make-auto-indent-extension (not enabled?)))])
      (result-with-message
        (make-transaction-spec
          (command-context-buffer-id context)
          (command-context-view-id context)
          (buffer-state-generation (command-context-buffer-state context))
          (make-change-set (context-document-length context) '())
          #f (list effect) '())
        context
        (string-append "Auto-indent " (if enabled? "disabled" "enabled")))))

  (define (current-layout-options context)
    (configuration-facet
      (view-state-configuration (command-context-view-state context))
      text-layout-options-facet 'view))

  (define (reconfigure-layout context tab-width wrap? message)
    (let* ([state (command-context-view-state context)]
           [effect
            (make-compartment-reconfigure-effect
              layout-options-compartment
              (make-layout-options-extension tab-width wrap?))])
      (result-with-message
        (make-view-transaction-spec
          (command-context-view-id context) (view-state-generation state)
          #f #f #f (list effect) '() #f)
        context message)))

  (define (toggle-soft-wrap context)
    (let* ([options (current-layout-options context)]
           [enabled? (text-layout-options-wrap? options)])
      (reconfigure-layout
        context (text-layout-options-tab-width options) (not enabled?)
        (string-append "Soft wrap " (if enabled? "disabled" "enabled")))))

  (define (set-tab-width context width)
    (unless (and (integer? width) (exact? width) (> width 0))
      (assertion-violation 'editor.set-tab-width "expected a positive tab width" width))
    (let ([options (current-layout-options context)])
      (reconfigure-layout
        context width (text-layout-options-wrap? options)
        (string-append "Tab width set to " (number->string width)))))

  (define (parse-tab-width value)
    (let ([width (and (string? value) (string->number value))])
      (unless (and (integer? width) (exact? width) (> width 0))
        (assertion-violation 'editor.set-tab-width
                             "expected a positive tab width" value))
      width))

  (define (make-tab-width-reader)
    (make-interactive-reader
      'tab-width
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request 'tab-width "Tab width: " #f #f 'free)
          (lambda (value)
            (make-interactive-ready (list (parse-tab-width value))))))))

  (define (install-command! runtime owner name documentation procedure . readers)
    (command-runtime-register-command!
      runtime
      (make-command-definition
        name procedure owner documentation 'option
        (and (pair? readers) (make-interactive-plan (car readers))))))

  (define (make-editor-options-service! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-editor-options-service!
                           "expected a command runtime and owner" runtime owner))
    (let* ([keymap (make-keymap 'editor-options)]
           [service (%make-editor-options-service keymap)])
      (install-command!
        runtime owner 'editor.toggle-auto-indent
        "Toggle automatic leading indentation for the active Buffer."
        (lambda (context) (reconfigure-auto-indent context)))
      (install-command!
        runtime owner 'editor.toggle-soft-wrap
        "Toggle visual line wrapping for the active View."
        (lambda (context) (toggle-soft-wrap context)))
      (install-command!
        runtime owner 'editor.set-tab-width
        "Set the visual tab width for the active View."
        (lambda (context width) (set-tab-width context width))
        (list (make-tab-width-reader)))
      (keymap-bind! keymap (list (meta-stroke #\i)) 'editor.toggle-auto-indent)
      (keymap-bind! keymap (list (meta-stroke #\$)) 'editor.toggle-soft-wrap)
      service))
)
