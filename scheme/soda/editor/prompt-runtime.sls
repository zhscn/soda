(library (soda editor prompt-runtime)
  (export install-prompt-effect-handler!)
  (import (rnrs)
          (soda editor effect)
          (soda editor event)
          (soda editor prompt))

  (define (install-prompt-effect-handler! executor)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-prompt-effect-handler!
        "expected an effect executor"
        executor))
    (register-effect-handler!
      executor
      'prompt.reply
      (lambda (reply)
        (unless (prompt-reply? reply)
          (assertion-violation
            'prompt.reply
            "expected a prompt reply"
            reply))
        (make-effect-result
          #t
          (list
            (make-internal-command-message
              (prompt-reply-command reply)
              (prompt-reply-result reply))))))
    executor))
