#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor event)
        (soda editor interaction)
        (soda editor interaction-transcript)
        (soda editor process-comint)
        (soda runtime))

  (define (buffer-string buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (utf8->string (text->bytevector text)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (string-contains? value needle)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and
          (<= index limit)
          (or
            (string=?
              (substring
                value
                index
                (+ index (string-length needle)))
              needle)
            (loop (+ index 1)))))))

  (define document (make-document "" 1001))
  (define buffer
    (make-buffer
      1000
      document
      "*process-comint-test*"
      'fundamental-mode))
  (define editor (make-editor buffer))
  (define runtime (make-runtime))
  (define executor (make-effect-executor))
  (define adapter
    (install-process-comint-runtime! executor runtime))

  (define (dispatch! message)
    (let loop ([messages (list message)])
      (unless (null? messages)
        (let* ([effects (editor-update! editor (car messages))]
               [result (execute-effects! executor effects)])
          (unless (effect-result-continue? result)
            (error 'process-comint-tests
                   "effect executor stopped unexpectedly"))
          (loop
            (append
              (effect-result-messages result)
              (cdr messages)))))))

  (define (handle-process-events!)
    (for-each
      (lambda (event)
        (let ([message
                (process-comint-runtime-handle-event
                  adapter
                  event)])
          (when message (dispatch! message))))
      (runtime-poll! runtime)))

  (define (wait-until predicate)
    (let loop ()
      (unless (predicate)
        (handle-process-events!)
        (loop))))

  (define profile
    (make-process-comint-profile
      "prompt-test"
      '("/bin/sh"
        "-c"
        "printf 'prompt> '; sleep 0.05; printf '\\nnotice\\nprompt> '; IFS= read line; printf 'out:%s\\nprompt> ' \"$line\"; IFS= read ignored")
      ""
      "prompt> "))

  (dispatch! (make-command-message 'process.start profile))
  (define session (car (editor-interactions editor)))
  (define process
    (interaction-session-evaluator session))
  (define process-buffer
    (editor-buffer-ref
      editor
      (interaction-session-buffer-id session)))

  (unless
    (and
      (eq? (interaction-session-kind session) 'process)
      (process-comint? process)
      (process-comint-running? process)
      (process-comint-source process))
    (error 'process-comint-tests
           "process session did not start"))

  (wait-until
    (lambda ()
      (string-contains?
        (buffer-string process-buffer)
        "prompt> ")))

  (dispatch!
    (make-input-message
      (make-text-input-event
        'text
        (string->utf8 "draft"))))

  (wait-until
    (lambda ()
      (string-contains?
        (buffer-string process-buffer)
        "notice\nprompt> draft")))

  (unless
    (= (view-caret (editor-active-view editor))
       (bytevector-length
         (string->utf8 (buffer-string process-buffer))))
    (error 'process-comint-tests
           "asynchronous output did not preserve the input caret"))

  (dispatch!
    (make-command-message 'process.send-input #f))
  (wait-until
    (lambda ()
      (string-contains?
        (buffer-string process-buffer)
        "out:draft\nprompt> ")))

  (dispatch!
    (make-command-message 'interaction.line-start #f))
  (unless
    (= (view-caret (editor-active-view editor))
       (interaction-session-input-start session))
    (error 'process-comint-tests
           "soft line start did not stop after the process prompt"))

  (unless
    (exists
      (lambda (field)
        (and
          (eq? (interaction-field-kind field) 'prompt)
          (positive?
            (- (interaction-field-end field)
               (interaction-field-start field)))))
      (interaction-transcript-fields
        (interaction-session-transcript session)
        process-buffer))
    (error 'process-comint-tests
           "process prompt was not recorded as a transcript field"))

  (dispatch!
    (make-command-message 'process.send-eof #f))
  (wait-until
    (lambda ()
      (not (process-comint-running? process))))

  (unless
    (and
      (string-contains?
        (buffer-string process-buffer)
        "Process prompt-test finished with status")
      (equal?
        (interaction-session-history session)
        '("draft")))
    (error 'process-comint-tests
           "process exit sentinel or history differs"))

  (editor-close! editor)
  (runtime-close! runtime)
