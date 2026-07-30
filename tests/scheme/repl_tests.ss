#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor completion)
        (soda editor completion-runtime)
        (soda editor core)
        (soda editor debugger)
        (soda editor effect)
        (soda editor evaluator)
        (soda editor event)
        (soda editor interaction)
        (soda editor repl)
        (soda tui frame)
        (soda tui renderer))

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

(define (buffer-string-range buffer start end)
  (let ([snapshot (document-snapshot (buffer-document buffer))])
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ([text (snapshot-text snapshot)])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (utf8->string
                (text-subbytevector text start end)))
            (lambda () (text-close! text)))))
      (lambda () (snapshot-close! snapshot)))))

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

(define (string-suffix? value suffix)
  (let ([offset (- (string-length value)
                   (string-length suffix))])
    (and
      (not (negative? offset))
      (string=?
        (substring value offset (string-length value))
        suffix))))

(define (frame-row-prefix frame row columns)
  (let loop ([column 0] [parts '()])
    (if (= column columns)
        (apply string-append (reverse parts))
        (loop
          (+ column 1)
          (cons
            (cell-text (frame-cell-ref frame row column))
            parts)))))

(define document (make-document "" 501))
(define buffer
  (make-buffer 500 document "*repl-test*" 'fundamental-mode))
(define editor (make-editor buffer))
(define executor (make-effect-executor))
(install-interaction-effect-handler! executor editor)
(install-completion-effect-handlers!
  executor
  (editor-completion-provider-catalog editor))

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

(define (repl-input)
  (buffer-string-range
    repl-buffer
    (interaction-session-input-start session)
    (bytevector-length (buffer-bytes repl-buffer))))

(define (insert-text! value)
  (dispatch!
    (make-input-message
      (make-text-input-event
        'text
        (string->utf8 value)))))

(define (press-key! key codepoint modifiers)
  (dispatch!
    (make-input-message
      (make-key-event
        key
        codepoint
        #f
        #f
        modifiers
        'press
        (make-bytevector 0)))))

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
       (= (interaction-session-output-mark session)
          (interaction-session-input-start session))
       (= (interaction-session-prompt-start session)
          (-
            (interaction-session-input-start session)
            (bytevector-length (string->utf8 "> "))))
       (= (interaction-session-prompt-end session)
          (interaction-session-input-start session))
       (zero? (view-first-column (editor-active-view editor)))
       (not (buffer-modified? repl-buffer))
       (string=? (buffer-string repl-buffer)
                 "Soda Chez Scheme REPL\n> ")
       (let ([frame (render-editor-frame editor 24 80)])
         (and
           (string=?
             (frame-row-prefix frame 0 21)
             "Soda Chez Scheme REPL")
           (string=?
             (frame-row-prefix frame 1 2)
             "> "))))
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

(insert-text! "(def")
(press-key! 'character (char->integer #\/) 2)
(let ([completion (editor-active-completion editor)])
  (unless
    (and
      completion
      (exists
        (lambda (item)
          (string=?
            (completion-item-insert-text item)
            "define"))
        (completion-session-items completion)))
    (error 'repl-tests
           "Scheme provider completion was cancelled before its response"
           (and
             completion
             (completion-session-query completion))
           (and
             completion
             (map
               completion-item-insert-text
               (completion-session-items completion))))))
(press-key! 'escape 27 0)
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(insert-text! "(string-ap")
(press-key! 'character (char->integer #\/) 2)
(let ([completion (editor-active-completion editor)])
  (unless
    (and
      completion
      (exists
        (lambda (item)
          (string=?
            (completion-item-insert-text item)
            "string-append"))
        (completion-session-items completion)))
    (error 'repl-tests
           "Scheme identifier punctuation was not part of the completion prefix")))
(press-key! 'enter 13 0)
(unless (string=? (repl-input) "(string-append")
  (error 'repl-tests
         "accepting Scheme completion replaced the wrong input range"
         (repl-input)))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(insert-text! "(soda-no-such-binding-xyz")
(press-key! 'character (char->integer #\/) 2)
(unless
  (and
    (not (editor-active-completion editor))
    (string=? (editor-status-message editor) "No completions"))
  (error 'repl-tests
         "an empty final provider result left completion active"))
(press-key! 'enter 13 0)
(unless (string=? (repl-input) "(soda-no-such-binding-xyz\n")
  (error 'repl-tests
         "empty completion state captured the following REPL Enter"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(dispatch! (make-command-message 'scheme.open-repl #f))
(unless (eq? (view-buffer (editor-active-view editor)) buffer)
  (error 'repl-tests
         "REPL toggle did not return to the originating editor view"))
(dispatch! (make-command-message 'scheme.open-repl #f))
(unless (eq? (view-buffer (editor-active-view editor)) repl-buffer)
  (error 'repl-tests
         "REPL toggle did not restore the transcript view"))

(insert-text! "kept-draft")
(dispatch! (make-command-message 'scheme.open-repl #f))
(dispatch! (make-command-message 'scheme.open-repl #f))
(unless
  (and (string=? (repl-input) "kept-draft")
       (= (view-caret (editor-active-view editor))
          (bytevector-length (buffer-bytes repl-buffer))))
  (error 'repl-tests
         "REPL reactivation did not preserve and focus the draft input"))

(define first-source-revision (buffer-revision repl-buffer))
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
       (= (evaluation-origin-revision first-origin)
          first-source-revision)
       (not (evaluation-origin-start first-origin))
       (not (evaluation-origin-end first-origin))
       (string-contains? (buffer-string repl-buffer) "hello\n42\n> ")
       (string-suffix?
         (buffer-string repl-buffer)
         "> kept-draft")
       (string=? (repl-input) "kept-draft")
       (string=?
         (buffer-string-range
           repl-buffer
           (interaction-session-last-input-start session)
           (interaction-session-last-input-end session))
         "(begin (define repl-value 40) (display \"hello\") (+ repl-value 2))")
       (string=?
         (buffer-string-range
           repl-buffer
           (interaction-session-last-output-start session)
           (interaction-session-last-output-end session))
         "hello\n42\n")
       (string=?
         (buffer-string-range
           repl-buffer
           (interaction-session-prompt-start session)
           (interaction-session-prompt-end session))
         "> ")
       (= (interaction-session-input-start session)
          (document-editable-start
            (buffer-document repl-buffer))))
  (error 'repl-tests
         "successful evaluation did not update the transcript or restore the draft"
         (buffer-string repl-buffer)
         (repl-input)
         (interaction-session-input-start session)
         (document-editable-start
           (buffer-document repl-buffer))
         (evaluation-origin-buffer-id first-origin)
         (evaluation-origin-revision first-origin)))

(press-key! 'character (char->integer #\c) 4)
(press-key! 'character (char->integer #\u) 4)
(unless
  (and (string=? (repl-input) "")
       (= (interaction-session-input-start session)
          (bytevector-length (buffer-bytes repl-buffer)))
       (not (interaction-session-history-index session)))
  (error 'repl-tests
         "clearing REPL input did not reset the editable region"))

(insert-text! "repl-v")
(press-key! 'character (char->integer #\/) 2)
(let ([completion (editor-active-completion editor)])
  (unless
    (and
      completion
      (exists
        (lambda (item)
          (and
            (eq? (completion-item-provider item) 'scheme-repl)
            (string=?
              (completion-item-insert-text item)
              "repl-value")))
        (completion-session-items completion)))
    (error 'repl-tests
           "REPL completion did not read the interaction environment")))
(press-key! 'escape 27 0)
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(define |soda quoted binding| 91)"))
(insert-text! "|soda quo")
(press-key! 'character (char->integer #\/) 2)
(let ([completion (editor-active-completion editor)])
  (unless
    (and
      completion
      (exists
        (lambda (item)
          (string=?
            (completion-item-insert-text item)
            "|soda quoted binding|"))
        (completion-session-items completion)))
    (error 'repl-tests
           "quoted Scheme identifier did not retain its lexical range")))
(press-key! 'enter 13 0)
(unless (string=? (repl-input) "|soda quoted binding|")
  (error 'repl-tests
         "quoted Scheme completion inserted an invalid identifier"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(display \"(define soda-transcript-only 1)\\n\")"))
(insert-text! "soda-transcript-o")
(press-key! 'character (char->integer #\/) 2)
(unless (not (editor-active-completion editor))
  (error 'repl-tests
         "REPL output was analyzed as Scheme source"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

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
(editor-register-internal-command!
  editor
  (make-internal-context-command
    'test.emitted-command
    (lambda (context)
      (set! emitted-value (command-context-argument context))
      '())))
(dispatch!
  (make-command-message
    'scheme.eval-expression
    "(editor-command! 'test.emitted-command 73)"))
(unless (equal? emitted-value 73)
  (error 'repl-tests
         "evaluation did not enqueue an editor command message"))

(insert-text! "(+ repl-value 3)")
(press-key! 'enter 13 0)
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

(insert-text! "pending-draft")
(define history-before-navigation
  (interaction-session-history session))
(press-key! 'character (char->integer #\p) 2)
(unless
  (string=?
    (repl-input)
    (car (reverse history-before-navigation)))
  (error 'repl-tests
         "M-p did not select the newest REPL history entry"))
(press-key! 'character (char->integer #\p) 2)
(unless
  (string=?
    (repl-input)
    (list-ref
      history-before-navigation
      (- (length history-before-navigation) 2)))
  (error 'repl-tests
         "repeated M-p did not move backward through REPL history"))
(press-key! 'character (char->integer #\n) 2)
(unless
  (string=?
    (repl-input)
    (car (reverse history-before-navigation)))
  (error 'repl-tests
         "M-n did not move forward through REPL history"))
(press-key! 'character (char->integer #\n) 2)
(unless
  (and (string=? (repl-input) "pending-draft")
       (not (interaction-session-history-index session)))
  (error 'repl-tests
         "history navigation did not restore the pending draft"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(define generation-before-multiline
  (interaction-session-generation session))
(define history-length-before-multiline
  (length (interaction-session-history session)))
(insert-text! "(+ 1")
(press-key! 'enter 13 0)
(unless
  (and (= (interaction-session-generation session)
          generation-before-multiline)
       (= (length (interaction-session-history session))
          history-length-before-multiline)
       (string=? (repl-input) "(+ 1\n"))
  (error 'repl-tests
         "Enter submitted an incomplete Scheme form"))
(insert-text! " 2)")
(press-key! 'enter 13 0)
(unless
  (and (= (interaction-session-generation session)
          (+ generation-before-multiline 1))
       (string=?
         (car (reverse (interaction-session-history session)))
         "(+ 1\n 2)")
       (string-contains? (buffer-string repl-buffer) "3\n> ")
       (string=? (repl-input) ""))
  (error 'repl-tests
         "completed multiline Scheme input was not submitted"))

(define source-form "(define source-eval-value 10)")
(define source-tail "(+ source-eval-value 2)")
(define source-text
  (string-append source-form "\n" source-tail))
(dispatch! (make-command-message 'scheme.open-repl #f))
(insert-text! source-text)
(define source-revision (buffer-revision buffer))
(dispatch! (make-command-message 'scheme.eval-buffer #f))
(let* ([result (interaction-session-last-result session)]
       [origin
         (evaluation-request-origin
           (evaluation-result-request result))])
  (unless
    (and
      (string-contains? (buffer-string repl-buffer) "12\n> ")
      (evaluation-origin? origin)
      (= (evaluation-origin-buffer-id origin) (buffer-id buffer))
      (= (evaluation-origin-revision origin) source-revision)
      (= (evaluation-origin-start origin) 0)
      (= (evaluation-origin-end origin)
         (bytevector-length (string->utf8 source-text))))
    (error 'repl-tests
           "eval-buffer did not retain its complete source origin")))

(dispatch! (make-command-message 'scheme.open-repl #f))
(dispatch! (make-command-message 'scheme.eval-last-sexp #f))
(let* ([result (interaction-session-last-result session)]
       [request (evaluation-result-request result)]
       [origin (evaluation-request-origin request)]
       [tail-start
         (bytevector-length
           (string->utf8
             (string-append source-form "\n")))])
  (unless
    (and
      (string=? (evaluation-request-source request) source-tail)
      (= (evaluation-origin-start origin) tail-start)
      (= (evaluation-origin-end origin)
         (bytevector-length (string->utf8 source-text))))
    (error 'repl-tests
           "eval-last-sexp did not select the datum before point"
           (evaluation-request-source request)
           (evaluation-origin-start origin)
           (evaluation-origin-end origin)
           tail-start)))

(dispatch! (make-command-message 'scheme.open-repl #f))
(dispatch! (make-command-message 'move.buffer-start #f))
(dispatch! (make-command-message 'mark.set #f))
(dispatch!
  (make-command-message
    'move.forward-character
    #f
    (prefix-argument-digit
      (prefix-argument-digit #f 2)
      9)))
(dispatch! (make-command-message 'scheme.eval-region #f))
(let* ([result (interaction-session-last-result session)]
       [request (evaluation-result-request result)]
       [origin (evaluation-request-origin request)])
  (unless
    (and
      (string=? (evaluation-request-source request) source-form)
      (= (evaluation-origin-start origin) 0)
      (= (evaluation-origin-end origin)
         (bytevector-length (string->utf8 source-form))))
    (error 'repl-tests
           "eval-region did not submit the active source range")))

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
    "(begin (define (soda-debug-inner debug-local) (car debug-local)) (soda-debug-inner 41))"))
(define failed-result
  (interaction-session-last-result session))
(unless
  (and (eq? (interaction-session-state session) 'failed)
       (evaluation-result? failed-result)
       (eq? (evaluation-result-status failed-result) 'condition)
       (condition? (evaluation-result-condition failed-result))
       (procedure?
         (evaluation-result-continuation failed-result))
       (debugger-session?
         (interaction-session-debugger session))
       (pair?
         (debugger-session-frames
           (interaction-session-debugger session)))
       (equal? (interaction-session-debug-actions session)
               '(open
                  next-frame
                  previous-frame
                  evaluate
                  retry
                  exit
                  discard))
       (string-contains? (buffer-string repl-buffer) "Exception:"))
  (error 'repl-tests
         "failed evaluation did not create debugger state"))

(define generation-before-retry
  (interaction-session-generation session))
(insert-text! "retry-draft")
(dispatch!
  (make-command-message 'scheme.debug-open #f))
(define debugger
  (interaction-session-debugger session))
(define debugger-buffer
  (view-buffer (editor-active-view editor)))
(unless
  (and
    (= (buffer-id debugger-buffer)
       (debugger-session-buffer-id debugger))
    (eq? (buffer-major-mode-name debugger-buffer)
         'debugger-mode)
    (string-contains?
      (buffer-string debugger-buffer)
      "Soda Scheme Debugger")
    (string-contains?
      (buffer-string debugger-buffer)
      "Frames:")
    (string-contains?
      (buffer-string debugger-buffer)
      "Selected frame locals:"))
  (error 'repl-tests
         "debug open did not project the failed continuation"))
(define debugger-text-before-insert
  (buffer-bytes debugger-buffer))
(insert-text! "x")
(unless
  (and
    (bytevector=? debugger-text-before-insert
                  (buffer-bytes debugger-buffer))
    (string? (editor-status-message editor)))
  (error 'repl-tests
         "debugger buffer accepted an editing command"))
(define selected-frame-before
  (debugger-session-selected-index debugger))
(press-key!
  'character
  (char->integer #\n)
  0)
(when (> (length (debugger-session-frames debugger)) 1)
  (unless
    (not
      (= selected-frame-before
         (debugger-session-selected-index debugger)))
    (error 'repl-tests
           "debug next-frame did not move the selected frame")))
(press-key!
  'character
  (char->integer #\e)
  0)
(unless (editor-active-prompt editor)
  (error 'repl-tests
         "debugger eval key did not open the frame prompt"))
(editor-abort-prompt! editor)
(dispatch!
  (make-command-message
    'scheme.debug-eval-frame
    "42"))
(unless
  (string-contains?
    (editor-status-message editor)
    "=> 42")
  (error 'repl-tests
         "debug frame evaluation did not expose its value"))
(dispatch!
  (make-command-message 'scheme.debug-retry #f))
(unless
  (and (= (interaction-session-generation session)
          (+ generation-before-retry 1))
       (eq? (interaction-session-state session) 'failed)
       (interaction-session-debugger session)
       (= (buffer-id (view-buffer (editor-active-view editor)))
          (buffer-id repl-buffer))
       (not
         (find
           (lambda (buffer)
             (eq? (buffer-major-mode-name buffer)
                  'debugger-mode))
           (editor-buffers editor)))
       (string-contains? (buffer-string repl-buffer) ";; retry")
       (string=? (repl-input) "retry-draft")
       (string-suffix?
         (buffer-string repl-buffer)
         "> retry-draft"))
  (error 'repl-tests
         "debug retry did not resubmit the failure and restore the draft"))

(dispatch!
  (make-command-message 'scheme.debug-open #f))
(dispatch!
  (make-command-message 'scheme.debug-exit #f))
(unless
  (and (eq? (interaction-session-state session) 'failed)
       (interaction-session-debugger session)
       (= (buffer-id (view-buffer (editor-active-view editor)))
          (buffer-id repl-buffer))
       (not
         (find
           (lambda (buffer)
             (eq? (buffer-major-mode-name buffer)
                  'debugger-mode))
           (editor-buffers editor))))
  (error 'repl-tests
         "debug exit did not retain the saved failure"))
(dispatch!
  (make-command-message 'scheme.debug-open #f))
(dispatch!
  (make-command-message 'scheme.debug-discard #f))
(unless
  (and (eq? (interaction-session-state session) 'ready)
       (not (interaction-session-debugger session))
       (null? (interaction-session-debug-actions session))
       (= (buffer-id (view-buffer (editor-active-view editor)))
          (buffer-id repl-buffer)))
  (error 'repl-tests
         "debug discard did not leave the failed state"))

(editor-close! editor)
(unless (and (editor-closed? editor)
             (interaction-session-closed? session)
             (interaction-transcript-closed?
               (interaction-session-transcript session))
             (buffer-closed? repl-buffer))
  (error 'repl-tests
         "closing the editor did not close its interaction session"))
