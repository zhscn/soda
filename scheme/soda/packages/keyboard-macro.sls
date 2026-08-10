(library (soda packages keyboard-macro)
  (export make-keyboard-macro-service!
          keyboard-macro-service?
          keyboard-macro-keymap
          keyboard-macro-recording?
          keyboard-macro-playing?
          keyboard-macro-step-count)
  (import (rnrs)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value))

  (define-record-type macro-step
    (fields name arguments prefix))

  (define-record-type
    (keyboard-macro-service %make-keyboard-macro-service
                            keyboard-macro-service?)
    (fields host owner
            (immutable keymap keyboard-macro-keymap)
            (mutable recording? keyboard-macro-recording?
                     keyboard-macro-recording?-set!)
            (mutable playing? keyboard-macro-playing?
                     keyboard-macro-playing?-set!)
            (mutable recorded keyboard-macro-recorded
                     keyboard-macro-recorded-set!)
            (mutable macro keyboard-macro-steps keyboard-macro-steps-set!)
            (mutable remaining keyboard-macro-remaining
                     keyboard-macro-remaining-set!)
            (mutable context keyboard-macro-context keyboard-macro-context-set!)))

  (define macro-command-names
    '(macro.start macro.end macro.play macro.cancel macro.step))

  (define (copy-value value)
    (cond
      [(string? value) (string-copy value)]
      [(bytevector? value) (bytevector-copy value)]
      [(pair? value) (cons (copy-value (car value)) (copy-value (cdr value)))]
      [(vector? value) (vector-map copy-value value)]
      [else value]))

  (define (keyboard-macro-step-count service)
    (length (keyboard-macro-steps service)))

  (define (macro-command? name)
    (memq name macro-command-names))

  (define (record-execution! service record)
    (let* ([identity (command-execution-record-identity record)]
           [name (command-identity-effective identity)])
      (when (and (keyboard-macro-recording? service)
                 (not (keyboard-macro-playing? service))
                 (eq? (command-execution-record-outcome record) 'completed)
                 (not (macro-command? name)))
        ;; Interactive readers have finished before pre-command hooks run.
        ;; Their decoded answers and any explicit repeat arguments therefore
        ;; become normal invocation arguments and playback needs no prompt.
        (keyboard-macro-recorded-set!
          service
          (cons
            (make-macro-step
              name
              (copy-value (command-execution-record-arguments record))
              (copy-value (command-execution-record-prefix-argument record)))
            (keyboard-macro-recorded service))))))

  (define (stop-playback! service)
    (keyboard-macro-playing?-set! service #f)
    (keyboard-macro-remaining-set! service '())
    (keyboard-macro-context-set! service #f)
    #t)

  (define (enqueue-next! service)
    (let ([remaining (keyboard-macro-remaining service)])
      (if (null? remaining)
          (stop-playback! service)
          (let* ([step (car remaining)]
                 [context
                  (package-host-refresh-command-context
                    (keyboard-macro-service-host service)
                    (keyboard-macro-context service)
                    (macro-step-prefix step) 'keyboard-macro)])
            (if (not context)
                (stop-playback! service)
                (begin
                  (keyboard-macro-remaining-set! service (cdr remaining))
                  (command-runtime-enqueue!
                    (package-host-command-runtime
                      (keyboard-macro-service-host service))
                    (make-command-invoke-message
                      'macro.step context (list step) #f))
                  #t))))))

  (define (repeat-steps steps count)
    (let loop ([remaining count] [result '()])
      (if (zero? remaining)
          result
          (loop (- remaining 1) (append result steps)))))

  (define (start-recording! service)
    (when (keyboard-macro-playing? service) (stop-playback! service))
    (keyboard-macro-recorded-set! service '())
    (keyboard-macro-recording?-set! service #t)
    (command-handled))

  (define (end-recording! service)
    (when (keyboard-macro-recording? service)
      (keyboard-macro-recording?-set! service #f)
      (keyboard-macro-steps-set!
        service (reverse (keyboard-macro-recorded service))))
    (command-handled))

  (define (play! service context count)
    (unless (and (integer? count) (exact? count) (> count 0))
      (assertion-violation 'macro.play
                           "repeat count must be a positive exact integer" count))
    (when (keyboard-macro-recording? service) (end-recording! service))
    (if (null? (keyboard-macro-steps service))
        (command-handled)
        (begin
          (keyboard-macro-context-set! service context)
          (keyboard-macro-remaining-set!
            service (repeat-steps (keyboard-macro-steps service) count))
          (keyboard-macro-playing?-set! service #t)
          (enqueue-next! service)
          (command-handled))))

  (define (make-keyboard-macro-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-keyboard-macro-service!
                           "expected a PackageHost and Owner" host owner))
    (owner-assert-active 'make-keyboard-macro-service! owner)
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'keyboard-macro)]
           [service
            (%make-keyboard-macro-service
              host owner keymap #f #f '() '() '() #f)])
      (command-runtime-add-hook!
        runtime 'execution-record owner 'keyboard-macro-record
        (lambda (record) (record-execution! service record)))
      (command-runtime-add-hook!
        runtime 'post-command owner 'keyboard-macro-advance
        (lambda (invocation result)
          (let ([name
                 (command-definition-name
                   (command-invocation-definition invocation))])
            (when (and (keyboard-macro-playing? service)
                       (not (macro-command? name)))
              (enqueue-next! service)))))
      (command-runtime-add-hook!
        runtime 'command-error owner 'keyboard-macro-error
        (lambda (invocation condition)
          (when (keyboard-macro-playing? service) (stop-playback! service))))
      (command-runtime-add-hook!
        runtime 'command-cancel owner 'keyboard-macro-command-cancel
        (lambda (invocation)
          (when (keyboard-macro-playing? service) (stop-playback! service))))
      (define-command
        runtime owner 'macro.step (context step)
        (documentation "Run one cancellable keyboard macro step.")
        (class 'macro)
        (undo 'ignore)
        (if (keyboard-macro-playing? service)
            (make-command-effect 'macro.invoke-step (cons step context))
            (command-handled)))
      (command-runtime-register-effect-handler!
        runtime 'macro.invoke-step owner 'keyboard-macro-invoke-step
        (lambda (runtime invocation effect)
          (when (keyboard-macro-playing? service)
            (let* ([payload (command-effect-payload effect)]
                   [step (car payload)]
                   [context (cdr payload)])
              (command-runtime-enqueue!
                runtime
                (let ([name (macro-step-name step)])
                  (unless (command-runtime-command-definition runtime name #f)
                    (stop-playback! service)
                    (assertion-violation
                      'macro.play "recorded command is no longer registered" name))
                  (make-command-invoke-message
                    name context
                    (copy-value (macro-step-arguments step)) #f)))))))
      (define-command
        runtime owner 'macro.start (context)
        (documentation "Start recording resolved command invocations.")
        (class 'macro)
        (undo 'ignore)
        (start-recording! service))
      (define-command
        runtime owner 'macro.end (context)
        (documentation "Finish the current keyboard macro.")
        (class 'macro)
        (undo 'ignore)
        (end-recording! service))
      (define-command
        runtime owner 'macro.play (context . counts)
        (documentation "Queue playback of the last keyboard macro.")
        (class 'macro)
        (undo 'ignore)
        (play! service context (if (null? counts) 1 (car counts))))
      (define-command
        runtime owner 'macro.cancel (context)
        (documentation "Cancel recording or queued macro playback.")
        (class 'macro)
        (undo 'ignore)
        (when (keyboard-macro-recording? service)
          (keyboard-macro-recording?-set! service #f)
          (keyboard-macro-recorded-set! service '()))
        (when (keyboard-macro-playing? service) (stop-playback! service))
        (command-handled))
      (let ([control-x
             (make-key-stroke 'character (char->integer #\x) 4)])
        (keymap-bind!
          keymap (list control-x (make-key-stroke 'character (char->integer #\() 0))
          'macro.start)
        (keymap-bind!
          keymap (list control-x (make-key-stroke 'character (char->integer #\)) 0))
          'macro.end)
        (keymap-bind!
          keymap (list control-x (make-key-stroke 'character (char->integer #\e) 0))
          'macro.play))
      service))
)
