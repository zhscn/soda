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
          [negative (make-prefix-argument -3)])
      (check (and (not (prefix-argument-present? absent))
                  (= (prefix-argument-numeric-value absent) 1)
                  (= (prefix-argument-numeric-value universal) 4)
                  (= (prefix-argument-numeric-value negative) -3))
             "PrefixArgument did not preserve raw and numeric semantics")))

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

  (define (test-runtime-state-record-and-repeat)
    (let* ([host (make-host-state)]
           [runtime (host-state-command-runtime host)]
           [owner (make-owner 'command-loop-test)]
           [prefix (make-prefix-argument '(universal universal) 16)]
           [context
            (make-command-context
              #f 9 #f #f #f #f #f #f '() prefix #f 'test #f)]
           [calls '()]
           [records '()])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (command-runtime-register-command!
            runtime
            (make-command-definition
              'command.effective
              (lambda (context value)
                (set! calls (cons (list value (command-context-source context)) calls))
                (command-result-with-transition
                  (command-handled)
                  (make-command-loop-transition
                    'command.semantic #t 'amalgamate)))
              owner))
          (command-runtime-add-hook!
            runtime 'execution-record owner 'capture-record
            (lambda (record) (set! records (cons record records))))
          (command-runtime-enqueue!
            runtime
            (make-command-invoke-message
              'command.effective context (list 'argument) #f 'command.requested))
          (host-state-run! host)
          (let* ([state (command-runtime-loop-state runtime context)]
                 [record (command-loop-state-last-record state)]
                 [identity (command-execution-record-identity record)])
            (check (and (eq? (command-identity-requested identity) 'command.requested)
                        (eq? (command-identity-effective identity) 'command.effective)
                        (eq? (command-identity-semantic identity) 'command.semantic)
                        (= (prefix-argument-numeric-value
                             (command-execution-record-prefix-argument record)) 16)
                        (eq? record (command-loop-state-repeat-record state))
                        (eq? record (car (command-runtime-execution-history runtime)))
                        (eq? record (car records)))
                   "runtime did not commit command identity and execution record"))
          (command-runtime-repeat-last! runtime context)
          (host-state-run! host)
          (check (equal? calls '((argument repeat) (argument test)))
                 "repeat did not replay the execution record" calls))
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
    (test-remapped-identity)
    (test-runtime-state-record-and-repeat)
    (test-undo-amalgamation))
)
