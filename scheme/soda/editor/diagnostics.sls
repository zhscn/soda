(library (soda editor diagnostics)
  (export install-diagnostic-commands!
          editor-refresh-scheme-diagnostics!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor file)
          (soda editor keymap)
          (soda editor location)
          (soda editor navigation)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state))

  (define scheme-diagnostic-namespace
    'scheme-semantic-diagnostics)

  (define editor-workspaces
    (make-weak-eq-hashtable))

  (define published-workspace-generations
    (make-weak-eq-hashtable))

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
            workspace
            synchronize-workspace?)
    (let* ([snapshot
             (if
               workspace
               (if
                 synchronize-workspace?
                 (scheme-workspace-snapshot-for-buffer
                   workspace buffer)
                 (scheme-workspace-refresh-buffer!
                   workspace buffer))
               (buffer-scheme-semantic-snapshot buffer))]
           [revision
             (scheme-semantic-snapshot-revision snapshot)]
           [annotations
             (map
               scheme-diagnostic->annotation
               (scheme-semantic-snapshot-diagnostics snapshot))])
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
          (when workspace
            (hashtable-set!
              published-workspace-generations
              set
              (scheme-workspace-generation workspace))))
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
    (let ([workspace
            (hashtable-ref
              editor-workspaces editor #f)])
      (when
        (and workspace synchronize-workspace?)
        (scheme-workspace-sync-editor!
          workspace editor))
      (for-each
        (lambda (buffer)
          (let ([current
                  (scheme-annotation-set editor buffer)])
            (cond
              [(scheme-buffer? buffer)
               (unless
                 (and
                   current
                   (=
                     (annotation-set-source-revision current)
                     (buffer-revision buffer))
                   (or
                     (not workspace)
                     (equal?
                       (hashtable-ref
                         published-workspace-generations
                         current
                         #f)
                       (scheme-workspace-generation
                         workspace))))
                 (publish-scheme-diagnostics!
                   editor
                   buffer
                   current
                   workspace
                   synchronize-workspace?))]
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

  (define (list-diagnostics-command context)
    (let* ([editor (command-context-editor context)]
           [buffer
             (view-buffer
               (command-context-view context))]
           [items
             (current-diagnostic-items editor buffer)])
      (if (null? items)
          (begin
            (editor-set-current-location-list! editor #f)
            (editor-set-status-message!
              editor
              "No current diagnostics"))
          (let ([locations
                  (make-location-list 'diagnostics items)])
            (editor-set-current-location-list! editor locations)
            (editor-jump-to-buffer!
              editor
              buffer
              (location-item-start
                (location-list-current locations)))
            (editor-set-status-message!
              editor
              (string-append
                "Diagnostics: "
                (number->string (length items))))))
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

  (define (jump-to-workspace-diagnostic!
            context
            item)
    (let* ([editor (command-context-editor context)]
           [buffer-id (location-item-buffer-id item)])
      (if
        buffer-id
        (let ([buffer
                (editor-buffer-ref editor buffer-id)])
          (unless
            (=
              (buffer-revision buffer)
              (location-item-revision item))
            (assertion-violation
              'diagnostics.list-workspace
              "workspace diagnostic is stale"
              (location-item-revision item)
              (buffer-revision buffer)))
          (editor-jump-to-buffer!
            editor
            buffer
            (location-item-start item))
          #f)
        (let ([resource
                (location-item-resource item)])
          (and
            (string? resource)
            (let ([view
                    (command-context-view context)])
              (editor-jump-to-buffer!
                editor
                (view-buffer view)
                (view-caret view))
              (make-command-effect
                'file.read
                (make-open-request
                  (view-id view)
                  resource
                  (location-item-start item)))))))))

  (define (list-workspace-diagnostics-command
            workspace
            context)
    (let* ([editor (command-context-editor context)]
           [items
             (map
               workspace-diagnostic-item
               (scheme-workspace-diagnostics
                 workspace editor))])
      (if
        (null? items)
        (begin
          (editor-set-current-location-list! editor #f)
          (editor-set-status-message!
            editor
            "No workspace diagnostics")
          '())
        (let* ([locations
                 (make-location-list
                   'workspace-diagnostics
                   items)]
               [effect
                 (jump-to-workspace-diagnostic!
                   context
                   (location-list-current locations))])
          (editor-set-current-location-list!
            editor locations)
          (editor-set-status-message!
            editor
            (string-append
              "Workspace diagnostics: "
              (number->string (length items))))
          (if effect (list effect) '())))))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-diagnostic-commands/internal!
            editor
            workspace)
    (unless
      (or
        (not workspace)
        (scheme-workspace-index? workspace))
      (assertion-violation
        'install-diagnostic-commands!
        "expected a Scheme workspace index"
        workspace))
    (if workspace
        (hashtable-set!
          editor-workspaces editor workspace)
        (hashtable-delete!
          editor-workspaces editor))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'diagnostics.list
        list-diagnostics-command
        "Publish current-buffer diagnostics as a location list."))
    (when workspace
      (editor-register-command!
        editor
        (make-interactive-context-command
          'diagnostics.list-workspace
          (lambda (context)
            (list-workspace-diagnostics-command
              workspace context))
          "Publish Scheme workspace diagnostics as a location list.")))
    (editor-bind-key!
      editor
      (list (stroke #\g 2) (stroke #\d 0))
      'diagnostics.list)
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
      [(editor workspace)
       (install-diagnostic-commands/internal!
         editor workspace)])))
