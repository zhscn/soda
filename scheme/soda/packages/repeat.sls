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
    (define-command
      runtime owner 'command.repeat (context)
      (documentation "Repeat the last repeatable command.")
      (class 'command)
      (semantic 'command.repeat)
      (repeatable #f)
      (undo 'ignore)
      (command-runtime-repeat-last! runtime context)
      (command-handled)))
)
