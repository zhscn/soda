(library (soda editor status)
  (export editor-set-status-message!
          editor-status-message
          editor-status-message-severity)
  (import (rnrs)
          (soda editor editor-storage))

  (define editor-set-status-message!
    (case-lambda
      [(editor message)
       (editor-set-status-message! editor message #f)]
      [(editor message severity)
       (require-open-editor 'editor-set-status-message! editor)
       (unless (or (not message) (string? message))
         (assertion-violation
           'editor-set-status-message!
           "status message must be a string or #f"
           message))
       (unless (memq severity '(#f info warning error))
         (assertion-violation
           'editor-set-status-message!
           "status severity must be #f, info, warning, or error"
           severity))
       (%editor-status-message-set!
         editor
         (if (and message severity)
             (cons severity message)
             message))]))

  (define (editor-status-message editor)
    (let ([message (%editor-status-message editor)])
      (if (pair? message)
          (cdr message)
          message)))

  (define (editor-status-message-severity editor)
    (let ([message (%editor-status-message editor)])
      (and (pair? message) (car message))))
)
