(library (soda editor scheme-document-highlight)
  (export install-scheme-document-highlights!
          editor-refresh-scheme-document-highlights!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor scheme-environment)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor scheme-workspace)
          (soda editor state)
          (soda editor annotation-state))

  (define document-highlight-namespace
    'scheme-document-highlight)

  (define editor-environments
    (make-weak-eq-hashtable))

  (define editor-highlight-states
    (make-weak-eq-hashtable))

  (define (highlight-annotation highlight)
    (make-annotation
      (list
        (scheme-document-highlight-kind highlight)
        (scheme-document-highlight-start highlight)
        (scheme-document-highlight-end highlight))
      (scheme-document-highlight-start highlight)
      (scheme-document-highlight-end highlight)
      'document-highlight
      'symbol-highlight
      #f
      #f
      highlight))

  (define (semantic-snapshot
            editor
            environments
            view
            buffer)
    (let ([environment
            (scheme-environment-for-view
              environments editor (view-id view))])
      (if environment
          (scheme-workspace-refresh-buffer!
            (scheme-environment-index environment)
            buffer)
          (buffer-scheme-semantic-snapshot buffer))))

  (define (highlight-state
            environments
            editor
            view
            buffer
            caret)
    (let* ([environment
             (scheme-environment-for-view
               environments editor (view-id view))]
           [index
             (and environment
                  (scheme-environment-index environment))])
      (list
        (buffer-id buffer)
        (buffer-revision buffer)
        caret
        (and index (scheme-workspace-generation index)))))

  (define (publish-highlights!
            editor
            buffer
            snapshot
            caret)
    (let ([highlights
            (scheme-semantic-document-highlights-at
              snapshot caret)])
      (editor-clear-annotation-sets!
        editor
        document-highlight-namespace
        #f)
      (editor-publish-annotation-set!
        editor
        (make-buffer-annotation-set
          buffer
          document-highlight-namespace
          (buffer-revision buffer)
          0
          (map highlight-annotation highlights)))))

  (define (clear-highlights! editor)
    (editor-clear-annotation-sets!
      editor
      document-highlight-namespace
      #f))

  (define (editor-refresh-scheme-document-highlights!
            editor)
    (let* ([environments
             (hashtable-ref
               editor-environments editor #f)]
           [view (editor-base-view editor)]
           [buffer (view-buffer view)]
           [caret (view-caret view)]
           [snapshot
             (and
               (scheme-buffer? buffer)
               (semantic-snapshot
                 editor environments view buffer))]
           [state
             (if
               (scheme-buffer? buffer)
               (highlight-state
                 environments editor view buffer caret)
               (list 'inactive
                     (buffer-id buffer)
                     (buffer-revision buffer)))]
           [current
             (hashtable-ref
               editor-highlight-states
               editor
               #f)])
      (unless (equal? state current)
        (hashtable-set!
          editor-highlight-states editor state)
        (if
          (scheme-buffer? buffer)
          (publish-highlights!
            editor
            buffer
            snapshot
            caret)
          (clear-highlights! editor)))
      editor))

  (define (refresh-after-buffer-event
            editor
            buffer
            . arguments)
    (hashtable-delete!
      editor-highlight-states editor)
    (editor-refresh-scheme-document-highlights!
      editor))

  (define (refresh-after-command
            context
            definition
            arguments
            effects
            condition)
    (guard (failure [else #f])
      (editor-refresh-scheme-document-highlights!
        (command-context-editor context))))

  (define (install-scheme-document-highlights/internal!
            editor
            environments)
    (unless
      (or
        (not environments)
        (scheme-environment-registry? environments))
      (assertion-violation
        'install-scheme-document-highlights!
        "expected a SchemeEnvironment registry"
        environments))
    (if environments
        (hashtable-set!
          editor-environments editor environments)
        (hashtable-delete!
          editor-environments editor))
    (for-each
      (lambda (phase)
        (editor-add-hook!
          editor
          phase
          'scheme-document-highlight
          refresh-after-buffer-event))
      '(buffer-created
        major-mode-changed
        after-revert))
    (add-command-hook!
      (editor-command-registry editor)
      'post-command
      'scheme-document-highlight
      refresh-after-command)
    (editor-refresh-scheme-document-highlights!
      editor)
    editor)

  (define install-scheme-document-highlights!
    (case-lambda
      [(editor)
       (install-scheme-document-highlights/internal!
         editor #f)]
      [(editor environments)
       (install-scheme-document-highlights/internal!
         editor environments)])))
