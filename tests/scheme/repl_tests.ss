#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor evaluator)
        (soda editor event)
        (soda editor interaction)
        (soda editor repl))

(define (buffer-bytes buffer)
  (let ([snapshot (document-snapshot (buffer-document buffer))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda () (text->bytevector text))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

(define (buffer-string buffer)
  (utf8->string (buffer-bytes buffer)))

(define (string-contains? value needle)
  (let ([limit (- (string-length value) (string-length needle))])
    (let loop ([index 0])
      (and (<= index limit)
           (or
             (string=?
               (substring
                 value
                 index
                 (+ index (string-length needle)))
               needle)
             (loop (+ index 1)))))))

(define document (make-document "" 501))
(define buffer
  (make-buffer 500 document "*repl-test*" 'fundamental-mode))
(define editor (make-editor buffer))
(define executor (make-effect-executor))
(install-interaction-effect-handler! executor editor)

(define (dispatch! message)
  (let loop ([messages (list message)])
    (unless (null? messages)
      (let* ([effects (editor-update! editor (car messages))]
             [result (execute-effects! executor effects)])
        (unless (effect-result-continue? result)
          (error 'repl-tests "unexpected stop effect"))
        (loop
          (append
            (effect-result-messages result)
            (cdr messages)))))))

(dispatch! (make-command-message 'scheme.open-repl #f))
(define session (car (editor-interactions editor)))
(define repl-buffer
  (editor-buffer-ref editor (interaction-session-buffer-id session)))

(unless
  (and (eq? (interaction-session-kind session) 'repl)
       (eq? (interaction-session-state session) 'ready)
       (= (length (editor-buffers editor)) 2)
       (= (length (editor-views editor)) 2)
       (not (= (document-id (buffer-document buffer))
               (document-id (buffer-document repl-buffer))))
       (eq? (view-buffer (editor-active-view editor)) repl-buffer)
       (= (interaction-session-input-start session)
          (document-editable-start
            (buffer-document repl-buffer)))
       (not (buffer-modified? repl-buffer))
       (string=? (buffer-string repl-buffer)
                 "Soda Chez Scheme REPL\n> "))
  (error 'repl-tests
         "opening the REPL did not create an editor-owned session"
         (editor-status-message editor)
         (interaction-session-state session)
         (length (editor-buffers editor))
         (length (editor-views editor))
         (buffer-string repl-buffer)
         (interaction-session-input-start session)
         (document-editable-start
           (buffer-document repl-buffer))))

(dispatch! (make-command-message 'scheme.open-repl #f))
(unless (eq? (view-buffer (editor-active-view editor)) buffer)
  (error 'repl-tests
         "REPL toggle did not return to the originating editor view"))
(dispatch! (make-command-message 'scheme.open-repl #f))
(unless (eq? (view-buffer (editor-active-view editor)) repl-buffer)
  (error 'repl-tests
         "REPL toggle did not restore the transcript view"))

(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(begin (define repl-value 40) (display \"hello\") (+ repl-value 2))"))

(define first-request
  (evaluation-result-request
    (interaction-session-last-result session)))
(define first-origin (evaluation-request-origin first-request))
(unless
  (and (eq? (interaction-session-state session) 'ready)
       (= (length (interaction-session-history session)) 1)
       (evaluation-origin? first-origin)
       (= (evaluation-origin-buffer-id first-origin)
          (buffer-id repl-buffer))
       (= (evaluation-origin-revision first-origin) 0)
       (not (evaluation-origin-start first-origin))
       (not (evaluation-origin-end first-origin))
       (string-contains? (buffer-string repl-buffer) "hello\n42\n> ")
       (= (interaction-session-input-start session)
          (bytevector-length (buffer-bytes repl-buffer)))
       (= (interaction-session-input-start session)
          (document-editable-start
            (buffer-document repl-buffer))))
  (error 'repl-tests
         "successful evaluation did not update the transcript"))

(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(+ repl-value 1)"))
(unless (string-contains? (buffer-string repl-buffer) "41\n> ")
  (error 'repl-tests
         "REPL environment did not retain top-level definitions"))

(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(eof-object? (read))"))
(unless (string-contains? (buffer-string repl-buffer) "#t\n> ")
  (error 'repl-tests
         "evaluation consumed command-loop standard input"))

(define emitted-value #f)
(editor-register-command!
  editor
  'test.emitted-command
  (lambda (context)
    (set! emitted-value (command-context-argument context))
    '()))
(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(editor-command! 'test.emitted-command 73)"))
(unless (equal? emitted-value 73)
  (error 'repl-tests
         "evaluation did not enqueue an editor command message"))

(dispatch!
  (make-input-message
    (make-text-input-event
      'text
      (string->utf8 "(+ repl-value 3)"))))
(dispatch!
  (make-input-message
    (make-key-event
      'enter
      13
      #f
      #f
      0
      'press
      (make-bytevector 0))))
(unless
  (and (string-contains? (buffer-string repl-buffer) "43\n> ")
       (string=?
         (car (reverse (interaction-session-history session)))
         "(+ repl-value 3)")
       (let* ([result (interaction-session-last-result session)]
              [request (evaluation-result-request result)]
              [origin (evaluation-request-origin request)])
         (and (evaluation-origin? origin)
              (= (evaluation-origin-buffer-id origin)
                 (buffer-id repl-buffer))
              (integer? (evaluation-origin-start origin))
              (integer? (evaluation-origin-end origin))
              (< (evaluation-origin-start origin)
                 (evaluation-origin-end origin)))))
  (error 'repl-tests
         "REPL Enter binding did not submit editable transcript input"))

(define transcript-before-protected-delete
  (buffer-bytes repl-buffer))
(dispatch!
  (make-command-message 'edit.backward-delete #f))
(unless
  (and (bytevector=? transcript-before-protected-delete
                     (buffer-bytes repl-buffer))
       (string? (editor-status-message editor)))
  (error 'repl-tests
         "REPL transcript prefix was editable"))
(editor-set-status-message! editor #f)

(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(car 1)"))
(define failed-result
  (interaction-session-last-result session))
(unless
  (and (eq? (interaction-session-state session) 'failed)
       (evaluation-result? failed-result)
       (eq? (evaluation-result-status failed-result) 'condition)
       (condition? (evaluation-result-condition failed-result))
       (procedure?
         (evaluation-result-continuation failed-result))
       (equal? (interaction-session-debug-actions session)
               '(retry dismiss))
       (string-contains? (buffer-string repl-buffer) "Exception:"))
  (error 'repl-tests
         "failed evaluation did not create debugger state"))

(define generation-before-retry
  (interaction-session-generation session))
(dispatch!
  (make-command-message 'scheme.debug-retry #f))
(unless
  (and (= (interaction-session-generation session)
          (+ generation-before-retry 1))
       (eq? (interaction-session-state session) 'failed)
       (string-contains? (buffer-string repl-buffer) ";; retry"))
  (error 'repl-tests
         "debug retry did not resubmit the failed evaluation"))

(dispatch!
  (make-command-message 'scheme.debug-dismiss #f))
(unless
  (and (eq? (interaction-session-state session) 'ready)
       (null? (interaction-session-debug-actions session)))
  (error 'repl-tests
         "debug dismiss did not leave the failed state"))

(editor-close! editor)
(unless (and (editor-closed? editor)
             (interaction-session-closed? session)
             (buffer-closed? repl-buffer))
  (error 'repl-tests
         "closing the editor did not close its interaction session"))
