(library (soda packages editor-options)
  (export make-editor-options-service!
          editor-options-service?
          editor-options-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel option)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base editing-options)
          (soda packages buffer-ui)
          (soda packages interaction)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host package)
          (soda host setting)
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
           [effect (set-buffer-local-option-effect auto-indent-option (not enabled?))])
      (reconfigure-buffer-option
        context effect
        (string-append "Auto-indent " (if enabled? "disabled" "enabled")))))

  (define (toggle-read-only context)
    (let* ([configuration
            (buffer-state-configuration (command-context-buffer-state context))]
           [enabled? (buffer-read-only? configuration)]
           [effect
            (make-compartment-reconfigure-effect
              buffer-read-only-compartment
              (make-buffer-read-only-extension (not enabled?)))])
      (reconfigure-buffer-option
        context effect
        (string-append "Buffer is " (if enabled? "editable" "read-only")))))

  (define (reconfigure-buffer-option context effect message)
    (result-with-message
      (make-transaction-spec
        (command-context-buffer-id context)
        (command-context-view-id context)
        (buffer-state-generation (command-context-buffer-state context))
        (make-change-set (context-document-length context) '())
        #f (list effect) '())
      context message))

  (define (current-indent-options context)
    (configuration-indent-options
      (buffer-state-configuration (command-context-buffer-state context))))

  (define (current-fill-options context)
    (configuration-fill-options
      (buffer-state-configuration (command-context-buffer-state context))))

  (define (reconfigure-indent context width insert-tabs? message)
    (reconfigure-buffer-option
      context
      (set-buffer-local-option-effect
        indent-options-option (make-indent-options width insert-tabs?))
      message))

  (define (toggle-tab-to-spaces context)
    (let* ([options (current-indent-options context)]
           [tabs? (indent-options-insert-tabs? options)])
      (reconfigure-indent
        context (indent-options-width options) (not tabs?)
        (string-append "Tab insertion " (if tabs? "uses spaces" "uses tabs")))))

  (define (set-indent-width context width)
    (unless (and (integer? width) (exact? width) (> width 0))
      (assertion-violation 'editor.set-indent-width
                           "expected a positive indentation width" width))
    (let ([options (current-indent-options context)])
      (reconfigure-indent
        context width (indent-options-insert-tabs? options)
        (string-append "Indent width set to " (number->string width)))))

  (define (reconfigure-fill context column auto-fill? message)
    (reconfigure-buffer-option
      context
      (set-buffer-local-option-effect
        fill-options-option (make-fill-options column auto-fill?))
      message))

  (define (toggle-auto-fill context)
    (let* ([options (current-fill-options context)]
           [enabled? (fill-options-auto-fill? options)])
      (reconfigure-fill
        context (fill-options-column options) (not enabled?)
        (string-append "Auto-fill " (if enabled? "disabled" "enabled")))))

  (define (set-fill-column context column)
    (unless (and (integer? column) (exact? column) (> column 0))
      (assertion-violation 'editor.set-fill-column
                           "expected a positive fill column" column))
    (let ([options (current-fill-options context)])
      (reconfigure-fill
        context column (fill-options-auto-fill? options)
        (string-append "Fill column set to " (number->string column)))))

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

  (define (toggle-line-numbers context)
    (let* ([state (command-context-view-state context)]
           [configuration (view-state-configuration state)]
           [enabled? (line-numbers-enabled? configuration)]
           [effect
            (make-compartment-reconfigure-effect
              line-number-compartment (make-line-number-extension (not enabled?)))])
      (result-with-message
        (make-view-transaction-spec
          (command-context-view-id context) (view-state-generation state)
          #f #f #f (list effect) '() #f)
        context
        (string-append "Line numbers " (if enabled? "disabled" "enabled")))))

  (define (toggle-guide-column context)
    (let* ([state (command-context-view-state context)]
           [configuration (view-state-configuration state)]
           [column (guide-column configuration)]
           [effect
            (make-compartment-reconfigure-effect
              guide-column-compartment
              (make-guide-column-extension (if column #f 80)))])
      (result-with-message
        (make-view-transaction-spec
          (command-context-view-id context) (view-state-generation state)
          #f #f #f (list effect) '() #f)
        context
        (if column "Guide column disabled" "Guide column set to 80"))))

  (define (toggle-constant-position context)
    (let* ([state (command-context-view-state context)]
           [configuration (view-state-configuration state)]
           [enabled? (constant-position-enabled? configuration)]
           [effect (make-compartment-reconfigure-effect
                     constant-position-compartment
                     (make-constant-position-extension (not enabled?)))])
      (result-with-message
        (make-view-transaction-spec (command-context-view-id context)
                                    (view-state-generation state)
                                    #f #f #f (list effect) '() #f)
        context
        (string-append "Constant position display " (if enabled? "disabled" "enabled")))))

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

  (define (parse-indent-width value)
    (let ([width (and (string? value) (string->number value))])
      (unless (and (integer? width) (exact? width) (> width 0))
        (assertion-violation 'editor.set-indent-width
                             "expected a positive indentation width" value))
      width))

  (define (parse-fill-column value)
    (let ([column (and (string? value) (string->number value))])
      (unless (and (integer? column) (exact? column) (> column 0))
        (assertion-violation 'editor.set-fill-column
                             "expected a positive fill column" value))
      column))

  (define (make-tab-width-reader)
    (make-interactive-reader
      'tab-width
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request 'tab-width "Tab width: " #f #f 'free)
          (lambda (value)
            (make-interactive-ready (list (parse-tab-width value))))))))

  (define (make-indent-width-reader)
    (make-interactive-reader
      'indent-width
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request 'indent-width "Indent width: " #f #f 'free)
          (lambda (value)
            (make-interactive-ready (list (parse-indent-width value))))))))

  (define (make-fill-column-reader)
    (make-interactive-reader
      'fill-column
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request 'fill-column "Fill column: " #f #f 'free)
          (lambda (value)
            (make-interactive-ready (list (parse-fill-column value))))))))

  (define (install-command! runtime owner name documentation procedure . readers)
    (command-runtime-register-command!
      runtime
      (make-command-definition
        name procedure owner documentation 'option
        (and (pair? readers) (make-interactive-plan (car readers))))))

  (define (parse-positive-integer input)
    (cond
      [(and (integer? input) (exact? input)) input]
      [(string? input) (string->number input)]
      [else #f]))

  (define (parse-boolean input)
    (cond
      [(boolean? input) input]
      [(and (string? input)
            (member (string-downcase input) '("true" "yes" "on" "1"))) #t]
      [(and (string? input)
            (member (string-downcase input) '("false" "no" "off" "0"))) #f]
      [else 'invalid]))

  (define (register-setting! host owner name type default scope parser materialize)
    (package-host-register-setting-schema!
      host owner
      (make-setting-schema
        name type default (list scope) parser #f
        (lambda (value ignored-scope) (materialize value)))))

  (define (register-editor-settings! host owner)
    (register-setting! host owner 'editor.tab-width 'positive-integer 8 'view
      parse-positive-integer make-tab-width-setting-extension)
    (register-setting! host owner 'editor.indent-width 'positive-integer 4 'buffer
      parse-positive-integer make-indent-width-setting-extension)
    (register-setting! host owner 'editor.fill-column 'positive-integer 80 'buffer
      parse-positive-integer make-fill-column-setting-extension)
    (register-setting! host owner 'editor.soft-wrap 'boolean #t 'view
      parse-boolean make-soft-wrap-setting-extension)
    (register-setting! host owner 'editor.line-numbers 'boolean #f 'view
      parse-boolean make-line-number-setting-extension)
    (register-setting! host owner 'editor.auto-indent 'boolean #t 'buffer
      parse-boolean make-auto-indent-setting-extension)
    (register-setting! host owner 'editor.auto-fill 'boolean #f 'buffer
      parse-boolean make-auto-fill-setting-extension)
    (register-setting! host owner 'editor.tab-to-spaces 'boolean #f 'buffer
      parse-boolean make-tab-to-spaces-setting-extension)
    (register-setting! host owner 'editor.read-only 'boolean #f 'buffer
      parse-boolean make-buffer-read-only-setting-extension))

  (define (make-editor-options-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-editor-options-service!
                           "expected a PackageHost and owner" host owner))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'editor-options)]
           [service (%make-editor-options-service keymap)])
      (register-editor-settings! host owner)
      (install-command!
        runtime owner 'editor.toggle-auto-indent
        "Toggle automatic leading indentation for the active Buffer."
        (lambda (context) (reconfigure-auto-indent context)))
      (install-command!
        runtime owner 'editor.toggle-read-only
        "Toggle whether ordinary commands may change the active Buffer."
        (lambda (context) (toggle-read-only context)))
      (install-command!
        runtime owner 'editor.toggle-soft-wrap
        "Toggle visual line wrapping for the active View."
        (lambda (context) (toggle-soft-wrap context)))
      (install-command!
        runtime owner 'editor.toggle-line-numbers
        "Toggle line-number gutter for the active View."
        (lambda (context) (toggle-line-numbers context)))
      (install-command!
        runtime owner 'editor.toggle-guide-column
        "Toggle an 80-column guide for the active View."
        (lambda (context) (toggle-guide-column context)))
      (install-command! runtime owner 'editor.toggle-constant-position
        "Toggle persistent line and column display for the active View."
        (lambda (context) (toggle-constant-position context)))
      (install-command!
        runtime owner 'editor.toggle-tab-to-spaces
        "Toggle whether Tab inserts spaces or a tab in the active Buffer."
        (lambda (context) (toggle-tab-to-spaces context)))
      (install-command!
        runtime owner 'editor.set-indent-width
        "Set the space indentation width for the active Buffer."
        (lambda (context width) (set-indent-width context width))
        (list (make-indent-width-reader)))
      (install-command!
        runtime owner 'editor.toggle-auto-fill
        "Toggle automatic hard wrapping for the active Buffer."
        (lambda (context) (toggle-auto-fill context)))
      (install-command!
        runtime owner 'editor.set-fill-column
        "Set the automatic wrapping and paragraph fill column for the active Buffer."
        (lambda (context column) (set-fill-column context column))
        (list (make-fill-column-reader)))
      (install-command!
        runtime owner 'editor.set-tab-width
        "Set the visual tab width for the active View."
        (lambda (context width) (set-tab-width context width))
        (list (make-tab-width-reader)))
      (keymap-bind! keymap (list (meta-stroke #\i)) 'editor.toggle-auto-indent)
      (keymap-bind! keymap (list (meta-stroke #\R)) 'editor.toggle-read-only)
      (keymap-bind! keymap (list (meta-stroke #\E)) 'editor.toggle-tab-to-spaces)
      (keymap-bind! keymap (list (meta-stroke #\T)) 'editor.set-indent-width)
      (keymap-bind! keymap (list (meta-stroke #\F)) 'editor.toggle-auto-fill)
      (keymap-bind! keymap (list (meta-stroke #\$)) 'editor.toggle-soft-wrap)
      service))
)
