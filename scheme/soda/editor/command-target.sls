(library (soda editor command-target)
  (export make-command-target
          command-target?
          command-target-source
          command-target-buffer-id
          command-target-document-id
          command-target-revision
          command-target-start
          command-target-end
          command-target-point
          command-target-mark
          command-target-forward?
          command-target-properties
          command-target-empty?
          command-target-current?
          require-command-target-current
          command-target-first
          command-target-second
          command-target-property-ref
          make-command-target-selector
          command-target-selector?
          command-target-selector-region-policy
          command-target-selector-allow-empty-region?
          command-target-selector-fallback
          resolve-command-target
          make-command-target-reader
          command-context-range-target
          command-context-point-target
          command-context-line-target
          command-context-buffer-target)
  (import (rnrs)
          (soda editor contract)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor condition)
          (soda editor state))

  (define-record-type
    (command-target %make-command-target command-target?)
    (fields
      source
      buffer-id
      document-id
      revision
      start
      end
      point
      mark
      forward?
      properties))

  (define-record-type
    (command-target-selector
      %make-command-target-selector
      command-target-selector?)
    (fields region-policy allow-empty-region? fallback))

  (define (make-command-target
            source
            buffer-id
            document-id
            revision
            start
            end
            point
            mark
            forward?
            properties)
    (unless (symbol? source)
      (assertion-violation
        'make-command-target
        "source must be a symbol"
        source))
    (unless
      (and
        (exact-non-negative-integer? buffer-id)
        (exact-non-negative-integer? document-id)
        (exact-non-negative-integer? revision)
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end)
        (exact-non-negative-integer? point)
        (or (not mark) (exact-non-negative-integer? mark))
        (boolean? forward?)
        (symbol-alist? properties))
      (assertion-violation
        'make-command-target
        "invalid command target"
        source
        buffer-id
        document-id
        revision
        start
        end
        point
        mark
        forward?
        properties))
    (%make-command-target
      source
      buffer-id
      document-id
      revision
      start
      end
      point
      mark
      forward?
      properties))

  (define (command-target-empty? target)
    (unless (command-target? target)
      (assertion-violation
        'command-target-empty?
        "expected a command target"
        target))
    (= (command-target-start target) (command-target-end target)))

  (define (command-target-current? target buffer)
    (unless (command-target? target)
      (assertion-violation
        'command-target-current?
        "expected a command target"
        target))
    (unless (buffer? buffer)
      (assertion-violation
        'command-target-current?
        "expected a buffer"
        buffer))
    (and
      (= (command-target-buffer-id target) (buffer-id buffer))
      (= (command-target-document-id target)
         (document-id (buffer-document buffer)))
      (= (command-target-revision target) (buffer-revision buffer))))

  (define (require-command-target-current who owner target)
    (let ([buffer
            (cond
              [(buffer? owner) owner]
              [(command-context? owner)
               (view-buffer (command-context-view owner))]
              [else
               (assertion-violation
                 who "expected a Buffer or command context" owner)])])
      (unless (command-target-current? target buffer)
        (editor-user-error who "The command target is stale"))
      buffer))

  (define (command-target-first target)
    (unless (command-target? target)
      (assertion-violation
        'command-target-first
        "expected a command target"
        target))
    (if (command-target-forward? target)
        (command-target-start target)
        (command-target-end target)))

  (define (command-target-second target)
    (unless (command-target? target)
      (assertion-violation
        'command-target-second
        "expected a command target"
        target))
    (if (command-target-forward? target)
        (command-target-end target)
        (command-target-start target)))

  (define command-target-property-ref
    (case-lambda
      [(target name)
       (command-target-property-ref target name #f)]
      [(target name default)
       (unless (command-target? target)
         (assertion-violation
           'command-target-property-ref
           "expected a command target"
           target))
       (unless (symbol? name)
         (assertion-violation
           'command-target-property-ref
           "property name must be a symbol"
           name))
       (let ([entry (assq name (command-target-properties target))])
         (if entry (cdr entry) default))]))

  (define (make-context-range-target
            context source first second properties)
    (unless (command-context? context)
      (assertion-violation
        'command-context-range-target
        "expected a command context"
        context))
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [document (buffer-document buffer)])
      (make-command-target
        source
        (buffer-id buffer)
        (document-id document)
        (buffer-revision buffer)
        (min first second)
        (max first second)
        (view-caret view)
        (and (view-mark-active? view) (view-mark view))
        (<= first second)
        properties)))

  (define command-context-range-target
    (case-lambda
      [(context source first second)
       (make-context-range-target
         context source first second '())]
      [(context source first second properties)
       (make-context-range-target
         context source first second properties)]))

  (define (region-target context allow-empty?)
    (let* ([view (command-context-view context)]
           [mark (and (view-mark-active? view) (view-mark view))])
      (and
        mark
        (or allow-empty? (not (= mark (view-caret view))))
        (command-context-range-target
          context
          'region
          mark
          (view-caret view)
          '()))))

  (define (make-command-target-selector
            region-policy
            allow-empty-region?
            fallback)
    (unless (memq region-policy '(prefer require ignore))
      (assertion-violation
        'make-command-target-selector
        "region policy must be prefer, require, or ignore"
        region-policy))
    (unless (boolean? allow-empty-region?)
      (assertion-violation
        'make-command-target-selector
        "allow-empty-region? must be a boolean"
        allow-empty-region?))
    (unless (or (not fallback) (procedure? fallback))
      (assertion-violation
        'make-command-target-selector
        "fallback must be a procedure or #f"
        fallback))
    (%make-command-target-selector
      region-policy
      allow-empty-region?
      fallback))

  (define (resolve-command-target selector context)
    (unless (command-target-selector? selector)
      (assertion-violation
        'resolve-command-target
        "expected a command target selector"
        selector))
    (unless (command-context? context)
      (assertion-violation
        'resolve-command-target
        "expected a command context"
        context))
    (let* ([policy
             (command-target-selector-region-policy selector)]
           [region
             (and
               (not (eq? policy 'ignore))
               (region-target
                 context
                 (command-target-selector-allow-empty-region?
                   selector)))])
      (cond
        [region region]
        [(eq? policy 'require)
         (editor-user-error
           'resolve-command-target
           "The region is not active")]
        [(command-target-selector-fallback selector)
         =>
         (lambda (fallback)
           (let ([target (fallback context)])
             (unless (or (not target) (command-target? target))
               (assertion-violation
                 'resolve-command-target
                 "target fallback returned an invalid value"
                 target))
             target))]
        [else #f])))

  (define (make-command-target-reader name selector)
    (unless (symbol? name)
      (assertion-violation
        'make-command-target-reader
        "name must be a symbol"
        name))
    (unless (command-target-selector? selector)
      (assertion-violation
        'make-command-target-reader
        "expected a command target selector"
        selector))
    (make-interactive-reader
      name
      (lambda (context)
        (let ([target (resolve-command-target selector context)])
          (unless target
            (editor-user-error
              name
              "No command target is available"))
          (make-interactive-ready (list target))))))

  (define (command-context-point-target context)
    (let ([point (view-caret (command-context-view context))])
      (command-context-range-target
        context 'point point point)))

  (define (with-context-text context procedure)
    (let* ([buffer
             (view-buffer (command-context-view context))]
           [snapshot
             (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (command-context-line-target context)
    (with-context-text
      context
      (lambda (text)
        (let* ([point (view-caret (command-context-view context))]
               [line (car (text-position text point))])
          (command-context-range-target
            context
            'line
            (text-line-start text line)
            (text-line-content-end text line)
            (list (cons 'line line)))))))

  (define (command-context-buffer-target context)
    (with-context-text
      context
      (lambda (text)
        (command-context-range-target
          context
          'buffer
          0
          (text-size text)
          '())))))
