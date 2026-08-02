(library (soda editor debugger-commands)
  (export install-debugger-commands!
          interaction-attach-debugger-result!
          editor-capture-condition!)
  (import (rnrs)
          (only (chezscheme) display-condition)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor comint)
          (soda editor completion)
          (soda editor condition)
          (soda editor debugger)
          (soda editor debugger-action)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor file)
          (soda editor interaction)
          (soda editor inspector)
          (soda editor keymap)
          (soda editor language)
          (soda editor prompt)
          (soda editor source-debug)
          (soda editor state)
          (soda editor language-state)
          (soda editor window)
          (soda editor window-runtime))

  (define (debugger-resource debugger)
    (string-append
      "*scheme-debugger:"
      (symbol->string (debugger-session-origin debugger))
      ":"
      (if (debugger-session-interaction-id debugger)
          (number->string
            (debugger-session-interaction-id debugger))
          "editor")
      "*"))

  (define (debugger-buffer editor debugger)
    (let ([id (debugger-session-buffer-id debugger)])
      (and
        id
        (find
          (lambda (buffer) (= (buffer-id buffer) id))
          (editor-buffers editor)))))

  (define (visible-view-for-buffer editor target-buffer-id)
    (find
      (lambda (view)
        (and
          (= (buffer-id (view-buffer view)) target-buffer-id)
          (editor-window-for-view editor (view-id view))))
      (editor-views editor)))

  (define (refresh-debugger-buffer! editor debugger)
    (let ([buffer (debugger-buffer editor debugger)])
      (when buffer
        (buffer-replace-range-internal!
          buffer
          0
          (buffer-byte-size buffer)
          (string->utf8
            (debugger-session->string debugger)))
        (for-each
          (lambda (view)
            (when (= (buffer-id (view-buffer view))
                     (buffer-id buffer))
              (view-set-caret!
                view
                (debugger-session-selected-frame-byte-offset
                  debugger))))
          (editor-views editor)))
      buffer))

  (define (make-action-context
            editor
            session
            debugger
            action
            argument)
    (make-debugger-action-context
      editor
      session
      debugger
      (debugger-session-selected-frame debugger)
      (debugger-session-condition debugger)
      (debugger-session-continuation debugger)
      action
      argument))

  (define (initialize-debugger!
            editor
            session
            debugger)
    (debugger-session-set-change-listener!
      debugger
      (lambda (changed)
        (refresh-debugger-buffer!
          editor
          changed)))
    (let ([context
            (make-action-context
              editor session debugger #f #f)])
      (editor-apply-debugger-action-providers!
        editor
        context)
      (editor-run-hooks!
        editor
        'debugger-created
        context))
    debugger)

  (define (buffer-with-id editor id)
    (and
      id
      (find
        (lambda (buffer) (= (buffer-id buffer) id))
        (editor-buffers editor))))

  (define (remove-debugger-buffer! editor debugger)
    (let ([buffer (debugger-buffer editor debugger)]
          [return-buffer
            (buffer-with-id
              editor
              (debugger-session-return-buffer-id debugger))])
      (when buffer
        (for-each
          (lambda (view)
            (when (= (buffer-id (view-buffer view))
                     (buffer-id buffer))
              (let ([leaf
                      (editor-window-for-view
                        editor
                        (view-id view))]
                    [visible-return
                      (and
                        return-buffer
                        (visible-view-for-buffer
                          editor
                          (buffer-id return-buffer)))])
                (if
                  (and
                    leaf
                    visible-return
                    (> (length (editor-window-leaves editor)) 1))
                  (begin
                    (editor-set-active-window-id!
                      editor
                      (window-leaf-id leaf))
                    (editor-set-active-view!
                      editor
                      (view-id view))
                    (editor-delete-window! editor))
                  (when return-buffer
                    (editor-set-view-buffer!
                      editor
                      (view-id view)
                      (buffer-id return-buffer))
                    (when
                      (debugger-session-return-caret debugger)
                      (view-set-caret!
                        view
                        (min
                          (debugger-session-return-caret debugger)
                          (buffer-byte-size return-buffer)))))))))
          (filter
            (lambda (view)
              (= (buffer-id (view-buffer view))
                 (buffer-id buffer)))
            (editor-views editor)))
        (let ([return-view
                (and
                  return-buffer
                  (visible-view-for-buffer
                    editor
                    (buffer-id return-buffer)))])
          (when return-view
            (editor-select-view-window!
              editor
              (view-id return-view))))
        (editor-remove-buffer! editor (buffer-id buffer))
        (debugger-session-set-buffer-id! debugger #f))))

  (define (discard-debugger! editor session debugger)
    (when debugger
      (remove-debugger-buffer! editor debugger)
      (debugger-session-close! debugger)
      (if session
          (interaction-session-set-debugger! session #f)
          (when (eq? (editor-debugger editor) debugger)
            (editor-set-debugger! editor #f)))))

  (define (close-session-debugger! editor session)
    (discard-debugger!
      editor
      session
      (interaction-session-debugger session)))

  (define (open-debugger! editor debugger)
    (let* ([return-buffer-id
             (debugger-session-return-buffer-id debugger)]
           [return-view
             (and
               return-buffer-id
               (visible-view-for-buffer editor return-buffer-id))]
           [origin-view
             (or return-view (editor-active-view editor))]
           [buffer (debugger-buffer editor debugger)])
      (unless buffer
        (set! buffer
          (editor-create-buffer!
            editor
            (debugger-resource debugger)
            'debugger-mode
            (debugger-session->string debugger)
            (editor-view-resource-context
              editor
              (view-id origin-view))))
        (buffer-set-local-setting!
          buffer
          'track-modified?
          #f)
        (debugger-session-set-buffer-id!
          debugger
          (buffer-id buffer)))
      (let* ([target
               (editor-display-buffer!
                 editor
                 (make-display-request
                   (buffer-id buffer)
                   'tools
                   (view-id origin-view)
                   #f
                   (editor-view-resource-context
                     editor
                     (view-id origin-view))))])
      (view-set-caret!
        target
        (debugger-session-selected-frame-byte-offset debugger))
      (editor-set-status-message!
        editor
        (if
          (and
            (debugger-session-interaction-id debugger)
            (evaluation-suspension-condition?
              (debugger-session-condition debugger)))
          "Debugger: c continue, r action, q abort, k continuation"
          "Debugger: n/p frame, e eval, i condition, l local, d/u inspect"))
      buffer)))

  (define (editor-capture-condition! editor label condition)
    (guard
      (capture-condition
        [else
         (editor-set-status-message!
           editor
           "Editor command failed; debugger is unavailable")
         #f])
      (let ([current (editor-debugger editor)])
        (when current
          (discard-debugger! editor #f current)))
      (let* ([view (editor-active-view editor)]
             [buffer (view-buffer view)]
             [debugger
               (make-condition-debugger-session
                 'command
                 (cond
                   [(symbol? label) (symbol->string label)]
                   [(string? label) label]
                   [else "editor command"])
                 (buffer-id buffer)
                 (view-caret view)
                 condition)])
        (editor-set-debugger! editor debugger)
        (initialize-debugger!
          editor #f debugger)
        (open-debugger! editor debugger)
        debugger)))

  (define (interaction-attach-debugger-result!
            editor
            session
            result)
    (close-session-debugger! editor session)
    (if
      (memq
        (evaluation-result-status result)
        '(condition suspended))
        (guard (condition
                 [else
                  (editor-set-status-message!
                    editor
                    "Evaluation failed; debugger is unavailable")])
          (let ([debugger
                  (make-debugger-session session result)])
            (interaction-session-set-debugger!
              session
              debugger)
            (initialize-debugger!
              editor session debugger)
            (if
              (eq? (evaluation-result-status result) 'suspended)
              (begin
                (open-debugger!
                  editor
                  debugger)
                (editor-set-status-message!
                  editor
                  "Evaluation suspended; c continue, r action, q abort"))
              (editor-set-status-message!
                editor
                "Evaluation failed; M-x scheme.debug-open"))))
        (editor-set-status-message! editor #f)))

  (define (debugger-matches-buffer? debugger buffer-id)
    (and
      debugger
      (not (debugger-session-closed? debugger))
      (or
        (equal? (debugger-session-buffer-id debugger) buffer-id)
        (equal?
          (debugger-session-return-buffer-id debugger)
          buffer-id))))

  (define (debugger-visible? editor debugger)
    (let ([buffer-id
            (and debugger
                 (debugger-session-buffer-id debugger))])
      (and
        buffer-id
        (visible-view-for-buffer editor buffer-id))))

  (define (active-debug-target editor view)
    (let* ([buffer-id (buffer-id (view-buffer view))]
           [interaction
             (editor-interaction-for-buffer editor buffer-id)])
      (cond
        [(and
           interaction
           (interaction-session-debugger interaction))
         (list
           interaction
           (interaction-session-debugger interaction))]
        [(find
           (lambda (session)
             (debugger-matches-buffer?
               (interaction-session-debugger session)
               buffer-id))
           (editor-interactions editor))
         =>
         (lambda (session)
           (list
             session
             (interaction-session-debugger session)))]
        [(find
           (lambda (session)
             (debugger-visible?
               editor
               (interaction-session-debugger session)))
           (editor-interactions editor))
         =>
         (lambda (session)
           (list
             session
             (interaction-session-debugger session)))]
        [(debugger-matches-buffer?
           (editor-debugger editor)
           buffer-id)
         (list #f (editor-debugger editor))]
        [(editor-debugger editor)
         (list #f (editor-debugger editor))]
        [else #f])))

  (define (require-debug-target who context)
    (let* ([editor (command-context-editor context)]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (unless target
        (assertion-violation
          who
          "active buffer has no saved debugger"))
      target))

  (define (source-display-view editor debugger)
    (let* ([active (editor-active-view editor)]
           [return-buffer-id
             (debugger-session-return-buffer-id debugger)]
           [return-buffer
             (and
               return-buffer-id
               (buffer-with-id editor return-buffer-id))]
           [buffer
             (or return-buffer (view-buffer active))]
           [intent (if return-buffer 'jump 'pop)])
      (editor-display-buffer!
        editor
        (make-display-request
          (buffer-id buffer)
          intent
          (view-id active)
          #f
          (editor-view-resource-context
            editor
            (view-id active))))))

  (define (require-debugger-action who target id)
    (let ([action
            (debugger-session-action
              (cadr target)
              id)])
      (unless action
        (editor-user-error
          who
          (string-append
            "The debugger does not provide the "
            (symbol->string id)
            " action")))
      action))

  (define (debug-open-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-open
               context)]
           [debugger (cadr target)])
      (open-debugger!
        editor
        debugger)
      '()))

  (define (move-debug-frame-command context delta)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-frame
               context)]
           [debugger (cadr target)]
           [count (command-context-count context)])
      (unless debugger
        (assertion-violation
          'scheme.debug-frame
          "failed interaction has no debugger"))
      (if (positive? delta)
          (debugger-session-next-frame! debugger count)
          (debugger-session-previous-frame! debugger count))
      '()))

  (define (debug-next-frame-command context)
    (move-debug-frame-command context 1))

  (define (debug-previous-frame-command context)
    (move-debug-frame-command context -1))

  (define (debug-visit-source-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-visit-source
               context)]
           [debugger (cadr target)]
           [stop
             (debugger-session-source-stop debugger)]
           [stop-location
             (and stop
                  (source-debug-stop-location stop))]
           [stop-resource
             (and stop-location
                  (source-location-resource stop-location))]
           [source-buffer
             (and stop-resource
                  (editor-buffer-for-resource
                    editor
                    stop-resource))]
           [frame
             (debugger-session-selected-frame
               debugger)])
      (cond
        [source-buffer
         (let ([target
                 (editor-display-buffer!
                   editor
                   (make-display-request
                     (buffer-id source-buffer)
                     'jump
                     (view-id (command-context-view context))
                     #f
                     (editor-view-resource-context
                       editor
                       (view-id
                         (command-context-view context)))))])
           (view-set-caret!
             target
             (min
               (source-location-start stop-location)
               (buffer-byte-size source-buffer))))
         '()]
        [(and stop-location (string? stop-resource))
         (let ([target
                 (source-display-view
                   editor
                   debugger)])
           (editor-set-status-message!
             editor
             (string-append "Reading " stop-resource))
           (list
             (make-command-effect
               'file.read
               (make-open-request
                 (view-id target)
                 stop-resource
                 (source-location-start stop-location)))))]
        [(and
           frame
           (string? (debugger-frame-source-path frame))
           (integer? (debugger-frame-source-line frame))
           (exact? (debugger-frame-source-line frame))
           (not (negative? (debugger-frame-source-line frame))))
         (let ([target
                 (source-display-view
                   editor
                   debugger)])
           (editor-set-status-message!
             editor
             (string-append
               "Reading "
               (debugger-frame-source-path frame)))
           (list
             (make-command-effect
               'file.read
               (make-open-request
                 (view-id target)
                 (debugger-frame-source-path frame)
                 (make-file-source-position
                   (debugger-frame-source-line frame)
                   (or
                     (debugger-frame-source-character frame)
                     0))))))]
        [else
         (editor-user-error
           'scheme.debug-visit-source
           "selected frame has no source location")])))

  (define (values->string values)
    (call-with-string-output-port
      (lambda (port)
        (cond
          [(null? values) (display "#<void>" port)]
          [else
           (let loop ([remaining values] [first? #t])
             (unless (null? remaining)
               (unless first? (display " " port))
               (write (car remaining) port)
               (loop (cdr remaining) #f)))]))))

  (define (debug-eval-frame-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-eval-frame
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(string? argument)
         (guard
           (condition
             [else
              (editor-set-status-message!
                editor
                (string-append
                  "Debugger evaluation failed: "
                  (condition-display-string condition)))])
           (let ([values
                   (debugger-session-evaluate
                     debugger
                     argument)])
             (editor-set-status-message!
               editor
               (string-append
                 argument
                 " => "
                 (values->string values)))))]
        [(not argument)
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Evaluate in frame: "
             ""
             'scheme-debug-eval
             #f
             'free
             #f
             'scheme.debug-eval-frame-accept
             #f
             (cons
               (debugger-session-origin debugger)
               (debugger-session-generation debugger))))]
        [else
         (assertion-violation
           'scheme.debug-eval-frame
           "expression must be a string or #f"
           argument)])
      '()))

  (define (debug-eval-frame-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (prompt-result-value result))])
      (when (and source (positive? (string-length source)))
        (let ([target
                (active-debug-target
                  editor
                  (command-context-view context))])
          (when target
            (let ([debugger (cadr target)])
              (when
                (and
                  (pair? identity)
                  (eq? (car identity)
                       (debugger-session-origin debugger))
                  (= (cdr identity)
                     (debugger-session-generation debugger)))
                (guard
                  (condition
                    [else
                     (editor-set-status-message!
                       editor
                       (string-append
                         "Debugger evaluation failed: "
                         (condition-display-string condition)))])
                  (let ([values
                          (debugger-session-evaluate
                            debugger
                            source)])
                    (editor-set-status-message!
                      editor
                      (string-append
                        source
                        " => "
                        (values->string values))))))))))
      '()))

  (define (debug-inspect-ref-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-ref
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(and (integer? argument)
              (exact? argument)
              (not (negative? argument)))
         (debugger-session-inspection-down! debugger argument)
         #f]
        [(not argument)
         (unless (debugger-session-inspection-active? debugger)
           (editor-user-error
             'scheme.debug-inspect-ref
             "evaluate an expression before inspecting a child"))
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Inspect child index: "
             ""
             'scheme-debug-inspect-ref
             #f
             'free
             #f
             'scheme.debug-inspect-ref-accept
             #f
             (cons
               (debugger-session-origin debugger)
               (debugger-session-generation debugger))))]
        [else
         (assertion-violation
           'scheme.debug-inspect-ref
           "child index must be a non-negative exact integer or #f"
           argument)])
      '()))

  (define (debug-inspect-local-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-local
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(and (integer? argument)
              (exact? argument)
              (not (negative? argument)))
         (debugger-session-inspect-local! debugger argument)
         #f]
        [(not argument)
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Inspect local index: "
             ""
             'scheme-debug-inspect-local
             #f
             'free
             #f
             'scheme.debug-inspect-local-accept
             #f
             (cons
               (debugger-session-origin debugger)
               (debugger-session-generation debugger))))]
        [else
         (assertion-violation
           'scheme.debug-inspect-local
           "local index must be a non-negative exact integer or #f"
           argument)])
      '()))

  (define (debug-inspect-condition-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-condition
               context)]
           [debugger (cadr target)])
      (debugger-session-inspect-condition! debugger)
      '()))

  (define (debug-inspect-continuation-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-continuation
               context)]
           [debugger (cadr target)])
      (guard
        (condition
          [else
           (editor-user-error
             'scheme.debug-inspect-continuation
             "The raise continuation is unavailable")])
        (debugger-session-inspect-continuation! debugger)
        #f)
      '()))

  (define (apply-inspect-local-result! editor view result)
    (let* ([identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (prompt-result-value result))]
           [target (active-debug-target editor view)])
      (when
        (and target source (positive? (string-length source)))
        (let ([debugger (cadr target)])
          (when
            (and
              (pair? identity)
              (eq? (car identity)
                   (debugger-session-origin debugger))
              (= (cdr identity)
                 (debugger-session-generation debugger)))
            (let ([index (string->number source)])
              (unless
                (and index
                     (integer? index)
                     (exact? index)
                     (not (negative? index)))
                (editor-user-error
                  'scheme.debug-inspect-local
                  "local index must be a non-negative integer"))
              (debugger-session-inspect-local! debugger index)
              #f))))))

  (define (debug-inspect-local-accept-command context)
    (apply-inspect-local-result!
      (command-context-editor context)
      (command-context-view context)
      (command-context-argument context))
    '())

  (define (debug-inspect-ref-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (prompt-result-value result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (when
        (and target
             source
             (positive? (string-length source)))
        (let ([debugger (cadr target)])
          (when
            (and
              (pair? identity)
              (eq? (car identity)
                   (debugger-session-origin debugger))
              (= (cdr identity)
                 (debugger-session-generation debugger)))
            (let ([index (string->number source)])
              (unless
                (and index
                     (integer? index)
                     (exact? index)
                     (not (negative? index)))
                (editor-user-error
                  'scheme.debug-inspect-ref
                  "child index must be a non-negative integer"))
              (debugger-session-inspection-down!
                debugger
                index)))))
      '()))

  (define (debug-inspect-up-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-up
               context)]
           [debugger (cadr target)])
      (debugger-session-inspection-up! debugger)
      '()))

  (define (debug-inspect-top-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-top
               context)]
           [debugger (cadr target)])
      (debugger-session-inspection-top! debugger)
      '()))

  (define (debug-inspect-next-page-command context)
    (let* ([target
             (require-debug-target
               'scheme.debug-inspect-next-page
               context)]
           [debugger (cadr target)])
      (debugger-session-inspection-next-page!
        debugger)
      '()))

  (define (debug-inspect-previous-page-command context)
    (let* ([target
             (require-debug-target
               'scheme.debug-inspect-previous-page
               context)]
           [debugger (cadr target)])
      (debugger-session-inspection-previous-page!
        debugger)
      '()))

  (define (debug-inspect-render-command
            context
            who
            style)
    (let* ([target
             (require-debug-target who context)]
           [debugger (cadr target)])
      (guard
        (condition
          [else
           (editor-user-error
             who
             (string-append
               "Inspector rendering failed: "
               (condition-display-string condition)))])
        (debugger-session-inspection-render!
          debugger
          style))
      '()))

  (define (debug-inspect-print-command context)
    (debug-inspect-render-command
      context
      'scheme.debug-inspect-print
      'print))

  (define (debug-inspect-write-command context)
    (debug-inspect-render-command
      context
      'scheme.debug-inspect-write
      'write))

  (define (run-inspector-find!
            editor
            debugger
            source)
    (guard
      (condition
        [else
         (editor-user-error
           'scheme.debug-inspect-find
           (string-append
             "Inspector search failed: "
             (condition-display-string condition)))])
      (unless
        (debugger-session-inspection-find!
          debugger
          source)
        (editor-user-error
          'scheme.debug-inspect-find
          "No matching object"))
      '()))

  (define (debug-inspect-find-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-find
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(string? argument)
         (run-inspector-find!
           editor
           debugger
           argument)]
        [(not argument)
         (unless
           (debugger-session-inspection-node debugger)
           (editor-user-error
             'scheme.debug-inspect-find
             "The debugger has no inspected object"))
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Find object matching predicate: "
             ""
             'scheme-debug-inspect-find
             #f
             'must-match
             (lambda (value)
               (positive? (string-length value)))
             'scheme.debug-inspect-find-accept
             #f
             debugger))
         '()]
        [else
         (assertion-violation
           'scheme.debug-inspect-find
           "predicate expression must be a string or #f"
           argument)])))

  (define (debug-inspect-find-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [debugger
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (if
        (and
          target
          source
          (eq? debugger (cadr target)))
        (run-inspector-find!
          editor
          debugger
          source)
        '())))

  (define (debug-inspect-find-next-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-find-next
               context)]
           [debugger (cadr target)])
      (guard
        (condition
          [else
           (editor-user-error
             'scheme.debug-inspect-find-next
             (string-append
               "Inspector search failed: "
               (condition-display-string condition)))])
        (unless
          (debugger-session-inspection-find-next!
            debugger)
          (editor-user-error
            'scheme.debug-inspect-find-next
            "No further matching object")))
      '()))

  (define (debug-inspect-role context who role)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target who context)]
           [debugger (cadr target)])
      (guard
        (condition
          [else
           (editor-user-error
             who
             "The inspected object does not expose that component")])
        (debugger-session-inspection-select-role!
          debugger
          role))
      '()))

  (define (debug-inspect-code-command context)
    (debug-inspect-role
      context
      'scheme.debug-inspect-code
      'code))

  (define (debug-inspect-call-command context)
    (debug-inspect-role
      context
      'scheme.debug-inspect-call
      'call))

  (define (debug-inspect-closure-command context)
    (debug-inspect-role
      context
      'scheme.debug-inspect-closure
      'closure))

  (define (debug-inspect-source-command context)
    (debug-inspect-role
      context
      'scheme.debug-inspect-source
      'source))

  (define (debug-expression-prompt
            debugger
            label
            history
            accept-command)
    (make-prompt-request
      label
      ""
      history
      #f
      'free
      #f
      accept-command
      #f
      (cons
        (debugger-session-origin debugger)
        (debugger-session-generation debugger))))

  (define (prompt-matches-debugger? result debugger)
    (let ([identity
            (and
              (prompt-result? result)
              (prompt-result-data result))])
      (and
        (pair? identity)
        (eq? (car identity)
             (debugger-session-origin debugger))
        (= (cdr identity)
           (debugger-session-generation debugger)))))

  (define (set-inspected-value! editor debugger source)
    (unless
      (memq
        'set-value
        (debugger-session-inspection-capabilities debugger))
      (editor-user-error
        'scheme.debug-set-value
        "The inspected reference is not assignable"))
    (guard
      (condition
        [else
         (editor-set-status-message!
           editor
           (string-append
             "Inspector assignment failed: "
             (condition-display-string condition)))])
      (let ([values
              (debugger-session-set-inspected-value!
                debugger
                source)])
        (editor-set-status-message!
          editor
          (string-append
            "Set inspected value to "
            (values->string values))))))

  (define (debug-set-value-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-set-value
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(string? argument)
         (set-inspected-value!
           editor
           debugger
           argument)]
        [(not argument)
         (unless
           (memq
             'set-value
             (debugger-session-inspection-capabilities debugger))
           (editor-user-error
             'scheme.debug-set-value
             "The inspected reference is not assignable"))
         (editor-open-prompt!
           editor
           (debug-expression-prompt
             debugger
             "Set inspected value: "
             'scheme-debug-set-value
             'scheme.debug-set-value-accept))]
        [else
         (assertion-violation
           'scheme.debug-set-value
           "replacement expression must be a string or #f"
           argument)])
      '()))

  (define (debug-set-value-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [source
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (when
        (and
          target
          source
          (positive? (string-length source))
          (prompt-matches-debugger?
            result
            (cadr target)))
        (set-inspected-value!
          editor
          (cadr target)
          source))
      '()))

  (define (apply-inspected!
            editor
            target
            source)
    (let* ([session (car target)]
           [debugger (cadr target)]
           [node
             (debugger-session-inspection-node debugger)])
      (unless node
        (editor-user-error
          'scheme.debug-apply
          "The debugger has no inspected object"))
      (if (eq? (inspector-node-type node) 'continuation)
          (begin
            (unless
              (and
                session
                (eq? (interaction-session-state session) 'failed))
              (editor-user-error
                'scheme.debug-apply
                "The inspected continuation is not attached to a failed evaluation"))
            (let ([transformer
                    (debugger-session-evaluate-procedure
                      debugger
                      source)]
                  [continuation
                    (inspector-node-value node)])
              (close-session-debugger! editor session)
              (interaction-session-resume! session)
              (list
                (make-command-effect
                  'scheme.resume-evaluation
                  (make-evaluation-resume-request
                    (interaction-session-id session)
                    (interaction-session-generation session)
                    'apply-continuation
                    (list transformer continuation))))))
          (guard
            (condition
              [else
               (editor-set-status-message!
                 editor
                 (string-append
                   "Inspector apply failed: "
                   (condition-display-string condition)))
               '()])
            (let ([values
                    (debugger-session-apply-inspected
                      debugger
                      source)])
              (editor-set-status-message!
                editor
                (string-append
                  "Inspector apply => "
                  (values->string values)))
              '())))))

  (define (debug-apply-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-apply
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(string? argument)
         (apply-inspected!
           editor
           target
           argument)]
        [(not argument)
         (unless
           (debugger-session-inspection-node debugger)
           (editor-user-error
             'scheme.debug-apply
             "The debugger has no inspected object"))
         (editor-open-prompt!
           editor
           (debug-expression-prompt
             debugger
             "Apply procedure to inspected object: "
             'scheme-debug-apply
             'scheme.debug-apply-accept))
         '()]
        [else
         (assertion-violation
           'scheme.debug-apply
           "procedure expression must be a string or #f"
           argument)])))

  (define (debug-apply-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [source
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (if
        (and
          target
          source
          (positive? (string-length source))
          (prompt-matches-debugger?
            result
            (cadr target)))
        (apply-inspected! editor target source)
        '())))

  (define (restart-evaluation!
            editor
            session
            source
            origin)
    (let ([suspended?
            (eq? (interaction-session-state session) 'suspended)])
      (comint-stash-current-input! editor session)
      (when suspended?
        (interaction-session-abort-suspension! session))
      (close-session-debugger! editor session)
      (comint-replace-input! editor session ";; retry")
      (comint-commit-input! editor session)
      (let ([evaluate-effect
              (make-command-effect
                'scheme.evaluate
                (interaction-session-begin!
                  session
                  source
                  origin))])
        (if suspended?
            (list
              (make-command-effect
                'scheme.abort-evaluation
                (interaction-session-id session))
              evaluate-effect)
            (list evaluate-effect)))))

  (define (debugger-action-context-live? context)
    (let ([editor
            (debugger-action-context-editor context)]
          [session
            (debugger-action-context-session context)]
          [debugger
            (debugger-action-context-debugger context)])
      (and
        (not (debugger-session-closed? debugger))
        (if session
            (eq?
              (interaction-session-debugger session)
              debugger)
            (eq? (editor-debugger editor) debugger)))))

  (define (require-action-execution-context
            who
            command-context
            command)
    (let ([execution
            (command-context-argument command-context)])
      (unless (debugger-action-context? execution)
        (assertion-violation
          who
          "expected a debugger action execution context"
          execution))
      (unless
        (eq?
          (command-context-editor command-context)
          (debugger-action-context-editor execution))
        (assertion-violation
          who
          "action context belongs to another editor"))
      (unless (debugger-action-context-live? execution)
        (editor-user-error
          who
          "The debugger action context is no longer active"))
      (let* ([debugger
               (debugger-action-context-debugger execution)]
             [action
               (debugger-action-context-action execution)]
             [current
               (and
                 action
                 (debugger-session-action
                   debugger
                   (debugger-action-id action)))])
        (unless
          (and
            current
            (eq? (debugger-action-command current)
                 command))
          (editor-user-error
            who
            "The debugger action is no longer available"))
        execution)))

  (define (invoke-debugger-action!
            editor
            context)
    (let ([action
            (debugger-action-context-action context)])
      (when
        (eq? (debugger-action-command action)
             'scheme.debug-action)
        (editor-user-error
          'scheme.debug-action
          "A debugger action cannot invoke the action selector"))
      (editor-execute-command!
        editor
        (debugger-action-command action)
        #f
        context)))

  (define (open-debugger-action-parameter!
            editor
            context)
    (let* ([action
             (debugger-action-context-action context)]
           [parameter
             (debugger-action-parameter action)]
           [initial
             (or
               (debugger-action-parameter-default-value
                 parameter
                 context)
               "")])
      (editor-open-prompt!
        editor
        (make-prompt-request
          (debugger-action-parameter-prompt parameter)
          initial
          (case
            (debugger-action-parameter-kind parameter)
            [(source) 'scheme-debugger-source]
            [else 'scheme-debugger-expression])
          #f
          'must-match
          (lambda (value)
            (debugger-action-parameter-valid?
              parameter
              context
              value))
          'scheme.debug-action-parameter-accept
          #f
          context))
      '()))

  (define (begin-debugger-action!
            editor
            session
            debugger
            action)
    (let ([context
            (make-action-context
              editor session debugger action #f)])
      (if
        (eq?
          (debugger-action-parameter-kind
            (debugger-action-parameter action))
          'none)
        (invoke-debugger-action!
          editor
          context)
        (open-debugger-action-parameter!
          editor
          context))))

  (define (begin-debugger-action-by-id!
            command-context
            who
            id)
    (let* ([target
             (require-debug-target
               who
               command-context)]
           [action
             (require-debugger-action
               who target id)])
      (begin-debugger-action!
        (command-context-editor command-context)
        (car target)
        (cadr target)
        action)))

  (define (begin-debugger-action-for-command!
            command-context
            who
            command)
    (let* ([target
             (require-debug-target
               who
               command-context)]
           [action
             (find
               (lambda (candidate)
                 (eq?
                   (debugger-action-command candidate)
                   command))
               (debugger-session-actions
                 (cadr target)))])
      (unless action
        (editor-user-error
          who
          "The debugger does not provide this action"))
      (begin-debugger-action!
        (command-context-editor command-context)
        (car target)
        (cadr target)
        action)))

  (define (debug-action-parameter-accept-command
            command-context)
    (let* ([result
             (command-context-argument command-context)]
           [saved
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [value
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))])
      (if
        (and
          (debugger-action-context? saved)
          value
          (debugger-action-context-live? saved))
        (let* ([debugger
                 (debugger-action-context-debugger saved)]
               [old-action
                 (debugger-action-context-action saved)]
               [action
                 (debugger-session-action
                   debugger
                   (debugger-action-id old-action))]
               [context
                 (and
                   action
                   (debugger-action-context-with-argument
                     (debugger-action-context-with-action
                       saved action)
                     value))])
          (if
            (and
              context
              (debugger-action-parameter-valid?
                (debugger-action-parameter action)
                context
                value))
            (invoke-debugger-action!
              (command-context-editor command-context)
              context)
            '()))
        '())))

  (define (debug-continue-command context)
    (if
      (not
        (debugger-action-context?
          (command-context-argument context)))
      (begin-debugger-action-by-id!
        context
        'scheme.debug-continue
        'continue)
      (let* ([execution
               (require-action-execution-context
                 'scheme.debug-continue
                 context
                 'scheme.debug-continue)]
             [editor
               (debugger-action-context-editor execution)]
             [session
               (debugger-action-context-session execution)])
      (unless
        (and
          session
          (eq? (interaction-session-state session) 'suspended))
        (editor-user-error
          'scheme.debug-continue
          "The debugger has no suspended evaluation"))
      (close-session-debugger! editor session)
      (interaction-session-resume! session)
      (list
        (make-command-effect
          'scheme.resume-evaluation
          (make-evaluation-resume-request
            (interaction-session-id session)
            (interaction-session-generation session)
            'continue
            '()))))))

  (define (debug-source-resume-command
            context
            who
            action-id
            command
            resume-kind)
    (if
      (not
        (debugger-action-context?
          (command-context-argument context)))
      (begin-debugger-action-by-id!
        context
        who
        action-id)
      (let* ([execution
               (require-action-execution-context
                 who
                 context
                 command)]
             [editor
               (debugger-action-context-editor execution)]
             [session
               (debugger-action-context-session execution)]
             [debugger
               (debugger-action-context-debugger execution)])
        (unless
          (and
            session
            (eq? (interaction-session-state session) 'suspended)
            (debugger-session-source-stop debugger))
          (editor-user-error
            who
            "The debugger is not stopped at a source expression"))
        (close-session-debugger! editor session)
        (interaction-session-resume! session)
        (list
          (make-command-effect
            'scheme.resume-evaluation
            (make-evaluation-resume-request
              (interaction-session-id session)
              (interaction-session-generation session)
              resume-kind
              '()))))))

  (define (debug-step-command context)
    (debug-source-resume-command
      context
      'scheme.debug-step
      'step
      'scheme.debug-step
      'step))

  (define (debug-next-command context)
    (debug-source-resume-command
      context
      'scheme.debug-next
      'next
      'scheme.debug-next
      'next))

  (define (debug-finish-command context)
    (debug-source-resume-command
      context
      'scheme.debug-finish
      'finish
      'scheme.debug-finish
      'finish))

  (define (debug-use-value-command context)
    (if
      (not
        (debugger-action-context?
          (command-context-argument context)))
      (begin-debugger-action-by-id!
        context
        'scheme.debug-use-value
        'use-value)
      (let* ([execution
               (require-action-execution-context
                 'scheme.debug-use-value
                 context
                 'scheme.debug-use-value)]
             [editor
               (debugger-action-context-editor execution)]
             [session
               (debugger-action-context-session execution)]
             [debugger
               (debugger-action-context-debugger execution)]
             [frame
               (debugger-action-context-selected-frame execution)]
             [source
               (debugger-action-context-argument execution)])
      (unless
        (and
          session
          frame
          (debugger-action-context-continuation execution))
        (editor-user-error
          'scheme.debug-use-value
          "The condition has no resumable continuation"))
        (guard
          (condition
            [else
             (editor-set-status-message!
               editor
               (string-append
                 "Replacement evaluation failed: "
                 (condition-display-string condition)))
             '()])
          (let ([values
                  (debugger-session-evaluate-in-frame
                    debugger
                    frame
                    source)])
            (close-session-debugger! editor session)
            (interaction-session-resume! session)
            (list
              (make-command-effect
                'scheme.resume-evaluation
                (make-evaluation-resume-request
                  (interaction-session-id session)
                  (interaction-session-generation session)
                  'use-values
                  values))))))))

  (define (debug-retry-command context)
    (if
      (not
        (debugger-action-context?
          (command-context-argument context)))
      (begin-debugger-action-by-id!
        context
        'scheme.debug-retry
        'retry)
      (let* ([execution
               (require-action-execution-context
                 'scheme.debug-retry
                 context
                 'scheme.debug-retry)]
             [editor
               (debugger-action-context-editor execution)]
             [session
               (debugger-action-context-session execution)]
           [result
             (and session
                  (interaction-session-last-result session))])
      (unless result
        (assertion-violation
          'scheme.debug-retry
          "active interaction has no failed evaluation"))
      (let ([request (evaluation-result-request result)])
        (restart-evaluation!
          editor
          session
          (evaluation-request-source request)
          (evaluation-request-origin request))))))

  (define (debug-edit-and-retry-command context)
    (if
      (not
        (debugger-action-context?
          (command-context-argument context)))
      (begin-debugger-action-by-id!
        context
        'scheme.debug-edit-and-retry
        'edit-and-retry)
      (let* ([execution
               (require-action-execution-context
                 'scheme.debug-edit-and-retry
                 context
                 'scheme.debug-edit-and-retry)]
             [editor
               (debugger-action-context-editor execution)]
             [session
               (debugger-action-context-session execution)]
             [source
               (debugger-action-context-argument execution)]
           [result
             (and session
                  (interaction-session-last-result session))])
      (unless result
        (editor-user-error
          'scheme.debug-edit-and-retry
          "The debugger is not attached to an evaluation"))
      (restart-evaluation!
        editor
        session
        source
        (evaluation-request-origin
          (evaluation-result-request result))))))

  (define (debug-action-choice-source actions)
    (let ([items
            (map
              (lambda (action)
                (let ([id
                        (symbol->string
                          (debugger-action-id action))])
                  (make-completion-item
                    (debugger-action-id action)
                    'scheme-debugger
                    id
                    id
                    id
                    (debugger-action-kind action)
                    (debugger-action-description action)
                    #f
                    id
                    #f
                    #t
                    #f
                    action
                    #f
                    #f
                    (if
                      (debugger-action-default? action)
                      1
                      0))))
              actions)])
      (make-choice-source
        'scheme-debug-action
        '((styles . (fzf))
          (preselect . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (action)
              (string=?
                value
                (symbol->string
                  (debugger-action-id action))))
            actions))
        (lambda (generation) #f))))

  (define (debug-action-command context)
    (let* ([target
             (require-debug-target
               'scheme.debug-action
               context)]
           [debugger (cadr target)]
           [actions (debugger-session-actions debugger)]
           [default
             (debugger-actions-default actions)]
           [argument (command-context-argument context)])
      (cond
        [(symbol? argument)
         (let ([action
                 (debugger-session-action
                   debugger
                   argument)])
           (unless action
             (editor-user-error
               'scheme.debug-action
               (string-append
                 "The debugger does not provide the "
                 (symbol->string argument)
                 " action")))
           (begin-debugger-action!
             (command-context-editor context)
             (car target)
             debugger
             action))]
        [(not argument)
         (editor-open-prompt!
           (command-context-editor context)
           (make-completing-prompt-request
             "Debugger action: "
             ""
             'scheme-debug-action
             (and
               default
               (symbol->string
                 (debugger-action-id default)))
             'must-match
             (debug-action-choice-source actions)
             'scheme.debug-action-accept
             #f
             (make-action-context
               (command-context-editor context)
               (car target)
               debugger
               #f
               #f)))
         '()]
        [else
         (assertion-violation
           'scheme.debug-action
           "action id must be a symbol or #f"
           argument)])))

  (define (debug-exit-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-exit
               context)])
      (remove-debugger-buffer! editor (cadr target))
      (editor-set-status-message!
        editor
        "Debugger exited; saved condition retained")
      '()))

  (define (debug-discard-command context)
    (if
      (not
        (debugger-action-context?
          (command-context-argument context)))
      (begin-debugger-action-for-command!
        context
        'scheme.debug-discard
        'scheme.debug-discard)
      (let* ([execution
               (require-action-execution-context
                 'scheme.debug-discard
                 context
                 'scheme.debug-discard)]
             [editor
               (debugger-action-context-editor execution)]
             [session
               (debugger-action-context-session execution)]
             [debugger
               (debugger-action-context-debugger execution)])
      (let* ([suspended?
              (and
                session
                (eq? (interaction-session-state session)
                     'suspended))]
             [evaluation?
               (and
                 session
                 (memq
                   (interaction-session-state session)
                   '(failed suspended)))])
        (discard-debugger! editor session debugger)
        (when session
          (if suspended?
              (begin
                (interaction-session-abort-suspension! session)
                (comint-append-output!
                  editor
                  session
                  "Interrupted\n"))
              (interaction-session-dismiss-failure! session)))
        (editor-set-status-message! editor #f)
        (if evaluation?
            (list
              (make-command-effect
                'scheme.abort-evaluation
                (interaction-session-id session)))
            '())))))

  (define (debug-action-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [candidate
             (and
               (prompt-result? result)
               (prompt-result-candidate result))]
           [selected
             (and
               candidate
               (completion-item-provider-data candidate))]
           [saved
             (and
               (prompt-result? result)
               (prompt-result-data result))])
      (if
        (and
          (debugger-action-context? saved)
          (debugger-action-context-live? saved)
          (debugger-action? selected)
          (eq?
            editor
            (debugger-action-context-editor saved)))
        (let ([action
                (debugger-session-action
                  (debugger-action-context-debugger saved)
                  (debugger-action-id selected))])
          (if action
              (begin-debugger-action!
                editor
                (debugger-action-context-session saved)
                (debugger-action-context-debugger saved)
                action)
              '()))
        '())))

  (define (register-debugger-command!
            editor
            name
            procedure
            documentation)
    (editor-register-command!
      editor
      (make-interactive-context-command
        name
        procedure
        documentation)))

  (define (install-debugger-commands! editor)
    (for-each
      (lambda (entry)
        (register-debugger-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)))
      (list
        (list
          'scheme.debug-open
          debug-open-command
          "Open the debugger for the failed Scheme evaluation.")
        (list
          'scheme.debug-continue
          debug-continue-command
          "Continue a suspended Scheme evaluation.")
        (list
          'scheme.debug-step
          debug-step-command
          "Step into the next instrumented Scheme source expression.")
        (list
          'scheme.debug-next
          debug-next-command
          "Step over to the next Scheme source expression in this frame.")
        (list
          'scheme.debug-finish
          debug-finish-command
          "Continue until the current Scheme source frame returns.")
        (list
          'scheme.debug-use-value
          debug-use-value-command
          "Resume a failed continuation with replacement values.")
        (list
          'scheme.debug-next-frame
          debug-next-frame-command
          "Select the next Scheme debugger frame.")
        (list
          'scheme.debug-previous-frame
          debug-previous-frame-command
          "Select the previous Scheme debugger frame.")
        (list
          'scheme.debug-eval-frame
          debug-eval-frame-command
          "Evaluate an expression in the selected debugger frame.")
        (list
          'scheme.debug-inspect-ref
          debug-inspect-ref-command
          "Inspect a child of the last debugger evaluation result.")
        (list
          'scheme.debug-inspect-local
          debug-inspect-local-command
          "Inspect a local value in the selected debugger frame.")
        (list
          'scheme.debug-inspect-condition
          debug-inspect-condition-command
          "Inspect the original Scheme condition object.")
        (list
          'scheme.debug-inspect-continuation
          debug-inspect-continuation-command
          "Inspect the saved raise continuation.")
        (list
          'scheme.debug-inspect-up
          debug-inspect-up-command
          "Return to the parent debugger inspection object.")
        (list
          'scheme.debug-inspect-top
          debug-inspect-top-command
          "Return to the root debugger inspection object.")
        (list
          'scheme.debug-inspect-next-page
          debug-inspect-next-page-command
          "Show the next page of Inspector children.")
        (list
          'scheme.debug-inspect-previous-page
          debug-inspect-previous-page-command
          "Show the previous page of Inspector children.")
        (list
          'scheme.debug-inspect-print
          debug-inspect-print-command
          "Pretty-print the inspected object.")
        (list
          'scheme.debug-inspect-write
          debug-inspect-write-command
          "Write the inspected object.")
        (list
          'scheme.debug-inspect-find
          debug-inspect-find-command
          "Find an object reachable from the inspected object.")
        (list
          'scheme.debug-inspect-find-next
          debug-inspect-find-next-command
          "Find the next object matching the active Inspector search.")
        (list
          'scheme.debug-inspect-code
          debug-inspect-code-command
          "Inspect the selected continuation's procedure code.")
        (list
          'scheme.debug-inspect-call
          debug-inspect-call-command
          "Inspect the selected continuation's pending call.")
        (list
          'scheme.debug-inspect-closure
          debug-inspect-closure-command
          "Inspect the selected continuation's closure.")
        (list
          'scheme.debug-inspect-source
          debug-inspect-source-command
          "Inspect the selected procedure or continuation source.")
        (list
          'scheme.debug-set-value
          debug-set-value-command
          "Set the inspected assignable reference.")
        (list
          'scheme.debug-apply
          debug-apply-command
          "Apply a procedure to the inspected object.")
        (list
          'scheme.debug-visit-source
          debug-visit-source-command
          "Visit the source location of the selected debugger frame.")
        (list
          'scheme.debug-retry
          debug-retry-command
          "Retry the failed evaluation in the active interaction.")
        (list
          'scheme.debug-edit-and-retry
          debug-edit-and-retry-command
          "Edit and retry the failed evaluation.")
        (list
          'scheme.debug-action
          debug-action-command
          "Select an action provided by the active debugger.")
        (list
          'scheme.debug-exit
          debug-exit-command
          "Leave the debugger while retaining the saved condition.")
        (list
          'scheme.debug-discard
          debug-discard-command
          "Discard the saved condition and its continuation.")))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-eval-frame-accept
        debug-eval-frame-accept-command
        "Apply input from the debugger evaluation prompt."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-inspect-ref-accept
        debug-inspect-ref-accept-command
        "Apply a child index from the debugger inspector prompt."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-inspect-local-accept
        debug-inspect-local-accept-command
        "Apply a local index from the debugger inspector prompt."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-inspect-find-accept
        debug-inspect-find-accept-command
        "Apply an Inspector search predicate from minibuffer input."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-action-accept
        debug-action-accept-command
        "Apply the debugger action selected by the minibuffer."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-action-parameter-accept
        debug-action-parameter-accept-command
        "Apply a validated debugger action parameter."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-set-value-accept
        debug-set-value-accept-command
        "Set an inspected assignable reference from minibuffer input."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-apply-accept
        debug-apply-accept-command
        "Apply a procedure from minibuffer input to the inspected object."))
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'debugger-mode
        'fundamental-mode
        #f
        'interface
        'debugger-mode-map
        '((track-modified? . #f)
          (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind!
            keymap
            (list
              (make-key-stroke
                'character
                (char->integer (car entry))
                0))
            (cdr entry)))
        '((#\n . scheme.debug-next-frame)
          (#\p . scheme.debug-previous-frame)
          (#\e . scheme.debug-eval-frame)
          (#\c . scheme.debug-continue)
          (#\s . scheme.debug-step)
          (#\o . scheme.debug-next)
          (#\f . scheme.debug-finish)
          (#\i . scheme.debug-inspect-condition)
          (#\k . scheme.debug-inspect-continuation)
          (#\= . scheme.debug-use-value)
          (#\l . scheme.debug-inspect-local)
          (#\d . scheme.debug-inspect-ref)
          (#\u . scheme.debug-inspect-up)
          (#\t . scheme.debug-inspect-top)
          (#\[ . scheme.debug-inspect-previous-page)
          (#\] . scheme.debug-inspect-next-page)
          (#\P . scheme.debug-inspect-print)
          (#\W . scheme.debug-inspect-write)
          (#\/ . scheme.debug-inspect-find)
          (#\N . scheme.debug-inspect-find-next)
          (#\! . scheme.debug-set-value)
          (#\a . scheme.debug-apply)
          (#\v . scheme.debug-visit-source)
          (#\r . scheme.debug-action)
          (#\x . scheme.debug-exit)
          (#\q . scheme.debug-discard)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'debugger-mode-map
        keymap))))
