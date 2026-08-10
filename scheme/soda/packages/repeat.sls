(library (soda packages repeat)
  (export make-repeat-command!)
  (import (rnrs)
          (soda host command)
          (soda host command-runtime)
          (soda host value))

  ;; Repeat replays the last record explicitly marked repeatable.  The runtime
  ;; refreshes command-loop identity and prefix semantics for the queued call;
  ;; this command itself never replaces the repeat target.
  (define (make-repeat-command! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-repeat-command!
                           "expected a command runtime and owner"))
    (command-runtime-register-command!
      runtime
      (make-command-definition
        'command.repeat
        (lambda (context)
          (command-runtime-repeat-last! runtime context)
          (command-result-with-transition
            (command-handled)
            (make-command-loop-transition #f #f 'ignore)))
        owner "Repeat the last repeatable command." 'command #f))))
