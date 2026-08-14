(library (soda test command-loop)
  (export run-command-loop-tests!)
  (import (rnrs)
          (soda bootstrap)
          (soda kernel document)
          (soda kernel state)
          (soda host internal buffer)
          (soda host internal surface)
          (soda host internal view)
          (soda host command)
          (soda host command-argument)
          (soda host command-runtime)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host internal state)
          (soda host render)
          (soda host runtime)
          (soda host value)
          (soda packages prefix-argument)
          (soda view frame))

  (define (check condition message . irritants)
    (unless condition (apply error 'command-loop-tests message irritants)))

  (define (test-prefix-argument)
    (let ([absent (make-prefix-argument)]
          [universal (make-prefix-argument 'universal)]
          [negative (make-prefix-argument -3)]
          [state
           (prefix-argument-state-append-digit
             (prefix-argument-state-toggle-negative
               (prefix-argument-state-append-universal
                 (prefix-argument-state-append-universal
                   (make-prefix-argument-state))))
             3)])
      (check (and (not (prefix-argument-present? absent))
                  (= (prefix-argument-numeric-value absent) 1)
                  (= (prefix-argument-numeric-value universal) 4)
                  (= (prefix-argument-numeric-value negative) -3)
                  (= (prefix-argument-state-universal-count state) 2)
                  (= (prefix-argument-state-sign state) -1)
                  (= (prefix-argument-numeric-value
                       (prefix-argument-state-value state)) -3)
                  (= (prefix-argument-state-universal-count
                       (prefix-argument->state
                         (prefix-argument-state-value state))) 2))
             "PrefixArgument did not preserve raw and numeric semantics")))

  (define (test-command-policy-override)
    (let* ([policy (make-command-policy 'declared #t 'amalgamate #t 'repeat-map)]
           [inherited
            (command-loop-transition-resolve
              (make-command-loop-transition) policy 'effective)]
           [overridden
            (command-loop-transition-resolve
              (make-command-loop-transition #f #f 'ignore #f #f)
              policy 'effective)])
      (check (and (eq? (command-loop-transition-semantic-command inherited)
                       'declared)
                  (command-loop-transition-repeatable? inherited)
                  (command-loop-transition-preserve-prefix? inherited)
                  (eq? (command-loop-transition-transient-state inherited)
                       'repeat-map)
                  (eq? (command-loop-transition-semantic-command overridden)
                       'effective)
                  (not (command-loop-transition-repeatable? overridden))
                  (eq? (command-loop-transition-undo-policy overridden) 'ignore)
                  (not (command-loop-transition-preserve-prefix? overridden))
                  (not (command-loop-transition-transient-state overridden)))
             "CommandLoopTransition did not override CommandPolicy")))

  (define (test-remapped-identity)
    (let* ([map (make-keymap 'remap-test)]
           [stroke (make-key-stroke 'character (char->integer #\a) 4)]
           [_binding (keymap-bind! map (list stroke) 'command.requested)]
           [_remap (keymap-remap! map 'command.requested 'command.effective)]
           [state (make-input-state 'remap-state (list map) 'accept)]
           [context
            (make-input-context #f #f
                                (list (make-input-layer 'major map #f 'accept))
                                (make-input-stack state))]
           [result
            (input-dispatch
              context
              (make-key-event 'character (char->integer #\a) #f #f 4
                              'press (make-bytevector 0)))])
      (check (and (eq? (input-disposition-value result) 'command.effective)
                  (eq? (input-disposition-requested-command result)
                       'command.requested))
             "input remapping discarded requested command identity")))

  (define (test-feedback-input-lifetime)
    (let* ([map (make-keymap 'feedback-lifetime)]
           [_binding
            (keymap-bind!
              map (list (make-key-stroke 'character (char->integer #\a) 4))
              'command.action)]
           [context
            (make-input-context
              #f #f (list (make-input-layer 'major map #f 'accept))
              (make-input-stack (make-input-state 'feedback-lifetime (list map) 'accept)))]
           [command
            (input-dispatch
              context
              (make-key-event 'character (char->integer #\a) #f #f 4
                              'press (make-bytevector 0)))]
           [prefix (input-consume)]
           [text (input-dispatch context (make-text-input-event 'text (string->utf8 "x")))]
           [undefined
            (input-dispatch
              context
              (make-key-event 'f1 #f #f #f 0 'press (make-bytevector 0)))])
      (check (and (input-disposition-clears-feedback? command)
                  (input-disposition-clears-feedback? prefix)
                  (input-disposition-clears-feedback? text)
                  (not (input-disposition-clears-feedback? (input-pass)))
                  (not (input-disposition-clears-feedback? undefined)))
             "InputDisposition did not classify echo feedback lifetime")))

  (define (test-transient-input-exits-after-command)
    (let* ([durable-map (make-keymap 'durable)]
           [transient-map (make-keymap 'transient)]
           [_binding
            (keymap-bind! transient-map
                          (list (make-key-stroke
                                  'character (char->integer #\z) 0))
                          'command.repeat)]
           [durable (make-input-state 'durable (list durable-map) 'accept)]
           [transient (make-input-state 'transient (list transient-map) 'ignore)]
           [stack (input-stack-push (make-input-stack durable) transient)]
           [context
            (make-input-context
              #f #f
              (list (make-input-layer 'transient transient-map #f 'ignore))
              stack)]
           [result
            (input-dispatch
              context
              (make-key-event 'character (char->integer #\z) #f #f 0
                              'press (make-bytevector 0)))]
           [next (input-disposition-input-state result)])
      (check (and (eq? (input-disposition-kind result) 'command)
                  (= (length (input-stack-sessions next)) 1)
                  (eq? (input-session-state (car (input-stack-sessions next)))
                       durable)
                  (not (input-session-transient?
                         (car (input-stack-sessions next)))))
             "command dispatch retained a one-shot transient InputState")))

  (define (test-standard-context-argument-reader)
    (let* ([event
            (make-key-event 'character (char->integer #\3) #f #f 2
                            'press (make-bytevector 0))]
           [context
            (make-command-context
              #f 1 #f #f #f #f #f event '() (make-prefix-argument -4)
              #f 'test #f)]
           [digit-result
            ((interactive-reader-resolver command-event-digit-reader)
             context '())]
           [prefix-result
            ((interactive-reader-resolver command-numeric-prefix-reader)
             context (interactive-ready-values digit-result))]
           [codepoint-result
            ((interactive-reader-resolver command-key-codepoint-reader)
             context '())])
      (check (and (interactive-ready? digit-result)
                  (equal? (interactive-ready-values digit-result) '(3))
                  (interactive-ready? prefix-result)
                  (equal? (interactive-ready-values prefix-result) '(-4))
                  (equal? (interactive-ready-values codepoint-result)
                          (list (char->integer #\3))))
             "standard context readers did not resolve typed command arguments")))

  (define (test-prefix-argument-transient-map)
    (let* ([host (make-host-state)]
           [runtime (host-state-command-runtime host)]
           [owner (make-owner 'prefix-argument-test)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([state (make-prefix-argument-commands! runtime owner)]
                 [map (car (input-state-keymaps state))]
                 [definition
                  (command-runtime-command-definition runtime 'argument.digit)]
                 [policy (command-definition-policy definition)])
            (check
              (and (eq? (keymap-lookup
                          map
                          (list (make-key-stroke
                                  'character (char->integer #\7) 0))
                          #f)
                        'argument.digit)
                   (eq? (command-policy-transient-state policy) state)
                   (= (length
                        (interactive-plan-readers
                          (command-definition-interaction-spec definition)))
                      2))
              "prefix argument commands did not declare a reentrant input map")))
        (lambda ()
          (owner-close! owner)
          (host-state-close! host)))))

  (define (test-runtime-state-record-and-repeat)
    (let* ([host (make-host-state)]
           [runtime (host-state-command-runtime host)]
           [owner (make-owner 'command-loop-test)]
           [prefix (make-prefix-argument '(universal universal) 16)]
           [context
            (make-command-context
              #f 9 #f #f #f #f #f #f '() prefix #f 'test #f)]
           [repeat-map (make-keymap 'test-repeat-map)]
           [repeat-state (make-input-state 'test-repeat (list repeat-map) 'ignore)]
           [calls '()]
           [records '()])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (define-command
            runtime owner 'command.effective (context value)
            (repeatable #t)
            (undo 'amalgamate)
            (documentation "Exercise named command declaration clauses.")
            (semantic 'command.semantic)
            (preserve-prefix #t)
            (class 'test)
            (scope 'global)
            (set! calls (cons (list value (command-context-source context)) calls))
            (command-handled))
          (command-runtime-add-hook!
            runtime 'execution-record owner 'capture-record
            (lambda (record) (set! records (cons record records))))
          (command-runtime-set-repeat-state! runtime owner repeat-state)
          (command-runtime-enqueue!
            runtime
            (make-command-invoke-message
              'command.effective context (list 'argument) #f 'command.requested))
          (host-state-run! host)
          (let* ([state (command-runtime-loop-state runtime context)]
                 [record (command-loop-state-last-record state)]
                 [identity (command-execution-record-identity record)]
                 [definition
                  (command-runtime-command-definition runtime 'command.effective)]
                 [policy (command-definition-policy definition)]
                 [transition (command-execution-record-transition record)])
            (check (and (eq? (command-identity-requested identity) 'command.requested)
                        (eq? (command-identity-effective identity) 'command.effective)
                        (eq? (command-identity-semantic identity) 'command.semantic)
                        (= (prefix-argument-numeric-value
                             (command-execution-record-prefix-argument record)) 16)
                        (eq? record (command-loop-state-repeat-record state))
                        (eq? record (car (command-runtime-execution-history runtime)))
                        (eq? record (car records))
                        (eq? (command-policy-semantic-command policy) 'command.semantic)
                        (command-policy-repeatable? policy)
                        (eq? (command-policy-undo-policy policy) 'amalgamate)
                        (command-policy-preserve-prefix? policy)
                        (eq? (command-loop-transition-semantic-command transition)
                             'command.semantic)
                        (command-loop-transition-repeatable? transition)
                        (eq? (command-loop-transition-undo-policy transition)
                             'amalgamate))
                   "runtime did not resolve command policy into the execution record"))
          (check (and (eq? (command-runtime-take-transient-state! runtime 9)
                           repeat-state)
                      (not (command-runtime-take-transient-state! runtime 9)))
                 "repeat transient state was not consumed exactly once")
          (command-runtime-repeat-last! runtime context)
          (host-state-run! host)
          (check (and (equal? calls '((argument repeat) (argument test)))
                      (eq? (command-runtime-take-transient-state! runtime 9)
                           repeat-state))
                 "repeat did not replay and reinstall its transient map" calls)
          (command-runtime-forget-surface! runtime 9)
          (check (not (command-loop-state-last
                        (command-runtime-loop-state runtime context)))
                 "retired Surface retained command-loop state"))
        (lambda ()
          (owner-close! owner)
          (host-state-close! host)))))

  (define (application-context application)
    (let* ([state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [active (surface-active-context surface (host-state-views state))]
           [view (view-service-ref (host-state-views state)
                                   (active-context-view-id active))]
           [buffer (view-buffer view)])
      (make-command-context
        #f (active-context-surface-id active) (active-context-window-id active)
        (view-id view) (buffer-id buffer) (buffer-state buffer) (view-state view)
        #f '() (make-prefix-argument) #f 'test #f)))

  (define (test-prefix-argument-render-feedback)
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (command-runtime-start-interactive!
            (host-state-command-runtime state)
            'argument.universal (application-context application))
          (let* ([frame
                  (surface-render-frame
                    (render-surface surface (host-state-views state)))]
                 [row (- (frame-height frame) 1)])
            (check
              (and (string=? (frame-cell-grapheme (frame-cell-at frame row 0)) "A")
                   (string=? (frame-cell-grapheme (frame-cell-at frame row 1)) "r")
                   (string=? (frame-cell-grapheme (frame-cell-at frame row 2)) "g"))
              "pending prefix argument was not visible in Surface chrome")))
        (lambda () (soda-application-close! application)))))

  (define (test-undo-amalgamation)
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (command-runtime-start!
            runtime 'fundamental.insert-text (application-context application)
            (list (string->utf8 "a")))
          (command-runtime-start!
            runtime 'fundamental.insert-text (application-context application)
            (list (string->utf8 "b")))
          (command-runtime-start!
            runtime 'history.undo (application-context application))
          (check (string=?
                   (snapshot-string
                     (buffer-state-document
                       (buffer-state (soda-application-buffer application))))
                   "")
                 "amalgamated edit commands did not form one undo unit"))
        (lambda () (soda-application-close! application)))))

  ;; Runtime lanes make input latency a scheduling contract: an input burst is
  ;; FIFO, preempts background work, and still yields to the priority command
  ;; and cycle boundary emitted by its current action.
  (define (test-runtime-input-lane)
    (let ([runtime (make-runtime)] [events '()])
      (runtime-enqueue! runtime 'background-a)
      (runtime-enqueue! runtime 'background-b)
      (runtime-enqueue-input! runtime 'input-a)
      (runtime-enqueue-input! runtime 'input-b)
      (runtime-drain!
        runtime
        (lambda (event)
          (set! events (append events (list event)))
          (when (eq? event 'input-a)
            ;; This is the order used by frontend input: the boundary is
            ;; scheduled first and its command then takes immediate priority.
            (runtime-enqueue-priority! runtime 'input-boundary)
            (runtime-enqueue-priority! runtime 'input-command))))
      (check (equal? events
                     '(input-a input-command input-boundary input-b
                               background-a background-b))
             "Runtime did not preserve input priority and action boundaries"
             events)))

  (define (test-invalid-command-result-is-atomic)
    (let* ([host (make-host-state)]
           [runtime (host-state-command-runtime host)]
           [owner (make-owner 'invalid-command-result-test)]
           [context
            (make-command-context
              #f #f #f #f #f #f #f #f '() (make-prefix-argument) #f 'test #f)]
           [effect-applied? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (command-runtime-register-command!
            runtime
            (make-command-definition
              'test.invalid-result
              (lambda (ignored)
                (list (make-command-effect 'test.invalid-result-effect 'first) 'invalid))
              owner))
          (command-runtime-register-effect-handler!
            runtime 'test.invalid-result-effect owner 'observe-invalid-result
            (lambda (ignored invocation effect) (set! effect-applied? #t)))
          (let ([invocation
                 (command-runtime-start! runtime 'test.invalid-result context)])
            (check (and (eq? (command-invocation-phase invocation) 'cancelled)
                        (command-invocation-condition invocation)
                        (not effect-applied?))
                   "invalid command result applied a leading outcome before failing")))
        (lambda ()
          (owner-close! owner)
          (host-state-close! host)))))

  (define (run-command-loop-tests!)
    (test-prefix-argument)
    (test-command-policy-override)
    (test-remapped-identity)
    (test-feedback-input-lifetime)
    (test-transient-input-exits-after-command)
    (test-standard-context-argument-reader)
    (test-prefix-argument-transient-map)
    (test-runtime-state-record-and-repeat)
    (test-prefix-argument-render-feedback)
    (test-undo-amalgamation)
    (test-runtime-input-lane)
    (test-invalid-command-result-is-atomic))
)
