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
          (soda editor keymap)
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

  (define (set-mode-active! editor buffer definition active?)
    (let ([name (minor-mode-definition-name definition)])
      (case (minor-mode-definition-scope definition)
        [(global)
         (editor-set-global-minor-modes!
           editor
           (if active?
               (append
                 (remq name (editor-global-minor-modes editor))
                 (list name))
               (remq name (editor-global-minor-modes editor))))]
        [(buffer)
         (set-buffer-minor-modes!
           buffer
           (if active?
               (append
                 (remq name (buffer-minor-modes buffer))
                 (list name))
               (remq name (buffer-minor-modes buffer))))])))

  (define (editor-enable-minor-mode! editor buffer name)
    (let ([definition
            (minor-mode-catalog-ref
              (editor-minor-mode-catalog editor)
              name)])
      (unless (editor-minor-mode-active? editor buffer name)
        (set-mode-active! editor buffer definition #t)
        (guard
          (condition
            [else
             (set-mode-active! editor buffer definition #f)
             (guard (rollback-condition [else #f])
               ((minor-mode-definition-disable definition)
                editor
                buffer))
             (raise condition)])
          ((minor-mode-definition-enable definition) editor buffer)
          (run-mode-hooks! editor definition 'enable buffer)
          (editor-invalidate! editor 'chrome))))
    name)

  (define (editor-disable-minor-mode! editor buffer name)
    (let ([definition
            (minor-mode-catalog-ref
              (editor-minor-mode-catalog editor)
              name)])
      (when (editor-minor-mode-active? editor buffer name)
        (guard
          (condition
            [else
             (set-mode-active! editor buffer definition #t)
             (guard (rollback-condition [else #f])
               ((minor-mode-definition-enable definition)
                editor
                buffer))
             (raise condition)])
          ((minor-mode-definition-disable definition) editor buffer)
          (set-mode-active! editor buffer definition #f)
          (run-mode-hooks! editor definition 'disable buffer)
          (editor-invalidate! editor 'chrome))))
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

  (define (validate-minor-mode-keymap! editor definition)
    (unless (minor-mode-definition? definition)
      (assertion-violation
        'editor-register-minor-mode!
        "expected a minor mode definition"
        definition))
    (let ([layer
            (minor-mode-definition-keymap-layer definition)])
      (when
        (and
          layer
          (not
            (keymap-catalog-find
              (editor-keymap-catalog editor)
              layer)))
        (assertion-violation
          'editor-register-minor-mode!
          "minor mode names an unknown keymap layer"
          layer)))
    definition)

  (define (register-minor-mode-command! editor definition)
    (let ([name (minor-mode-definition-name definition)])
      (editor-register-command!
        editor
        (make-interactive-context-command
          name
          (lambda (context)
            (editor-toggle-minor-mode!
              (command-context-editor context)
              (view-buffer (command-context-view context))
              name
              (command-context-prefix context))
            '())
          (minor-mode-definition-documentation definition))))
    definition)

  (define (active-definition-targets editor definition)
    (let ([name (minor-mode-definition-name definition)])
      (case (minor-mode-definition-scope definition)
        [(global)
         (if (memq name (editor-global-minor-modes editor))
             (list (view-buffer (editor-active-view editor)))
             '())]
        [(buffer)
         (filter
           (lambda (buffer)
             (memq name (buffer-minor-modes buffer)))
           (editor-buffers editor))])))

  (define (replacement-targets definition targets)
    (if
      (and
        (eq? (minor-mode-definition-scope definition) 'global)
        (pair? targets))
      (list (car targets))
      targets))

  (define (editor-register-minor-mode! editor definition)
    (validate-minor-mode-keymap! editor definition)
    (call-with-editor-configuration-transaction
      editor
      (lambda ()
        (let* ([catalog (editor-minor-mode-catalog editor)]
               [name (minor-mode-definition-name definition)]
               [old (minor-mode-catalog-find catalog name)]
               [old-targets
                 (if old
                     (active-definition-targets editor old)
                     '())]
               [new-targets
                 (replacement-targets definition old-targets)]
               [old-disabled '()]
               [new-enabled '()])
          (guard
            (condition
              [else
               (guard (rollback-condition [else #f])
                 (for-each
                   (lambda (buffer)
                     (editor-disable-minor-mode! editor buffer name))
                   new-enabled)
                 (when old
                   (minor-mode-catalog-register! catalog old)
                   (for-each
                     (lambda (buffer)
                       (editor-enable-minor-mode! editor buffer name))
                     (reverse old-disabled))))
               (raise condition)])
            (unless (or (not old) (eq? old definition))
              (for-each
                (lambda (buffer)
                  (editor-disable-minor-mode! editor buffer name)
                  (set! old-disabled (cons buffer old-disabled)))
                old-targets))
            (minor-mode-catalog-register! catalog definition)
            (register-minor-mode-command! editor definition)
            (unless (or (not old) (eq? old definition))
              (for-each
                (lambda (buffer)
                  (editor-enable-minor-mode! editor buffer name)
                  (set! new-enabled (cons buffer new-enabled)))
                new-targets))))))
    definition))
