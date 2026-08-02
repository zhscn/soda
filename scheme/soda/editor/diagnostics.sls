(library (soda editor diagnostics)
  (export install-diagnostic-commands!
          editor-register-diagnostic-result-action!
          editor-refresh-scheme-diagnostics!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor scheme-environment)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda editor location-results)
          (soda editor result-buffer)
          (soda json))

  (define scheme-diagnostic-namespace
    'scheme-semantic-diagnostics)

  (define editor-environments
    (make-weak-eq-hashtable))

  (define published-workspace-generations
    (make-weak-eq-hashtable))

  (define published-presentation-policies
    (make-weak-eq-hashtable))

  (define editor-diagnostic-result-actions
    (make-weak-eq-hashtable))

  (define (editor-register-diagnostic-result-action! editor action)
    (unless (and (editor? editor) (result-action? action))
      (assertion-violation
        'editor-register-diagnostic-result-action!
        "expected an Editor and ResultAction"
        editor action))
    (let ([current
            (hashtable-ref
              editor-diagnostic-result-actions editor '())])
      (hashtable-set!
        editor-diagnostic-result-actions
        editor
        (cons
          action
          (filter
            (lambda (candidate)
              (not
                (eq? (result-action-name candidate)
                     (result-action-name action))))
            current))))
    action)

  (define (scheme-annotation-id diagnostic)
    (list
      (scheme-diagnostic-code diagnostic)
      (scheme-diagnostic-start diagnostic)
      (scheme-diagnostic-end diagnostic)))

  (define (scheme-diagnostic->annotation diagnostic)
    (make-diagnostic
      (scheme-annotation-id diagnostic)
      (scheme-diagnostic-start diagnostic)
      (scheme-diagnostic-end diagnostic)
      (scheme-diagnostic-severity diagnostic)
      (scheme-diagnostic-message diagnostic)
      diagnostic))

  (define provisional-diagnostic-codes
    '(unclosed-delimiter
      unterminated-string
      unterminated-symbol
      unterminated-block-comment
      undefined-identifier
      unused-parameter
      unused-import
      library-not-found
      identifier-not-exported))

  (define incomplete-diagnostic-codes
    '(unclosed-delimiter
      unterminated-string
      unterminated-symbol
      unterminated-block-comment))

  (define (active-caret editor buffer)
    (let ([view (editor-active-view editor)])
      (and
        (eq? (view-buffer view) buffer)
        (view-caret view))))

  (define (incomplete-tail-start diagnostics caret)
    (fold-left
      (lambda (start diagnostic)
        (if
          (and
            (memq
              (scheme-diagnostic-code diagnostic)
              incomplete-diagnostic-codes)
            (<= (scheme-diagnostic-end diagnostic) caret))
          (if start
              (min start (scheme-diagnostic-start diagnostic))
              (scheme-diagnostic-start diagnostic))
          start))
      #f
      diagnostics))

  (define (diagnostic-presentation-key
            editor
            buffer
            diagnostics)
    (let ([caret (active-caret editor buffer)])
      (and
        caret
        (incomplete-tail-start diagnostics caret))))

  (define (presented-diagnostics diagnostics start caret)
    (if
      (not start)
      diagnostics
      (filter
        (lambda (diagnostic)
          (not
            (and
              (<= start
                  (scheme-diagnostic-start diagnostic)
                  (scheme-diagnostic-end diagnostic)
                  caret)
              (memq
                (scheme-diagnostic-code diagnostic)
                provisional-diagnostic-codes))))
        diagnostics)))

  (define (expected-presentation-key editor buffer)
    (let ([caret (active-caret editor buffer)])
      (and
        caret
        (incomplete-tail-start
          (scheme-semantic-snapshot-diagnostics
            (buffer-scheme-semantic-snapshot buffer))
          caret))))

  (define (scheme-annotation-set editor buffer)
    (find
      (lambda (set)
        (eq?
          (annotation-set-namespace set)
          scheme-diagnostic-namespace))
      (editor-annotation-sets-for-buffer
        editor
        (buffer-id buffer))))

  (define (next-generation current)
    (if current
        (+ (annotation-set-generation current) 1)
        0))

  (define (publish-scheme-diagnostics!
            editor
            buffer
            current
            index
            synchronize-workspace?)
    (let* ([snapshot
             (if index
                 (if synchronize-workspace?
                     (scheme-workspace-snapshot-for-buffer
                       index buffer)
                     (scheme-workspace-refresh-buffer!
                       index buffer))
                 (buffer-scheme-semantic-snapshot buffer))]
           [revision
             (scheme-semantic-snapshot-revision snapshot)]
           [diagnostics
             (scheme-semantic-snapshot-diagnostics snapshot)]
           [presentation-key
             (diagnostic-presentation-key
               editor buffer diagnostics)]
           [annotations
             (map
               scheme-diagnostic->annotation
               (presented-diagnostics
                 diagnostics
                 presentation-key
                 (active-caret editor buffer)))])
      (let ([set
              (make-buffer-annotation-set
                buffer
                scheme-diagnostic-namespace
                revision
                (next-generation current)
                annotations)])
        (when
          (editor-publish-annotation-set!
            editor set)
          (when index
            (hashtable-set!
              published-workspace-generations
              set
              (scheme-workspace-generation index)))
          (hashtable-set!
            published-presentation-policies
            set
            presentation-key))
        set)))

  (define (clear-scheme-diagnostics!
            editor
            buffer
            current)
    (when current
      (editor-publish-annotation-set!
        editor
        (make-buffer-annotation-set
          buffer
          scheme-diagnostic-namespace
          (buffer-revision buffer)
          (next-generation current)
          '()))))

  (define (refresh-scheme-diagnostics!
            editor
            synchronize-workspace?)
    (let ([environments
            (hashtable-ref
              editor-environments editor #f)])
      (for-each
        (lambda (buffer)
          (let ([current
                  (scheme-annotation-set editor buffer)])
            (cond
              [(scheme-buffer? buffer)
               (let ([index
                       (let ([environment
                               (scheme-environment-for-buffer
                                 environments
                                 editor
                                 (buffer-id buffer))])
                         (and
                           environment
                           (if synchronize-workspace?
                               (scheme-semantic-index-for-buffer
                                 environments editor buffer)
                               (scheme-environment-index
                                 environment))))])
                 (unless
                   (and
                   current
                   (=
                     (annotation-set-source-revision current)
                     (buffer-revision buffer))
                   (equal?
                     (hashtable-ref
                       published-presentation-policies
                       current
                       #f)
                     (expected-presentation-key editor buffer))
                     (or
                       (not index)
                       (equal?
                         (hashtable-ref
                           published-workspace-generations
                           current
                           #f)
                         (scheme-workspace-generation index))))
                   (publish-scheme-diagnostics!
                     editor
                     buffer
                     current
                     index
                     synchronize-workspace?)))]
              [current
               (clear-scheme-diagnostics!
                 editor buffer current)])))
        (editor-buffers editor))
      editor))

  (define (editor-refresh-scheme-diagnostics! editor)
    (refresh-scheme-diagnostics! editor #t))

  (define (refresh-after-buffer-event
            editor
            buffer
            . arguments)
    (editor-refresh-scheme-diagnostics! editor))

  (define (refresh-after-command
            context
            definition
            arguments
            effects
            condition)
    (guard (failure [else #f])
      (refresh-scheme-diagnostics!
        (command-context-editor context)
        #f)))

  (define (diagnostic-item? item)
    (let ([metadata (location-item-metadata item)])
      (and
        (annotation? metadata)
        (eq? (annotation-kind metadata) 'diagnostic))))

  (define (item-before? left right)
    (cond
      [(< (location-item-start left)
          (location-item-start right))
       #t]
      [(> (location-item-start left)
          (location-item-start right))
       #f]
      [else
       (< (location-item-end left)
          (location-item-end right))]))

  (define (insert-item item items)
    (cond
      [(null? items) (list item)]
      [(item-before? item (car items)) (cons item items)]
      [else (cons (car items)
                  (insert-item item (cdr items)))]))

  (define (sort-items items)
    (fold-left
      (lambda (result item) (insert-item item result))
      '()
      items))

  (define (current-diagnostic-items editor buffer)
    (sort-items
      (filter
        diagnostic-item?
        (fold-left
          (lambda (items set)
            (append
              items
              (annotation-set-location-items
                set
                (buffer-revision buffer))))
          '()
          (editor-annotation-sets-for-buffer
            editor
            (buffer-id buffer))))))

  (define (diagnostic-severity item)
    (let ([metadata (location-item-metadata item)])
      (cond
        [(annotation? metadata) (annotation-severity metadata)]
        [(scheme-diagnostic? metadata)
         (scheme-diagnostic-severity metadata)]
        [else #f])))

  (define (diagnostic-code item)
    (let ([metadata (location-item-metadata item)])
      (cond
        [(and (annotation? metadata)
              (scheme-diagnostic? (annotation-payload metadata)))
         (scheme-diagnostic-code (annotation-payload metadata))]
        [(scheme-diagnostic? metadata)
         (scheme-diagnostic-code metadata)]
        [(and (annotation? metadata)
              (json-object? (annotation-payload metadata)))
         (let ([code
                 (json-object-ref
                   (annotation-payload metadata) "code" #f)])
           (and (not (json-null? code)) code))]
        [else #f])))

  (define (diagnostic-origin item)
    (let ([metadata (location-item-metadata item)])
      (cond
        [(and (annotation? metadata)
              (json-object? (annotation-payload metadata)))
         (let ([source
                 (json-object-ref
                   (annotation-payload metadata) "source" #f)])
           (and (string? source) source))]
        [(or (scheme-diagnostic? metadata)
             (and (annotation? metadata)
                  (scheme-diagnostic?
                    (annotation-payload metadata))))
         "scheme"]
        [else #f])))

  (define (diagnostic-field->string value)
    (cond
      [(string? value) value]
      [(symbol? value) (symbol->string value)]
      [(number? value) (number->string value)]
      [else #f]))

  (define (join-diagnostic-fields fields)
    (if (null? fields)
        ""
        (let loop ([remaining (cdr fields)] [result (car fields)])
          (if (null? remaining)
              result
              (loop
                (cdr remaining)
                (string-append result " " (car remaining)))))))

  (define (diagnostic-display-item item)
    (let* ([severity (diagnostic-severity item)]
           [origin (diagnostic-origin item)]
           [code (diagnostic-field->string (diagnostic-code item))]
           [fields
             (filter
               (lambda (value) value)
               (list
                 (and severity (symbol->string severity))
                 origin
                 code))]
           [prefix
             (if (null? fields)
                 ""
                 (string-append
                   "[" (join-diagnostic-fields fields) "] "))])
      (make-location-item
        (location-item-buffer-id item)
        (location-item-resource item)
        (location-item-revision item)
        (location-item-start item)
        (location-item-end item)
        (location-item-excerpt item)
        (string-append
          prefix
          (or (location-item-presentation item)
              (location-item-excerpt item)
              ""))
        (location-item-metadata item)
        (location-item-language-context item))))

  (define (decorate-diagnostic-results! buffer)
    (for-each
      (lambda (range)
        (let* ([item
                 (buffer-text-property-ref
                   buffer (car range) 'result-item #f)]
               [severity (and item (diagnostic-severity item))]
               [code (and item (diagnostic-code item))])
          (when severity
            (buffer-add-text-properties!
              buffer (car range) (cadr range)
              `((diagnostic-severity . ,severity)
                (diagnostic-code . ,code))))))
      (buffer-text-property-ranges buffer 'result-index))
    buffer)

  (define diagnostic-severities '(error warning info hint))

  (define (diagnostic-items-for-severities items severities)
    (filter
      (lambda (item)
        (memq (diagnostic-severity item) severities))
      items))

  (define (severity-label severity)
    (case severity
      [(error) "errors"]
      [(warning) "warnings"]
      [(info) "information"]
      [else "hints"]))

  (define (toggle-severity severities severity)
    (if (memq severity severities)
        (filter (lambda (candidate) (not (eq? candidate severity)))
                severities)
        (filter
          (lambda (candidate)
            (or (eq? candidate severity) (memq candidate severities)))
          diagnostic-severities)))

  (define (register-diagnostic-filter-actions!
            editor buffer resource title source origin-view-id refresh)
    (let ([all-items
            (buffer-local-ref buffer 'diagnostic-source-items '())])
      (for-each
        (lambda (severity)
          (when
            (exists
              (lambda (item)
                (eq? (diagnostic-severity item) severity))
              all-items)
            (let ([name
                    (string->symbol
                      (string-append
                        "toggle-" (symbol->string severity)))])
              (buffer-register-result-panel-action!
                buffer
                (make-result-panel-action
                  name
                  (string-append
                    (if
                      (memq
                        severity
                        (buffer-local-ref
                          buffer
                          'diagnostic-visible-severities
                          diagnostic-severities))
                      "Hide "
                      "Show ")
                    (severity-label severity))
                  (lambda (candidate) #t)
                  (lambda (context candidate)
                    (let* ([current
                             (buffer-local-ref
                               candidate
                               'diagnostic-visible-severities
                               diagnostic-severities)]
                           [next (toggle-severity current severity)])
                      (buffer-set-local!
                        candidate 'diagnostic-visible-severities next)
                      (show-diagnostics!
                        editor resource title source all-items
                        origin-view-id refresh)
                      (let ([shown
                              (length
                                (diagnostic-items-for-severities
                                  all-items next))])
                        (editor-set-status-message!
                          editor
                          (string-append
                            "Diagnostics: " (number->string shown)
                            " of " (number->string (length all-items)))))
                      '())))))))
        diagnostic-severities))
    buffer)

  (define (show-diagnostics!
            editor resource title source items origin-view-id refresh)
    (let* ([locations (make-location-list source '())]
           [buffer
            (editor-open-result-buffer!
              editor resource 'diagnostics-mode title locations
              origin-view-id 'diagnostic #f #f)]
           [severities
             (buffer-local-ref
               buffer
               'diagnostic-visible-severities
               diagnostic-severities)]
           [visible-items
             (diagnostic-items-for-severities items severities)]
           [presented-items (map diagnostic-display-item visible-items)])
      (buffer-set-local! buffer 'diagnostic-source-items items)
      (buffer-set-local! buffer 'diagnostic-origin-view-id origin-view-id)
      (buffer-set-local!
        buffer 'diagnostic-visible-severities severities)
      (editor-set-current-location-list!
        editor (if (null? presented-items) #f locations))
      (editor-append-location-results! editor buffer presented-items)
      (when (null? presented-items)
        (editor-append-result-message!
          editor
          buffer
          (if (null? items)
              "No diagnostics."
              "No diagnostics match the active filter.")
          'info))
      (when refresh
        (buffer-set-result-refresh! buffer refresh))
      (editor-finish-result-producer! editor buffer 'ready)
      (decorate-diagnostic-results! buffer)
      (for-each
        (lambda (action)
          (buffer-register-result-action! buffer action))
        (reverse
          (hashtable-ref
            editor-diagnostic-result-actions editor '())))
      (register-diagnostic-filter-actions!
        editor buffer resource title source origin-view-id refresh)))

  (define (diagnostic-status! editor label items)
    (editor-set-status-message!
      editor
      (string-append
        label ": " (number->string (length items)))))

  (define (buffer-present-in-editor? editor buffer)
    (exists (lambda (candidate) (eq? candidate buffer))
            (editor-buffers editor)))

  (define (list-diagnostics-command context)
    (let* ([editor (command-context-editor context)]
           [buffer
             (view-buffer
               (command-context-view context))]
           [origin-view-id (view-id (command-context-view context))]
           [items
             (current-diagnostic-items editor buffer)])
      (letrec ([refresh
                 (lambda (refresh-context refresh-buffer)
                   (unless (buffer-present-in-editor? editor buffer)
                     (editor-user-error
                       'buffer-item.refresh
                       "Diagnostic source Buffer is no longer open"))
                   (let ([current-origin-view-id
                           (editor-result-origin-view-id
                             editor
                             (command-context-view refresh-context))]
                         [current
                           (current-diagnostic-items editor buffer)])
                     (show-diagnostics!
                       editor
                       "*Diagnostics*"
                       "Diagnostics"
                       'diagnostics
                       current
                       current-origin-view-id
                       refresh)
                     (diagnostic-status! editor "Diagnostics" current)
                     '()))])
        (show-diagnostics!
          editor
          "*Diagnostics*"
          "Diagnostics"
          'diagnostics
          items
          origin-view-id
          refresh)
        (diagnostic-status! editor "Diagnostics" items))
      '()))

  (define (workspace-diagnostic-item value)
    (let ([diagnostic
            (scheme-workspace-diagnostic-diagnostic value)])
      (make-location-item
        (scheme-workspace-diagnostic-buffer-id value)
        (scheme-workspace-diagnostic-resource value)
        (scheme-workspace-diagnostic-revision value)
        (scheme-diagnostic-start diagnostic)
        (scheme-diagnostic-end diagnostic)
        (scheme-workspace-diagnostic-excerpt value)
        diagnostic)))

  (define (list-workspace-diagnostics-command
            environments
            context)
    (let* ([editor (command-context-editor context)]
           [origin-view-id (view-id (command-context-view context))]
           [index
             (scheme-semantic-index-for-view
               environments editor origin-view-id)]
           [items
             (map
               workspace-diagnostic-item
               (scheme-workspace-diagnostics
                 index editor))])
      (letrec ([refresh
                 (lambda (refresh-context refresh-buffer)
                   (let* ([current-origin-view-id
                            (editor-result-origin-view-id
                              editor
                              (command-context-view refresh-context))]
                          [current-index
                            (scheme-semantic-index-for-view
                              environments editor current-origin-view-id)]
                          [current
                            (map
                              workspace-diagnostic-item
                              (scheme-workspace-diagnostics
                                current-index editor))])
                     (show-diagnostics!
                       editor
                       "*Workspace Diagnostics*"
                       "Workspace diagnostics"
                       'workspace-diagnostics
                       current
                       current-origin-view-id
                       refresh)
                     (diagnostic-status!
                       editor "Workspace diagnostics" current)
                     '()))])
        (show-diagnostics!
          editor
          "*Workspace Diagnostics*"
          "Workspace diagnostics"
          'workspace-diagnostics
          items
          origin-view-id
          refresh)
        (diagnostic-status!
          editor "Workspace diagnostics" items)
        '())))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-diagnostic-commands/internal!
            editor
            environments)
    (unless
      (or
        (not environments)
        (scheme-environment-registry? environments))
      (assertion-violation
        'install-diagnostic-commands!
        "expected a SchemeEnvironment registry"
        environments))
    (if environments
        (hashtable-set!
          editor-environments editor environments)
        (hashtable-delete!
          editor-environments editor))
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'diagnostics-mode 'location-results-mode #f 'interface
        #f
        '((track-modified? . #f) (read-only? . #t))))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'diagnostics.list
        list-diagnostics-command
        "Publish current-buffer diagnostics as a location list."))
    (when environments
      (editor-register-command!
        editor
        (make-interactive-context-command
          'diagnostics.list-workspace
          (lambda (context)
            (list-workspace-diagnostics-command
              environments context))
          "Publish Scheme workspace diagnostics as a location list.")))
    (editor-bind-key!
      editor
      (list (stroke #\g 2) (stroke #\d 0))
      'diagnostics.list)
    (when environments
      (editor-bind-key!
        editor
        (list (stroke #\g 2) (stroke #\d 2))
        'diagnostics.list-workspace))
    (for-each
      (lambda (phase)
        (editor-add-hook!
          editor
          phase
          'scheme-semantic-diagnostics
          refresh-after-buffer-event))
      '(buffer-created
        major-mode-changed
        after-revert))
    (add-command-hook!
      (editor-command-registry editor)
      'post-command
      'scheme-semantic-diagnostics
      refresh-after-command)
    (editor-refresh-scheme-diagnostics! editor)
    editor)

  (define install-diagnostic-commands!
    (case-lambda
      [(editor)
       (install-diagnostic-commands/internal!
         editor #f)]
      [(editor environments)
       (install-diagnostic-commands/internal!
         editor environments)])))
