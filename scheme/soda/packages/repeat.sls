(library (soda packages repeat)
  (export make-repeat-command!)
  (import (rnrs)
          (soda host command)
          (soda host input)
          (soda host input-event)
          (soda host package-context))

  ;; Repeat replays the last record explicitly marked repeatable.  The runtime
  ;; refreshes command-loop identity and prefix semantics for the queued call;
  ;; this command itself never replaces the repeat target.
  (define (make-repeat-command! context)
    (unless (package-context? context)
      (assertion-violation 'make-repeat-command!
                           "expected a PackageContext"))
    (let* ([keymap (make-keymap 'command-repeat)]
           [state (make-input-state 'command-repeat (list keymap) 'ignore)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\z) 0))
        'command.repeat)
      (package-context-set-repeat-state! context state))
    (define-package-command
      context 'command.repeat (command-context)
      (documentation "Repeat the last repeatable command.")
      (class 'command)
      (semantic 'command.repeat)
      (repeatable #f)
      (undo 'ignore)
      (package-context-repeat-last! context command-context)
      (command-handled)))
)
