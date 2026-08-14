(library (soda packages minibuffer)
  (export make-minibuffer-service!
          minibuffer-service?
          minibuffer-service-current
          minibuffer-service-sessions
          minibuffer-session?
          minibuffer-session-interaction
          minibuffer-session-buffer-id
          minibuffer-session-view-id
          minibuffer-session-origin-view-id
          minibuffer-session-completion
          prompt-snapshot?
          prompt-snapshot-session-id prompt-snapshot-request
          prompt-snapshot-input prompt-snapshot-input-revision
          prompt-snapshot-point prompt-snapshot-selection
          prompt-snapshot-origin-context prompt-snapshot-completion-generation
          prompt-snapshot-presentation
          minibuffer-session-snapshot
          minibuffer-service-add-hook!
          minibuffer-service-refresh-completion!
          minibuffer-service-select-completion!
          minibuffer-service-history-entries
          minibuffer-input-context
          minibuffer-service-submit!
          minibuffer-service-cancel!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel change)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel viewport)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host dispatch)
          (soda host feedback)
          (soda host input)
          (soda host input-event)
          (soda host buffer)
          (soda host package)
          (soda host view)
          (soda host value)
          (soda packages interaction)
          (soda packages completion)
          (soda packages input-history)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda view decoration)
          (soda view display)
          (soda view list-viewport)
          (soda view plugin))

  ;; Prompt buffers are ordinary transient buffers.  The service owns their
  ;; session stack and requested row count; the Surface owns placement.
  (define-record-type
    (minibuffer-session %make-minibuffer-session minibuffer-session?)
    (fields interaction buffer-id view-id origin-view-id surface-id height
            (mutable completion-buffer-id minibuffer-session-completion-buffer-id
                     minibuffer-session-completion-buffer-id-set!)
            (mutable completion-view-id minibuffer-session-completion-view-id
                     minibuffer-session-completion-view-id-set!)
            (mutable completion-viewport minibuffer-session-completion-viewport
                     minibuffer-session-completion-viewport-set!)
            (mutable history-index minibuffer-session-history-index
                     minibuffer-session-history-index-set!)
            (mutable history-draft minibuffer-session-history-draft
                     minibuffer-session-history-draft-set!)
            (mutable submitted-value minibuffer-session-submitted-value
                     minibuffer-session-submitted-value-set!)
            (mutable completion minibuffer-session-completion minibuffer-session-completion-set!)))
  (define-record-type minibuffer-hook
    (fields owner procedure))
  (define-record-type
    (minibuffer-service %make-minibuffer-service minibuffer-service?)
    (fields host interactions owner keymap mode completion-mode histories
            (mutable sessions minibuffer-service-sessions minibuffer-service-sessions-set!)
            (mutable setup-hooks minibuffer-service-setup-hooks minibuffer-service-setup-hooks-set!)
            (mutable exit-hooks minibuffer-service-exit-hooks minibuffer-service-exit-hooks-set!)
            (mutable registration minibuffer-service-registration minibuffer-service-registration-set!)))

  ;; Prompt chrome is virtual View content, never part of the transient
  ;; Document.  Commands consequently receive exactly the text the user
  ;; entered, while DisplayMap still places the caret after the prompt.
  (define minibuffer-view-compartment
    (make-compartment 'minibuffer-view 'view))

  (define (minibuffer-input-decorations value)
    (let* ([view (car value)]
           [snapshot
            (buffer-state-document (buffer-state (view-buffer view)))]
           [length (snapshot-byte-size snapshot)])
      (if (zero? length)
          (make-decoration-set '())
          (make-decoration-set
            (list
              (make-range-value
                0 length (make-face-decoration 'minibuffer.input 0)))))))

  (define (make-minibuffer-prompt-plugin prompt)
    (make-view-plugin
      'minibuffer-prompt
      (lambda (view) (cons view prompt))
      #f #f minibuffer-input-decorations #f
      (lambda (value)
        (lambda (stream)
          (display-stream-insert
            stream 0
            (list
              (make-display-text (cdr value) 0 0 'minibuffer.prompt
                                 (list 'minibuffer 'prompt))))))
      (lambda (update)
        (or (view-update-damaged? update 'document)
            (view-update-damaged? update 'configuration)))))

  (define (minibuffer-configuration service base request)
    (configuration-reconfigure
      (configuration-reconfigure
        base buffer-major-mode-compartment
        (make-buffer-mode-extension (minibuffer-service-mode service)))
      minibuffer-view-compartment
      (make-facet-provider
        view-plugins-facet
        (list (make-minibuffer-prompt-plugin
                (interaction-request-display-prompt request))))))

  (define (session-for service interaction)
    (let loop ([sessions (minibuffer-service-sessions service)])
      (and (pair? sessions)
           (if (eq? interaction (minibuffer-session-interaction (car sessions)))
               (car sessions) (loop (cdr sessions))))))

  (define minibuffer-history-limit 100)

  (define (session-history-key session)
    (interaction-request-history-key
      (interaction-session-request
        (minibuffer-session-interaction session))))

  (define (history-for service key create?)
    (and key
         (or (hashtable-ref (minibuffer-service-histories service) key #f)
             (and create?
                  (let ([history (make-input-history minibuffer-history-limit)])
                    (hashtable-set!
                      (minibuffer-service-histories service) key history)
                    history)))))

  (define (minibuffer-service-history-entries service key)
    (unless (and (minibuffer-service? service) (symbol? key))
      (assertion-violation 'minibuffer-service-history-entries
                           "expected a MinibufferService and history key"
                           service key))
    (let ([history (history-for service key #f)])
      (if history (input-history-entries history) '())))

  (define (minibuffer-service-current service)
    (and (minibuffer-service? service)
         (let ([sessions (minibuffer-service-sessions service)])
           (and (pair? sessions) (car sessions)))))
  (define (session-input service session)
    (let ([buffer (package-host-buffer-ref (minibuffer-service-host service)
                                           (minibuffer-session-buffer-id session) #f)])
      (and buffer (snapshot-string (buffer-state-document (buffer-state buffer))))))

  ;; Buffer selections are UTF-8 byte offsets; completion source boundaries
  ;; are string character indexes.  Convert at the prompt boundary so every
  ;; source shares one convention, including paths with non-ASCII names.
  (define (input-byte-offset->character-index input offset)
    (let loop ([index 0] [bytes 0])
      (cond
        [(= bytes offset) index]
        [(= index (string-length input)) index]
        [else
         (loop (+ index 1)
               (+ bytes
                  (bytevector-length
                    (string->utf8
                      (string (string-ref input index))))))])))

  (define (minibuffer-session-snapshot service session)
    (unless (and (minibuffer-service? service) (minibuffer-session? session))
      (assertion-violation 'minibuffer-session-snapshot
                           "expected a minibuffer service and session" service session))
    (let* ([host (minibuffer-service-host service)]
           [buffer (package-host-buffer-ref host (minibuffer-session-buffer-id session) #f)]
           [view (package-host-view-ref host (minibuffer-session-view-id session) #f)]
           [selection (and view (view-state-selection (view-state view)))]
           [range (and selection (selection-primary-range selection))]
           [controller (minibuffer-session-completion session)]
           [surface-size (package-host-surface-size
                           host (minibuffer-session-surface-id session))]
           [input (if buffer (snapshot-string (buffer-state-document (buffer-state buffer))) "")]
           [point (if range
                      (input-byte-offset->character-index input
                                                          (selection-range-head range))
                      0)])
      (make-prompt-snapshot
        (interaction-session-invocation-id (minibuffer-session-interaction session))
        (interaction-session-request (minibuffer-session-interaction session))
        input
        (if buffer (buffer-state-generation (buffer-state buffer)) 0)
        point
        selection
        (interaction-session-context (minibuffer-session-interaction session))
        (if controller (completion-controller-generation controller) 0)
        (list (cons 'surface-id (minibuffer-session-surface-id session))
              (cons 'surface-size surface-size)
              (cons 'interaction-height (minibuffer-session-height session))))))
  (define (notify-hooks! hooks snapshot)
    (for-each
      (lambda (hook)
        (guard (ignored [else #f])
          ((minibuffer-hook-procedure hook) snapshot)))
      hooks))
  (define (minibuffer-service-add-hook! service phase owner procedure)
    (unless (and (minibuffer-service? service) (memq phase '(setup exit))
                 (owner? owner) (procedure? procedure))
      (assertion-violation 'minibuffer-service-add-hook!
                           "expected a minibuffer service, phase, owner, and procedure"
                           service phase owner procedure))
    (owner-assert-active 'minibuffer-service-add-hook! owner)
    (let* ([hook (make-minibuffer-hook owner procedure)]
           [accessor (if (eq? phase 'setup)
                         minibuffer-service-setup-hooks
                         minibuffer-service-exit-hooks)]
           [setter (if (eq? phase 'setup)
                       minibuffer-service-setup-hooks-set!
                       minibuffer-service-exit-hooks-set!)])
      (setter service (append (accessor service) (list hook)))
      (make-registration
        owner
        (lambda ()
          (setter service
                  (filter (lambda (item) (not (eq? item hook)))
                          (accessor service)))))))
  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))
  ;; A minibuffer contributes local overrides to the ordinary Buffer input
  ;; composition.  The application supplies its basic-editing fallback while
  ;; request-specific answers retain transient precedence.  Application-global
  ;; bindings are intentionally outside this contract.
  (define minibuffer-input-context
    (case-lambda
      [(service active view)
       (minibuffer-input-context service active view '())]
      [(service active view fallback-layers)
       (let ([session (minibuffer-service-current service)])
         (and session (= (minibuffer-session-view-id session) (view-id view))
              (let* ([request
                      (interaction-session-request
                        (minibuffer-session-interaction session))]
                     [request-keymap (interaction-request-keymap request)]
                     [local-layers
                      (append
                        (if request-keymap
                            (list (make-input-layer
                                    'transient request-keymap #f 'ignore))
                            '())
                        (list
                          (make-input-layer
                            'major (minibuffer-service-keymap service) #f 'accept)))])
                (buffer-input-context
                  active view (append local-layers fallback-layers)))))]))
  (define (open! service interaction)
    (let* ([host (minibuffer-service-host service)]
           [context (interaction-session-context interaction)]
           [origin (package-host-view-ref host (command-context-view-id context) #f)]
           [size (package-host-surface-size host (command-context-surface-id context))])
      (and origin size
           (let ([document #f] [buffer #f] [view #f]
                 [placed? #f] [committed? #f])
             (dynamic-wind
               (lambda () #f)
               (lambda ()
                 (let* ([request (interaction-session-request interaction)]
                        [configuration
                         (minibuffer-configuration service
                           (view-state-configuration (view-state origin)) request)])
                   (set! document
                         (make-document
                           (or (interaction-request-initial-value request) "")))
                   (set! buffer
                         (package-host-create-buffer!
                           host (minibuffer-service-owner service)
                           " *minibuffer*" document configuration))
                   ;; The Buffer owns the Document after successful creation.
                   (set! document #f)
                   (set! view
                         (package-host-create-view!
                           host (minibuffer-service-owner service)
                           buffer configuration))
                   ;; Initial prompt contents are ready for continuation.
                   ;; Establish point before placement so every frontend sees
                   ;; the same first Frame.
                   (let ([end
                          (snapshot-byte-size
                            (buffer-state-document (buffer-state buffer)))])
                     (when (positive? end)
                       (let ([state (view-state view)])
                         (package-host-dispatch-view!
                           host
                           (make-view-transaction-spec
                             (view-id view) (view-state-generation state)
                             (make-selection
                               (list (make-selection-range end end)))
                             (view-state-viewport state)
                             #f '() '()
                             (make-scroll-request
                               'reveal-point
                               (command-context-surface-id context)
                               #f (view-id view)))))))
                   (set! placed?
                         (and
                           (package-host-push-interaction-view!
                             host (command-context-surface-id context)
                             (view-id view) 1)
                           #t))
                   (and placed?
                        (let ([session
                               (%make-minibuffer-session
                                 interaction (buffer-id buffer) (view-id view)
                                 (view-id origin)
                                 (command-context-surface-id context)
                                 1 #f #f
                                 (make-list-viewport
                                   0 completion-window-height)
                                 #f
                                 (or (interaction-request-initial-value request) "")
                                 #f #f)])
                          (minibuffer-service-sessions-set!
                            service
                            (cons session (minibuffer-service-sessions service)))
                          (set! committed? #t)
                          (notify-hooks!
                            (minibuffer-service-setup-hooks service)
                            (minibuffer-session-snapshot service session))
                          session))))
               (lambda ()
                 (unless committed?
                   (when placed?
                     (package-host-remove-interaction-view!
                       host (command-context-surface-id context) (view-id view)))
                   (when buffer
                     (package-host-close-buffer! host (buffer-id buffer)))
                   (when document (document-close! document)))))))))

  (define (fail-open! service interaction)
    (let ([context (interaction-session-context interaction)])
      (guard (ignored [else #f])
        (package-host-publish-feedback!
          (minibuffer-service-host service)
          (command-context-surface-id context)
          (make-user-feedback "Unable to open minibuffer" 'error)))
      (interaction-service-cancel!
        (minibuffer-service-interactions service))))

  (define completion-window-height 6)

  (define (candidate-line candidate selected?)
    (string-append
      (if selected? "> " "  ")
      (completion-candidate-label candidate)
      (let ([annotation (completion-candidate-annotation candidate)])
        (if annotation (string-append "  " annotation) ""))
      "\n"))

  (define (completion-text session controller)
    (let* ([candidates (completion-controller-candidates controller)]
           [range
            (list-viewport-visible-range
              (minibuffer-session-completion-viewport session)
              (length candidates))]
           [selected (completion-controller-selected-index controller)])
      (let loop ([remaining candidates] [index 0] [result ""])
        (cond
          [(or (null? remaining) (= index (cdr range))) result]
          [(< index (car range)) (loop (cdr remaining) (+ index 1) result)]
          [else
           (loop (cdr remaining) (+ index 1)
                 (string-append
                   result
                   (candidate-line (car remaining)
                                   (and selected (= selected index)))))]))))

  (define (close-completion-presentation! service session)
    (let ([view-id (minibuffer-session-completion-view-id session)]
          [buffer-id (minibuffer-session-completion-buffer-id session)]
          [host (minibuffer-service-host service)])
      (when view-id
        (package-host-remove-interaction-view!
          host (minibuffer-session-surface-id session) view-id))
      (when buffer-id (package-host-close-buffer! host buffer-id))
      (minibuffer-session-completion-view-id-set! session #f)
      (minibuffer-session-completion-buffer-id-set! session #f)))

  (define (completion-configuration service)
    (make-configuration
      (make-buffer-modes-extension
        (minibuffer-service-completion-mode service) '())))

  (define (ensure-completion-presentation! service session controller)
    (let ([candidates (completion-controller-candidates controller)])
      (if (null? candidates)
          (begin
            (minibuffer-session-completion-viewport-set!
              session (make-list-viewport 0 completion-window-height))
            (close-completion-presentation! service session))
          (let* ([viewport
                  (list-viewport-reveal
                    (minibuffer-session-completion-viewport session)
                    (length candidates)
                    (completion-controller-selected-index controller))]
                 [_ (minibuffer-session-completion-viewport-set! session viewport)]
                 [host (minibuffer-service-host service)]
                 [configuration (completion-configuration service)]
                 [buffer
                  (or (and (minibuffer-session-completion-buffer-id session)
                           (package-host-buffer-ref
                             host
                             (minibuffer-session-completion-buffer-id session)
                             #f))
                      (package-host-create-buffer!
                        host (minibuffer-service-owner service)
                        " *Completions*" (make-document "") configuration))]
                 [view
                  (or (and (minibuffer-session-completion-view-id session)
                           (package-host-view-ref
                             host (minibuffer-session-completion-view-id session) #f))
                      (let ([created
                             (package-host-create-view!
                               host (minibuffer-service-owner service)
                               buffer configuration)])
                        (if (package-host-add-interaction-companion-view!
                              host (minibuffer-session-surface-id session)
                              (minibuffer-session-view-id session)
                              (view-id created) completion-window-height)
                            created
                            #f)))])
            (if (not view)
                (begin
                  (package-host-close-buffer! host (buffer-id buffer))
                  #f)
                (let* ([state (buffer-state buffer)]
                       [old-size
                        (snapshot-byte-size (buffer-state-document state))]
                       [text (completion-text session controller)]
                       [published
                        (package-host-dispatch!
                          host
                          (make-transaction-spec
                            (buffer-id buffer) (view-id view)
                            (buffer-state-generation state)
                            (make-change-set
                              old-size
                              (list
                                (make-text-change
                                  0 old-size (string->utf8 text))))
                            #f '() '()))])
                  (minibuffer-session-completion-buffer-id-set!
                    session (buffer-id buffer))
                  (minibuffer-session-completion-view-id-set!
                    session (view-id view))
                  (let ([selected
                         (completion-controller-selected-index controller)])
                    (when selected
                      (let ([current (package-host-view-ref host (view-id view) #f)])
                        (when current
                          (package-host-dispatch-view!
                            host
                            (make-view-transaction-spec
                              (view-id current)
                              (view-state-generation (view-state current))
                              #f
                              (make-viewport
                                (max 0 (- selected (- completion-window-height 1)))
                                0)
                              #f '() '() #f))))))
                  published))))))

  (define (close! service interaction outcome)
    (let ([session (session-for service interaction)])
      (when session
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let* ([snapshot (minibuffer-session-snapshot service session)]
                   [controller (minibuffer-session-completion session)])
              (when (and (eq? outcome 'accepted)
                         (session-history-key session)
                         (string? (minibuffer-session-submitted-value session)))
                (input-history-add!
                  (history-for service (session-history-key session) #t)
                  (minibuffer-session-submitted-value session)))
              (when controller
                (if (eq? outcome 'accepted)
                    (completion-controller-accept! controller snapshot)
                    (completion-controller-restore! controller)))
              (notify-hooks! (minibuffer-service-exit-hooks service) snapshot)))
          (lambda ()
            ;; Package callbacks are isolated from Host resource ownership.
            ;; Even a failed completion finalizer must retire this exact
            ;; prompt View and Buffer without disturbing another session.
            (close-completion-presentation! service session)
            (minibuffer-service-sessions-set!
              service (filter (lambda (item) (not (eq? item session)))
                              (minibuffer-service-sessions service)))
            (package-host-remove-interaction-view!
              (minibuffer-service-host service)
              (minibuffer-session-surface-id session)
              (minibuffer-session-view-id session))
            (package-host-close-buffer! (minibuffer-service-host service)
                                        (minibuffer-session-buffer-id session)))))))
  (define (invalid-input-feedback context)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        #f #f
        (input-stack-with-feedback
          (view-state-input-state state) "Input does not match an available choice")
        '() '() #f)))

  (define (minibuffer-service-submit-value! service context use-candidate?)
       (let ([session (minibuffer-service-current service)])
         (and session
           (let* ([buffer
                   (package-host-buffer-ref
                     (minibuffer-service-host service)
                     (minibuffer-session-buffer-id session) #f)]
                  [raw (and buffer (snapshot-string (buffer-state-document (buffer-state buffer))))]
                  [snapshot (minibuffer-session-snapshot service session)]
                  [controller
                   (let ([current (minibuffer-session-completion session)])
                     (if (and current
                              (not (completion-controller-context-current?
                                     current snapshot)))
                         (minibuffer-service-refresh-completion! service)
                         current))]
                  [candidate
                   (and use-candidate? controller
                        (completion-controller-selected controller))]
                  [candidate-application
                   (and candidate
                        (call-with-values
                          (lambda () (completion-candidate-apply candidate raw))
                          cons))]
                  [request (interaction-session-request (minibuffer-session-interaction session))]
                  [policy (interaction-request-selection-policy
                            request)]
                  [default-action (interaction-request-default-action request)]
                  [value
                   (cond
                     [candidate (car candidate-application)]
                     [(eq? policy 'choice)
                      (and default-action (string=? raw "")
                           (choice-action-id default-action))]
                     [else raw])])
             (cond
               [(and candidate
                     (eq? (completion-candidate-accept-behavior candidate)
                          'continue))
                (and context
                     (replace-prompt-input-at
                       context (car candidate-application)
                       (cdr candidate-application) '()))]
               [(and value
                      (or (eq? policy 'free)
                          (and (eq? policy 'choice) (symbol? value))
                          candidate
                          (let ([validator (interaction-request-validator request)])
                            (or (and validator (validator value snapshot))
                                (and controller
                                     (completion-controller-valid-input?
                                       controller value snapshot))))))
                 (begin
                   (minibuffer-session-submitted-value-set! session value)
                   (interaction-service-submit!
                     (minibuffer-service-interactions service) value))]
               [else (and context (invalid-input-feedback context))])))))

  (define minibuffer-service-submit!
    (case-lambda
      [(service) (minibuffer-service-submit! service #f)]
      [(service context)
       (minibuffer-service-submit-value! service context #t)]))
  (define (minibuffer-service-refresh-completion! service)
    (let ([session (minibuffer-service-current service)])
      (and session
           (let* ([request (interaction-session-request (minibuffer-session-interaction session))]
                  [source (interaction-request-completion-source request)])
             (and (completion-source? source)
                  (let ([controller (or (minibuffer-session-completion session)
                                        (make-completion-controller
                                          source (interaction-request-selection-policy request)))])
                    (minibuffer-session-completion-set! session controller)
                    (completion-controller-refresh!
                      controller (minibuffer-session-snapshot service session))
                    (ensure-completion-presentation! service session controller)
                    controller))))))

  (define (replace-prompt-input-at context value point annotations)
    (let* ([state (command-context-buffer-state context)]
           [length (snapshot-byte-size (buffer-state-document state))]
           [bytes (string->utf8 value)]
           [point-bytes
            (bytevector-length (string->utf8 (substring value 0 point)))]
           [selection (make-selection
                        (list (make-selection-range point-bytes point-bytes)))])
      (make-transaction-spec
        (command-context-buffer-id context) (command-context-view-id context)
        (buffer-state-generation state)
        (make-change-set length (list (make-text-change 0 length bytes)))
        selection '() annotations)))

  (define replace-prompt-input
    (case-lambda
      [(context value) (replace-prompt-input context value '())]
      [(context value annotations)
       (replace-prompt-input-at
         context value (string-length value) annotations)]))

  (define (minibuffer-service-move-history service context delta)
    (let* ([session (minibuffer-service-current service)]
           [key (and session (session-history-key session))]
           [history (and key (history-for service key #f))]
           [entries (and history (input-history-entries history))]
           [current (and session (minibuffer-session-history-index session))])
      (if (or (not session) (null? (or entries '())))
          (command-handled)
          (let* ([last (- (length entries) 1)]
                 [target
                  (cond
                    [(not current) (and (positive? delta) 0)]
                    [else (+ current delta)])])
            (cond
              [(not target) (command-handled)]
              [(negative? target)
               (minibuffer-session-history-index-set! session #f)
               (replace-prompt-input
                 context (minibuffer-session-history-draft session)
                 (list (make-annotation 'minibuffer.history #t)))]
              [else
               (when (not current)
                 (minibuffer-session-history-draft-set!
                   session (or (session-input service session) "")))
               (let ([index (min last target)])
                 (minibuffer-session-history-index-set! session index)
                 (replace-prompt-input
                   context (list-ref entries index)
                   (list (make-annotation 'minibuffer.history #t))))])))))

  ;; Completion application is a normal prompt-buffer transaction.  Sources
  ;; continue to own candidate generation; this service only chooses one
  ;; explicit candidate, a sole candidate, or an unambiguous shared prefix.
  (define (minibuffer-service-complete! service context)
    (let ([session (minibuffer-service-current service)])
      (if (or (not session)
              (not (= (command-context-buffer-id context)
                      (minibuffer-session-buffer-id session))))
          (command-handled)
          (let* ([controller (minibuffer-service-refresh-completion! service)]
                 [snapshot (minibuffer-session-snapshot service session)]
                 [application
                  (and controller
                       (completion-controller-application controller snapshot))])
            (if application
                (replace-prompt-input-at
                  context (car application) (cdr application) '())
                (command-handled))))))
  (define (minibuffer-service-select-completion! service index)
    (let ([session (minibuffer-service-current service)])
      (and session (minibuffer-session-completion session)
           (let* ([snapshot (minibuffer-session-snapshot service session)]
                  [current (minibuffer-session-completion session)]
                  [controller
                   (if (completion-controller-context-current? current snapshot)
                       current
                       (minibuffer-service-refresh-completion! service))])
             (completion-controller-select!
               controller index (minibuffer-session-snapshot service session))
             (ensure-completion-presentation! service session controller)
             controller))))

  (define (minibuffer-service-move-completion! service delta)
    (let* ([session (minibuffer-service-current service)]
           [controller
            (and session
                 (let ([current (minibuffer-session-completion session)])
                   (if (and current
                            (completion-controller-context-current?
                              current (minibuffer-session-snapshot service session)))
                       current
                       (minibuffer-service-refresh-completion! service))))]
           [candidates
            (and controller (completion-controller-candidates controller))])
      (and (pair? candidates)
           (let* ([current (completion-controller-selected-index controller)]
                  [last (- (length candidates) 1)]
                  [policy (completion-controller-selection-policy controller)]
                  [target
                   (cond
                     [(not current)
                      (cond
                        [(positive? delta) 0]
                        [(eq? policy 'free) -1]
                        [else last])]
                     [else
                      (max (if (eq? policy 'free) -1 0)
                           (min last (+ current delta)))])])
             (minibuffer-service-select-completion! service target)))))
  (define (minibuffer-service-cancel! service)
    (and (minibuffer-service-current service)
         (interaction-service-cancel! (minibuffer-service-interactions service))))
  (define (make-minibuffer-service! host interactions owner)
    (unless (and (package-host? host) (interaction-service? interactions) (owner? owner))
      (assertion-violation 'make-minibuffer-service! "invalid minibuffer dependencies"))
    (let ([keymap (make-keymap 'minibuffer)])
      (keymap-bind! keymap (list (make-key-stroke 'enter #f 0)) 'minibuffer.accept)
      (keymap-bind! keymap (list (control-stroke #\j)) 'minibuffer.accept)
      (keymap-bind!
        keymap (list (make-key-stroke 'enter #f 2))
        'minibuffer.accept-input)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\j) 2))
        'minibuffer.accept-input)
      (keymap-bind! keymap (list (make-key-stroke 'tab #f 0)) 'minibuffer.complete)
      (keymap-bind!
        keymap (list (make-key-stroke 'tab #f 1))
        'minibuffer.previous-completion)
      (keymap-bind! keymap (list (make-key-stroke 'down #f 0)) 'minibuffer.next-completion)
      (keymap-bind! keymap (list (control-stroke #\n)) 'minibuffer.next-completion)
      (keymap-bind! keymap (list (make-key-stroke 'up #f 0)) 'minibuffer.previous-completion)
      (keymap-bind! keymap (list (control-stroke #\p)) 'minibuffer.previous-completion)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\p) 2))
        'minibuffer.previous-history)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\n) 2))
        'minibuffer.next-history)
      (keymap-bind!
        keymap (list (make-key-stroke 'up #f 2))
        'minibuffer.previous-history)
      (keymap-bind!
        keymap (list (make-key-stroke 'down #f 2))
        'minibuffer.next-history)
      (keymap-bind! keymap (list (control-stroke #\g)) 'minibuffer.cancel)
      (keymap-bind! keymap (list (make-key-stroke 'escape #f 0)) 'minibuffer.cancel)
      (let* ([mode
              (make-mode-spec
                'minibuffer-mode 'major "Minibuffer" #f
                (list
                  (make-buffer-syntax-profile-extension
                    (make-plain-text-syntax-profile)))
                '(editing motion selection kill yank viewport interface minibuffer)
                "Mini")]
             [completion-mode
              (make-mode-spec
                'completion-list-mode 'major "Completions" #f
                (list
                  (make-buffer-syntax-profile-extension
                    (make-plain-text-syntax-profile)))
                '(interface completion-list) "Comp")]
             [service
              (%make-minibuffer-service
                host interactions owner keymap mode completion-mode
                (make-eq-hashtable)
                '() '() '() #f)])
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.accept (context)
        (documentation "Accept the current minibuffer input.")
        (class 'minibuffer)
        (undo 'ignore)
        (or (minibuffer-service-submit! service context)
            (command-handled)))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.complete (context)
        (documentation "Apply the current prompt completion without accepting the prompt.")
        (class 'minibuffer)
        (undo 'ignore)
        (minibuffer-service-complete! service context))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.accept-input (context)
        (documentation "Accept the minibuffer input without using the selected completion.")
        (class 'minibuffer)
        (undo 'ignore)
        (or (minibuffer-service-submit-value! service context #f)
            (command-handled)))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.next-completion (context)
        (documentation "Select the next minibuffer completion candidate.")
        (class 'minibuffer)
        (undo 'ignore)
        (minibuffer-service-move-completion! service 1)
        (command-handled))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.previous-completion (context)
        (documentation "Select the previous minibuffer completion candidate.")
        (class 'minibuffer)
        (undo 'ignore)
        (minibuffer-service-move-completion! service -1)
        (command-handled))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.previous-history (context)
        (documentation "Replace minibuffer input with an older history entry.")
        (class 'minibuffer)
        (undo 'ignore)
        (minibuffer-service-move-history service context 1))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.next-history (context)
        (documentation "Replace minibuffer input with a newer history entry or the saved draft.")
        (class 'minibuffer)
        (undo 'ignore)
        (minibuffer-service-move-history service context -1))
      (define-command
        (package-host-command-runtime host) owner 'minibuffer.cancel (context)
        (documentation "Cancel the current minibuffer input.")
        (class 'minibuffer)
        (undo 'ignore)
        (minibuffer-service-cancel! service)
        (command-handled))
      (minibuffer-service-registration-set!
        service
        (interaction-service-add-listener!
          interactions owner
          (lambda (kind interaction)
            (cond [(eq? kind 'opened)
                   (guard (ignored [else (fail-open! service interaction)])
                     (or (open! service interaction)
                         (fail-open! service interaction)))]
                  [(memq kind '(accepted cancelled))
                   (close! service interaction kind)]))))
      (package-host-add-update-listener!
        host owner
        (lambda (update)
          (let ([session (minibuffer-service-current service)])
            (when (and session
                       (= (editor-update-buffer-id update)
                          (minibuffer-session-buffer-id session)))
              (let ([document-changed?
                     (not (change-set-empty? (editor-update-changes update)))]
                    [selection-changed?
                     (exists
                       (lambda (view-update)
                         (and (= (view-state-update-view-id view-update)
                                 (minibuffer-session-view-id session))
                              (not
                                (equal?
                                  (view-state-selection
                                    (view-state-update-old-state view-update))
                                  (view-state-selection
                                    (view-state-update-new-state view-update))))))
                       (editor-update-views update))])
                (when document-changed?
                  (unless (exists
                            (lambda (annotation)
                              (eq? (annotation-key annotation) 'minibuffer.history))
                            (editor-update-annotations update))
                    (minibuffer-session-history-index-set! session #f)
                    (minibuffer-session-history-draft-set!
                      session
                      (snapshot-string
                        (buffer-state-document
                          (editor-update-new-buffer-state update))))))
                (when (and (or document-changed? selection-changed?)
                           (minibuffer-session-completion session))
                  (minibuffer-service-refresh-completion! service)))))))
      service)))
)
