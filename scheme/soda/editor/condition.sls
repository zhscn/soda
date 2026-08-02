(library (soda editor condition)
  (export editor-user-error
          editor-user-error-condition?
          condition-display-string)
  (import (rnrs)
          (only (chezscheme) display-condition))

  (define-condition-type
    &editor-user-error
    &error
    make-editor-user-error-condition
    editor-user-error-condition?)

  (define (editor-user-error who message . irritants)
    (unless (symbol? who)
      (assertion-violation
        'editor-user-error
        "who must be a symbol"
        who))
    (unless (string? message)
      (assertion-violation
        'editor-user-error
        "message must be a string"
        message))
    (raise
      (condition
        (make-editor-user-error-condition)
        (make-who-condition who)
        (make-message-condition message)
        (make-irritants-condition irritants))))

  (define (condition-display-string value)
    (call-with-string-output-port
      (lambda (port)
        (display-condition value port)))))
