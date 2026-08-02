(library (soda editor editor-settings)
  (export editor-setting-names
          editor-setting-definition
          editor-register-setting!
          editor-setting-ref
          editor-global-setting-ref
          editor-set-global-setting!
          editor-clear-global-setting!
          editor-set-buffer-setting!
          editor-clear-buffer-setting!
          call-with-editor-setting-transaction
          editor-setting-buffer)
  (import (rnrs)
          (soda editor buffer)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor invalidation)
          (soda editor setting)
          (soda editor view))

  (define (editor-buffers* editor)
    (entity-registry-values (editor-buffer-registry editor)))

  (define (editor-setting-buffer who editor buffer)
    (unless (buffer? buffer)
      (assertion-violation who "expected a buffer" buffer))
    (unless
      (eq?
        (entity-registry-ref
          (editor-buffer-registry editor)
          (buffer-id buffer))
        buffer)
      (assertion-violation
        who
        "buffer is not registered with this editor"
        buffer))
    buffer)

  (define (require-editor-setting-definition who editor name)
    (unless (symbol? name)
      (assertion-violation who "setting name must be a symbol" name))
    (let ([definition
            (setting-store-find (editor-setting-store editor) name)])
      (unless definition
        (assertion-violation who "unknown setting" name))
      definition))

  (define (editor-setting-names editor)
    (require-open-editor 'editor-setting-names editor)
    (setting-store-names (editor-setting-store editor)))

  (define (editor-setting-definition editor name)
    (require-open-editor 'editor-setting-definition editor)
    (require-editor-setting-definition
      'editor-setting-definition editor name))

  (define (editor-register-setting! editor definition)
    (require-open-editor 'editor-register-setting! editor)
    (unless (setting-definition? definition)
      (assertion-violation
        'editor-register-setting!
        "expected a setting definition"
        definition))
    (let* ([store (editor-setting-store editor)]
           [snapshot (setting-store-snapshot store)])
      (guard
        (condition
          [else
           (setting-store-restore! store snapshot)
           (raise condition)])
        (let ([registered
                (setting-store-register! store definition)])
          (for-each
            (lambda (buffer)
              (setting-store-validate
                store
                (setting-definition-name definition)
                (buffer-setting-ref
                  buffer
                  (setting-definition-name definition))))
            (editor-buffers* editor))
          (editor-invalidate!
            editor
            (setting-definition-impact definition))
          registered))))

  (define (editor-active-buffer* editor)
    (view-buffer
      (entity-registry-ref
        (editor-view-registry editor)
        (editor-active-view-id editor))))

  (define editor-setting-ref
    (case-lambda
      [(editor name)
       (editor-setting-ref editor (editor-active-buffer* editor) name)]
      [(editor buffer name)
       (require-open-editor 'editor-setting-ref editor)
       (require-editor-setting-definition
         'editor-setting-ref editor name)
       (buffer-setting-ref
         (editor-setting-buffer 'editor-setting-ref editor buffer)
         name)]))

  (define (editor-global-setting-ref editor name)
    (require-open-editor 'editor-global-setting-ref editor)
    (require-editor-setting-definition
      'editor-global-setting-ref editor name)
    (setting-store-ref (editor-setting-store editor) name))

  (define (editor-set-global-setting! editor name setting)
    (require-open-editor 'editor-set-global-setting! editor)
    (let* ([definition
             (require-editor-setting-definition
               'editor-set-global-setting! editor name)]
           [store (editor-setting-store editor)]
           [generation (setting-store-generation store)])
      (setting-store-set! store name setting)
      (unless (= generation (setting-store-generation store))
        (editor-invalidate!
          editor
          (setting-definition-impact definition)))
      setting))

  (define (editor-clear-global-setting! editor name)
    (require-open-editor 'editor-clear-global-setting! editor)
    (let* ([definition
             (require-editor-setting-definition
               'editor-clear-global-setting! editor name)]
           [store (editor-setting-store editor)]
           [generation (setting-store-generation store)])
      (setting-store-clear! store name)
      (unless (= generation (setting-store-generation store))
        (editor-invalidate!
          editor
          (setting-definition-impact definition)))
      (setting-store-ref store name)))

  (define (editor-set-buffer-setting! editor buffer name setting)
    (require-open-editor 'editor-set-buffer-setting! editor)
    (let* ([target
             (editor-setting-buffer
               'editor-set-buffer-setting! editor buffer)]
           [definition
             (require-editor-setting-definition
               'editor-set-buffer-setting! editor name)]
           [old (buffer-setting-ref target name)])
      (buffer-set-local-setting! target name setting)
      (unless (equal? old (buffer-setting-ref target name))
        (editor-invalidate!
          editor
          (setting-definition-impact definition)))
      setting))

  (define (editor-clear-buffer-setting! editor buffer name)
    (require-open-editor 'editor-clear-buffer-setting! editor)
    (let* ([target
             (editor-setting-buffer
               'editor-clear-buffer-setting! editor buffer)]
           [definition
             (require-editor-setting-definition
               'editor-clear-buffer-setting! editor name)]
           [old (buffer-setting-ref target name)])
      (buffer-clear-local-setting! target name)
      (let ([resolved (buffer-setting-ref target name)])
        (unless (equal? old resolved)
          (editor-invalidate!
            editor
            (setting-definition-impact definition)))
        resolved)))

  (define (call-with-editor-setting-transaction editor procedure)
    (require-open-editor
      'call-with-editor-setting-transaction editor)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-editor-setting-transaction
        "expected a procedure"
        procedure))
    (let ([store-snapshot
            (setting-store-snapshot (editor-setting-store editor))]
          [buffer-snapshots
            (map
              (lambda (buffer)
                (cons buffer (buffer-settings-snapshot buffer)))
              (editor-buffers* editor))])
      (guard
        (condition
          [else
           (setting-store-restore!
             (editor-setting-store editor)
             store-snapshot)
           (for-each
             (lambda (entry)
               (unless (buffer-closed? (car entry))
                 (buffer-restore-settings!
                   (car entry)
                   (cdr entry))))
             buffer-snapshots)
           (editor-invalidate! editor 'configuration)
           (raise condition)])
        (procedure))))
)
