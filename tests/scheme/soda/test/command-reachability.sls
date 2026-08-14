(library (soda test command-reachability)
  (export run-command-reachability-tests!)
  (import (rnrs)
          (soda bootstrap)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda packages command-presentation)
          (soda packages interaction)
          (soda packages minibuffer))

  ;; This matrix names the contexts whose keymaps have deliberately different
  ;; compositions.  Each case checks both the command projection used by M-x,
  ;; Help, describe and where-is and the resolver used for an actual key.
  (define (active-command-context application)
    (let* ([state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [active (surface-active-context surface (host-state-views state))]
           [view (view-service-ref (host-state-views state)
                                   (active-context-view-id active))]
           [buffer (view-buffer view)]
           [input-context
            (soda-application-resolve-input-context application active view)])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state view)
        #f '() #f active 'command-reachability-test #f
        (input-layers-snapshot (input-context-layers input-context)))))

  (define (command-access runtime context name)
    (command-context-command-access runtime context '() name))

  (define (access-has-key? access name)
    (and access
         (member name
                 (map key-sequence-name
                      (command-access-key-sequences access)))))

  (define (resolve-command application event)
    (let* ([state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [active (surface-active-context surface (host-state-views state))]
           [view (view-service-ref (host-state-views state)
                                   (active-context-view-id active))])
      (input-dispatch
        (soda-application-resolve-input-context application active view) event)))

  (define (character-event character modifiers)
    (make-key-event 'character (char->integer character) #f #f modifiers
                    'press (make-bytevector 0)))

  (define (assert-command-dispatches! application event name description)
    (let ([result (resolve-command application event)])
      (unless (and (eq? (input-disposition-kind result) 'command)
                   (eq? (input-disposition-value result) name))
        (error 'command-reachability-tests description result))))

  (define (run-fundamental-context-test!)
    (let* ([application (make-soda-application)]
           [runtime (host-state-command-runtime (soda-application-state application))]
           [context (active-command-context application)])
      (unless (and (access-has-key?
                     (command-access runtime context 'message.show-position) "C-c")
                   (not (command-access runtime context 'buffer.quit)))
        (error 'command-reachability-tests
               "fundamental context projected special-buffer commands"))
      (assert-command-dispatches!
        application (character-event #\c 4) 'message.show-position
        "fundamental key resolver diverged from the command projection")
      (soda-application-close! application)))

  (define (run-generated-context-test!)
    (let* ([application (make-soda-application)]
           [runtime (host-state-command-runtime (soda-application-state application))])
      (command-runtime-start! runtime 'help.show (active-command-context application))
      (let ([context (active-command-context application)])
        (unless (and (access-has-key? (command-access runtime context 'buffer.quit) "q")
                     (not (command-access runtime context 'fundamental.newline)))
          (error 'command-reachability-tests
                 "generated Buffer context projected ordinary editing commands"))
        (assert-command-dispatches!
          application (character-event #\q 0) 'buffer.quit
          "generated Buffer key resolver diverged from the command projection"))
      (soda-application-close! application)))

  (define (run-semantic-item-context-test!)
    (let* ([application (make-soda-application)]
           [runtime (host-state-command-runtime (soda-application-state application))])
      (command-runtime-start! runtime 'buffer.list (active-command-context application))
      (let ([context (active-command-context application)])
        (unless (and (access-has-key?
                       (command-access runtime context 'buffer.next-item) "C-n")
                     (access-has-key?
                       (command-access runtime context 'buffer.activate-item) "<enter>")
                     (not (command-access runtime context 'fundamental.newline)))
          (error 'command-reachability-tests
                 "semantic item context lost its generated Buffer projection"))
        (assert-command-dispatches!
          application (character-event #\n 4) 'buffer.next-item
          "semantic item key resolver diverged from the command projection"))
      (soda-application-close! application)))

  (define (run-minibuffer-and-interaction-context-test!)
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [interactions (soda-application-interaction application)]
           [minibuffer (soda-application-minibuffer application)])
      (command-runtime-start-interactive!
        runtime 'command.execute-extended (active-command-context application))
      (let* ([session (interaction-service-current interactions)]
             [origin (and session (interaction-session-context session))]
             [minibuffer-context (active-command-context application)])
        (unless (and session
                     ;; M-x owns the origin context, where unbound user
                     ;; commands are correctly offered as extended commands.
                     (command-access runtime origin 'buffer.bury)
                     (null? (command-access-key-sequences
                              (command-access runtime origin 'buffer.bury)))
                     ;; The active minibuffer itself has no M-x endpoint; its
                     ;; projection includes only commands reached by its map.
                     (not (command-access runtime minibuffer-context 'buffer.bury))
                     (access-has-key?
                       (command-access runtime minibuffer-context 'keyboard.quit) "C-g"))
          (error 'command-reachability-tests
                 "interaction origin and active minibuffer projections diverged"))
        (assert-command-dispatches!
          application (character-event #\g 4) 'keyboard.quit
          "minibuffer key resolver diverged from the command projection"))
      ;; The assertion only resolves C-g; retire the suspended interaction
      ;; through its ordinary service lifecycle before closing the application.
      (minibuffer-service-cancel! minibuffer)
      (host-state-run! state)
      (soda-application-close! application)))

  (define (run-command-reachability-tests!)
    (run-fundamental-context-test!)
    (run-generated-context-test!)
    (run-semantic-item-context-test!)
    (run-minibuffer-and-interaction-context-test!)))
