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
          (soda host command-runtime)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host internal state)
          (soda host runtime)
          (soda host value))

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

  (define (run-command-loop-tests!)
    (test-prefix-argument)
    (test-command-policy-override)
    (test-remapped-identity)
    (test-transient-input-exits-after-command)
    (test-runtime-state-record-and-repeat)
    (test-undo-amalgamation))
)
