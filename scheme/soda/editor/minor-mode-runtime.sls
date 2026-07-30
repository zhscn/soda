(library (soda editor minor-mode-runtime)
  (export editor-register-minor-mode!
          editor-minor-mode-active?
          editor-enable-minor-mode!
          editor-disable-minor-mode!
          editor-toggle-minor-mode!
          editor-active-minor-modes
          editor-minor-mode-keymap-layers
          editor-minor-mode-lighter)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor minor-mode)
          (soda editor prefix)
          (soda editor state))

  (define (buffer-minor-modes buffer)
    (let ([modes
            (buffer-setting-ref buffer 'minor-modes '())])
      (if (and (list? modes) (for-all symbol? modes))
          modes
          '())))

  (define (set-buffer-minor-modes! buffer modes)
    (buffer-set-local-setting! buffer 'minor-modes modes))

  (define (editor-active-minor-modes editor buffer)
    (append
      (editor-global-minor-modes editor)
      (filter
        (lambda (mode)
          (not (memq mode (editor-global-minor-modes editor))))
        (buffer-minor-modes buffer))))

  (define (editor-minor-mode-active? editor buffer name)
    (and
      (memq name (editor-active-minor-modes editor buffer))
      #t))

  (define (run-mode-hooks! editor definition phase buffer)
    (for-each
      (lambda (hook) (hook editor buffer))
      (minor-mode-hooks
        (editor-minor-mode-catalog editor)
        (minor-mode-definition-name definition)
        phase)))

  (define (editor-enable-minor-mode! editor buffer name)
    (let ([definition
            (minor-mode-catalog-ref
              (editor-minor-mode-catalog editor)
              name)])
      (unless (editor-minor-mode-active? editor buffer name)
        (case (minor-mode-definition-scope definition)
          [(global)
           (editor-set-global-minor-modes!
             editor
             (append
               (editor-global-minor-modes editor)
               (list name)))]
          [(buffer)
           (set-buffer-minor-modes!
             buffer
             (append (buffer-minor-modes buffer) (list name)))])
        ((minor-mode-definition-enable definition) editor buffer)
        (run-mode-hooks! editor definition 'enable buffer)
        (editor-invalidate! editor 'chrome)))
    name)

  (define (editor-disable-minor-mode! editor buffer name)
    (let ([definition
            (minor-mode-catalog-ref
              (editor-minor-mode-catalog editor)
              name)])
      (when (editor-minor-mode-active? editor buffer name)
        (case (minor-mode-definition-scope definition)
          [(global)
           (editor-set-global-minor-modes!
             editor
             (remq name (editor-global-minor-modes editor)))]
          [(buffer)
           (set-buffer-minor-modes!
             buffer
             (remq name (buffer-minor-modes buffer)))])
        ((minor-mode-definition-disable definition) editor buffer)
        (run-mode-hooks! editor definition 'disable buffer)
        (editor-invalidate! editor 'chrome)))
    name)

  (define (editor-toggle-minor-mode! editor buffer name prefix)
    (let ([enable?
            (if prefix
                (positive? (prefix-argument-value prefix))
                (not
                  (editor-minor-mode-active?
                    editor buffer name)))])
      (if enable?
          (editor-enable-minor-mode! editor buffer name)
          (editor-disable-minor-mode! editor buffer name))))

  (define (editor-minor-mode-keymap-layers editor buffer)
    (filter
      symbol?
      (map
        (lambda (name)
          (let ([definition
                  (minor-mode-catalog-find
                    (editor-minor-mode-catalog editor)
                    name)])
            (and
              definition
              (minor-mode-definition-keymap-layer
                definition))))
        (editor-active-minor-modes editor buffer))))

  (define (editor-minor-mode-lighter editor name)
    (let ([definition
            (minor-mode-catalog-find
              (editor-minor-mode-catalog editor)
              name)])
      (and definition
           (minor-mode-definition-lighter definition))))

  (define (editor-register-minor-mode! editor definition)
    (minor-mode-catalog-register!
      (editor-minor-mode-catalog editor)
      definition)
    (let ([name (minor-mode-definition-name definition)])
      (editor-register-command!
        editor
        name
        (lambda (context)
          (editor-toggle-minor-mode!
            (command-context-editor context)
            (view-buffer (command-context-view context))
            name
            (command-context-prefix context))
          '())
        (minor-mode-definition-documentation definition)))
    definition))
