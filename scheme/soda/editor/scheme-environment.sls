(library (soda editor scheme-environment)
  (export make-scheme-environment-registry
          scheme-environment-registry?
          scheme-environment?
          scheme-environment-id
          scheme-environment-name
          scheme-environment-dialect
          scheme-environment-index
          scheme-environment-registry-environments
          scheme-environment-registry-ensure!
          scheme-environment-registry-ref
          scheme-environment-registry-find
          scheme-environment-registry-remove!
          scheme-environment-attach-buffer!
          scheme-environment-attach-view!
          scheme-environment-for-view
          scheme-environment-for-buffer
          scheme-semantic-index-for-view
          scheme-semantic-index-for-buffer)
  (import (rnrs)
          (soda editor buffer)
          (soda editor language-session)
          (soda editor scheme-query)
          (soda editor scheme-workspace)
          (soda editor state))

  (define-record-type scheme-environment
    (fields id name dialect index))

  (define-record-type
    (scheme-environment-registry
      %make-scheme-environment-registry
      scheme-environment-registry?)
    (fields
      by-id
      by-name
      by-session
      (mutable next-id)))

  (define (make-scheme-environment-registry)
    (%make-scheme-environment-registry
      (make-eqv-hashtable)
      (make-hashtable string-hash string=?)
      (make-eqv-hashtable)
      1))

  (define (require-registry who registry)
    (unless (scheme-environment-registry? registry)
      (assertion-violation
        who
        "expected a SchemeEnvironment registry"
        registry)))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (scheme-environment-registry-environments registry)
    (require-registry
      'scheme-environment-registry-environments
      registry)
    (let-values
      ([(ids environments)
        (hashtable-entries
          (scheme-environment-registry-by-id registry))])
      (vector->list environments)))

  (define (scheme-environment-registry-ref registry id)
    (require-registry 'scheme-environment-registry-ref registry)
    (or
      (and
        (integer? id)
        (exact? id)
        (positive? id)
        (hashtable-ref
          (scheme-environment-registry-by-id registry)
          id
          #f))
      (assertion-violation
        'scheme-environment-registry-ref
        "unknown SchemeEnvironment"
        id)))

  (define (scheme-environment-registry-find registry name)
    (require-registry 'scheme-environment-registry-find registry)
    (unless (non-empty-string? name)
      (assertion-violation
        'scheme-environment-registry-find
        "environment name must be a non-empty string"
        name))
    (hashtable-ref
      (scheme-environment-registry-by-name registry)
      name
      #f))

  (define (scheme-environment-registry-ensure!
            registry
            name
            dialect)
    (require-registry 'scheme-environment-registry-ensure! registry)
    (unless (non-empty-string? name)
      (assertion-violation
        'scheme-environment-registry-ensure!
        "environment name must be a non-empty string"
        name))
    (unless (symbol? dialect)
      (assertion-violation
        'scheme-environment-registry-ensure!
        "dialect must be a symbol"
        dialect))
    (let ([existing
            (scheme-environment-registry-find registry name)])
      (cond
        [(not existing)
         (let* ([id
                  (scheme-environment-registry-next-id registry)]
                [environment
                  (make-scheme-environment
                    id
                    name
                    dialect
                    (make-scheme-workspace-index))])
           (scheme-environment-registry-next-id-set!
             registry
             (+ id 1))
           (hashtable-set!
             (scheme-environment-registry-by-id registry)
             id
             environment)
           (hashtable-set!
             (scheme-environment-registry-by-name registry)
             name
             environment)
           environment)]
        [(eq? dialect (scheme-environment-dialect existing))
         existing]
        [else
         (assertion-violation
           'scheme-environment-registry-ensure!
           "environment dialect does not match the existing environment"
           name
           dialect
           (scheme-environment-dialect existing))])))

  (define (scheme-environment-registry-remove! registry editor id)
    (let ([environment
            (scheme-environment-registry-ref registry id)])
      (let-values
        ([(session-ids environments)
          (hashtable-entries
            (scheme-environment-registry-by-session registry))])
        (let loop ([position 0])
          (when (< position (vector-length session-ids))
            (when
              (eq? environment (vector-ref environments position))
              (let ([session-id (vector-ref session-ids position)])
                (editor-remove-language-session! editor session-id)
                (hashtable-delete!
                  (scheme-environment-registry-by-session registry)
                  session-id)))
            (loop (+ position 1)))))
      (scheme-workspace-clear!
        (scheme-environment-index environment))
      (hashtable-delete!
        (scheme-environment-registry-by-id registry)
        id)
      (hashtable-delete!
        (scheme-environment-registry-by-name registry)
        (scheme-environment-name environment))
      environment))

  (define (scheme-environment-attach-view!
            registry
            editor
            view-id
            environment)
    (require-registry 'scheme-environment-attach-view! registry)
    (unless (scheme-environment? environment)
      (assertion-violation
        'scheme-environment-attach-view!
        "expected a SchemeEnvironment"
        environment))
    (let* ([view (editor-view-ref editor view-id)]
           [buffer (view-buffer view)]
           [attachment
             (scheme-environment-attach-buffer!
               registry
               editor
               (buffer-id buffer)
               environment
               view-id)])
      (editor-set-view-language-attachment!
        editor view-id attachment)
      attachment))

  (define (scheme-environment-attach-buffer!
            registry
            editor
            buffer-id
            environment
            origin-view-id)
    (require-registry 'scheme-environment-attach-buffer! registry)
    (unless (scheme-environment? environment)
      (assertion-violation
        'scheme-environment-attach-buffer!
        "expected a SchemeEnvironment"
        environment))
    (let ([buffer (editor-buffer-ref editor buffer-id)])
      (unless (scheme-buffer? buffer)
        (assertion-violation
          'scheme-environment-attach-buffer!
          "Buffer is not in Scheme mode"
          (buffer-major-mode-name buffer)))
      (let* ([key
               (make-language-session-key
                 'scheme
                 'soda-static
                 '()
                 (list
                   (cons 'dialect
                         (scheme-environment-dialect environment)))
                 (scheme-environment-id environment)
                 '())]
             [session
               (editor-ensure-language-session! editor key)]
             [attachment
               (editor-attach-language-session!
                 editor
                 buffer-id
                 session
                 'home
                 origin-view-id)])
        (hashtable-set!
          (scheme-environment-registry-by-session registry)
          (language-session-id session)
          environment)
        (scheme-workspace-attach-buffer!
          (scheme-environment-index environment)
          buffer)
        attachment)))

  (define (environment-for-attachment registry attachment)
    (and
      attachment
      (hashtable-ref
        (scheme-environment-registry-by-session registry)
        (language-attachment-session-id attachment)
        #f)))

  (define (scheme-environment-for-view registry editor view-id)
    (require-registry 'scheme-environment-for-view registry)
    (environment-for-attachment
      registry
      (editor-view-language-attachment editor view-id)))

  (define (scheme-environment-for-buffer registry editor buffer-id)
    (require-registry 'scheme-environment-for-buffer registry)
    (let ([environments
            (fold-left
              (lambda (result attachment)
                (let ([environment
                        (environment-for-attachment
                          registry attachment)])
                  (if
                    (or
                      (not environment)
                      (memq environment result))
                    result
                    (cons environment result))))
              '()
              (editor-buffer-language-attachments
                editor buffer-id))])
      (and (= (length environments) 1) (car environments))))

  (define (standalone-index buffer)
    (let ([index (make-scheme-workspace-index)])
      (scheme-workspace-attach-buffer! index buffer)
      index))

  (define (scheme-semantic-index-for-view
            registry editor view-id)
    (let* ([view (editor-view-ref editor view-id)]
           [environment
             (scheme-environment-for-view
               registry editor view-id)]
           [index
             (if environment
                 (scheme-environment-index environment)
                 (standalone-index (view-buffer view)))])
      (when environment
        (scheme-workspace-attach-buffer!
          index
          (view-buffer view)))
      (scheme-workspace-sync-editor! index editor)
      index))

  (define (scheme-semantic-index-for-buffer
            registry editor buffer)
    (require-registry 'scheme-semantic-index-for-buffer registry)
    (unless (buffer? buffer)
      (assertion-violation
        'scheme-semantic-index-for-buffer
        "expected a buffer"
        buffer))
    (let* ([environment
             (scheme-environment-for-buffer
               registry editor (buffer-id buffer))]
           [index
             (if environment
                 (scheme-environment-index environment)
                 (standalone-index buffer))])
      (when environment
        (scheme-workspace-attach-buffer! index buffer))
      (scheme-workspace-sync-editor! index editor)
      index))
)
