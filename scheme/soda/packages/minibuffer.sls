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
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host buffer)
          (soda host package)
          (soda host view)
          (soda host value)
          (soda packages interaction)
          (soda packages completion)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda view decoration)
          (soda view display)
          (soda view plugin))

  ;; Prompt buffers are ordinary transient buffers.  The service owns only
  ;; their session stack and its interaction overlay placement.
  (define-record-type
    (minibuffer-session %make-minibuffer-session minibuffer-session?)
    (fields interaction buffer-id view-id origin-view-id surface-id rectangle
            (mutable completion minibuffer-session-completion minibuffer-session-completion-set!)))
  (define-record-type minibuffer-hook
    (fields owner procedure))
  (define-record-type
    (minibuffer-service %make-minibuffer-service minibuffer-service?)
    (fields host interactions owner keymap mode
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
              (cons 'overlay-rectangle (minibuffer-session-rectangle session))))))
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
      (when (and origin size)
        (let* ([request (interaction-session-request interaction)]
               [configuration
                (minibuffer-configuration service
                  (view-state-configuration (view-state origin)) request)]
               [document (make-document (or (interaction-request-initial-value request) ""))]
               [buffer (package-host-create-buffer! host (minibuffer-service-owner service)
                                                    " *minibuffer*" document configuration)]
               [view (package-host-create-view! host (minibuffer-service-owner service)
                                                buffer configuration)]
               [rectangle (list (max 0 (- (cdr size) 1)) 0 (car size) 1)])
          (if (package-host-push-interaction-view!
                host (command-context-surface-id context) (view-id view) rectangle)
              (let ([session
                     (%make-minibuffer-session interaction (buffer-id buffer) (view-id view)
                                                (view-id origin) (command-context-surface-id context)
                                                rectangle #f)])
                (minibuffer-service-sessions-set!
                  service (cons session (minibuffer-service-sessions service)))
                (notify-hooks! (minibuffer-service-setup-hooks service)
                               (minibuffer-session-snapshot service session)))
              (package-host-close-buffer! host (buffer-id buffer)))))))
  (define (close! service interaction)
    (let ([session (session-for service interaction)])
      (when session
        (let ([controller (minibuffer-session-completion session)])
          (when controller
            (completion-controller-restore! controller
                                            (minibuffer-session-snapshot service session))))
        (notify-hooks! (minibuffer-service-exit-hooks service)
                       (minibuffer-session-snapshot service session))
        (minibuffer-service-sessions-set!
          service (filter (lambda (item) (not (eq? item session)))
                          (minibuffer-service-sessions service)))
        (package-host-remove-interaction-view!
          (minibuffer-service-host service)
          (minibuffer-session-surface-id session)
          (minibuffer-session-view-id session))
        (package-host-close-buffer! (minibuffer-service-host service)
                                    (minibuffer-session-buffer-id session)))))
  (define (invalid-input-feedback context)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        #f #f
        (input-stack-with-feedback
          (view-state-input-state state) "Input does not match an available choice")
        '() '() #f)))

  (define minibuffer-service-submit!
    (case-lambda
      [(service) (minibuffer-service-submit! service #f)]
      [(service context)
       (let ([session (minibuffer-service-current service)])
         (and session
           (let* ([buffer
                   (package-host-buffer-ref
                     (minibuffer-service-host service)
                     (minibuffer-session-buffer-id session) #f)]
                  [raw (and buffer (snapshot-string (buffer-state-document (buffer-state buffer))))]
                  [controller (minibuffer-session-completion session)]
                  [candidate (and controller (completion-controller-selected controller))]
                  [snapshot (minibuffer-session-snapshot service session)]
                  [request (interaction-session-request (minibuffer-session-interaction session))]
                  [policy (interaction-request-selection-policy
                            request)]
                  [default-action (interaction-request-default-action request)]
                  [value
                   (cond
                     [candidate (completion-candidate-insert-text candidate)]
                     [(eq? policy 'choice)
                      (and default-action (string=? raw "")
                           (choice-action-id default-action))]
                     [else raw])])
             (if (and value
                      (or (eq? policy 'free)
                          (and (eq? policy 'choice) (symbol? value))
                          candidate
                          (let ([validator (interaction-request-validator request)])
                            (or (and validator (validator value snapshot))
                                (and controller
                                     (completion-controller-valid-input?
                                       controller value snapshot))))))
                 (begin
                   (when controller
                     (completion-controller-accept! controller snapshot))
                   (interaction-service-submit!
                     (minibuffer-service-interactions service) value))
                 (and context (invalid-input-feedback context))))))]))
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
                    (completion-controller-refresh! controller
                                                    (minibuffer-session-snapshot service session))))))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (common-prefix strings)
    (if (null? strings)
        ""
        (let* ([first (car strings)]
               [limit (string-length first)])
          (let loop ([index 0])
            (if (or (= index limit)
                    (exists
                      (lambda (value)
                        (or (= index (string-length value))
                            (not (char=? (string-ref first index)
                                         (string-ref value index)))))
                      (cdr strings)))
                (substring first 0 index)
                (loop (+ index 1)))))))

  (define (replace-prompt-input context value)
    (let* ([state (command-context-buffer-state context)]
           [length (snapshot-byte-size (buffer-state-document state))]
           [bytes (string->utf8 value)]
           [selection (make-selection
                        (list (make-selection-range
                                (bytevector-length bytes) (bytevector-length bytes))))])
      (make-transaction-spec
        (command-context-buffer-id context) (command-context-view-id context)
        (buffer-state-generation state)
        (make-change-set length (list (make-text-change 0 length bytes)))
        selection '() '())))

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
                 [input (prompt-snapshot-input snapshot)]
                 [candidates (and controller
                                  (completion-controller-candidates controller))]
                 [selected (and controller
                                (completion-controller-selected controller))]
                 [value
                  (cond
                    [selected (completion-candidate-insert-text selected)]
                    [(and (pair? candidates) (null? (cdr candidates)))
                     (completion-candidate-insert-text (car candidates))]
                    [else
                     (let ([prefix
                            (common-prefix
                              (map completion-candidate-insert-text
                                   (or candidates '())))])
                       (and (> (string-length prefix) (string-length input))
                            (string-prefix? input prefix)
                            prefix))])])
            (if value
                (replace-prompt-input context value)
                (command-handled))))))
  (define (minibuffer-service-select-completion! service index)
    (let ([session (minibuffer-service-current service)])
      (and session (minibuffer-session-completion session)
           (completion-controller-select! (minibuffer-session-completion session) index
                                          (minibuffer-session-snapshot service session)))))
  (define (minibuffer-service-cancel! service)
    (and (minibuffer-service-current service)
         (interaction-service-cancel! (minibuffer-service-interactions service))))
  (define (make-minibuffer-service! host interactions owner)
    (unless (and (package-host? host) (interaction-service? interactions) (owner? owner))
      (assertion-violation 'make-minibuffer-service! "invalid minibuffer dependencies"))
    (let ([keymap (make-keymap 'minibuffer)])
      (keymap-bind! keymap (list (make-key-stroke 'enter #f 0)) 'minibuffer.accept)
      (keymap-bind! keymap (list (control-stroke #\j)) 'minibuffer.accept)
      (keymap-bind! keymap (list (make-key-stroke 'tab #f 0)) 'minibuffer.complete)
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
             [service
              (%make-minibuffer-service
                host interactions owner keymap mode '() '() '() #f)])
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
            (cond [(eq? kind 'opened) (open! service interaction)]
                  [(memq kind '(accepted cancelled)) (close! service interaction)]))))
      service)))
)
