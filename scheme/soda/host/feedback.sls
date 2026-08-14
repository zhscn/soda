(library (soda host feedback)
  (export make-user-feedback
          user-feedback?
          user-feedback-text
          user-feedback-severity)
  (import (rnrs))

  ;; UserFeedback is a semantic command outcome destined for the echo area.
  ;; It is distinct from input guidance, stable editor status, interactions,
  ;; and background notifications.
  (define-record-type
    (user-feedback %make-user-feedback user-feedback?)
    (fields
      (immutable text user-feedback-text)
      (immutable severity user-feedback-severity)))

  (define make-user-feedback
    (case-lambda
      [(text) (make-user-feedback text 'info)]
      [(text severity)
       (unless (and (string? text)
                    (not (exists (lambda (character)
                                   (or (char=? character #\newline)
                                       (char=? character #\return)))
                                 (string->list text)))
                    (memq severity '(info success warning error)))
         (assertion-violation
           'make-user-feedback "invalid single-line user feedback"
           text severity))
       (%make-user-feedback (string-copy text) severity)]))
)
