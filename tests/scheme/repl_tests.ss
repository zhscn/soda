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
        (soda editor interaction-transcript)
        (soda editor prompt)
        (soda editor repl)
        (soda editor scheme-indentation)
        (only (soda editor state) view-set-caret!)
        (soda tui frame)
        (soda tui renderer))

(unless
  (and
    (= (scheme-continuation-indent "(+ 1" 2) 3)
    (= (scheme-continuation-indent "(define (value x)" 2) 2)
    (= (scheme-continuation-indent "(let ([value 1])" 2) 2)
    (= (scheme-continuation-indent "  [value" 2) 4)
    (= (scheme-continuation-indent "(display \"(\")" 2) 0)
    (= (scheme-continuation-indent "(begin #| ) |#" 2) 2)
    (= (scheme-continuation-indent "(list #\\(" 2) 2)
    (= (scheme-continuation-indent "(list |(|)" 2) 0)
    (string=?
      (scheme-reindent-entry
        "(define (value x)\n(+ x\n1))"
        2)
      "(define (value x)\n  (+ x\n     1))")
    (string=?
      (scheme-reindent-entry
        "(display \"first\n  second\")"
        2)
      "(display \"first\n  second\")"))
  (error 'repl-tests
         "Scheme continuation indentation differs from Expeditor rules"))

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

(define (frame-has-row-prefix? frame rows columns expected)
  (let loop ([row 0])
    (and
      (< row rows)
      (or
        (string=?
          (frame-row-prefix frame row columns)
          expected)
        (loop (+ row 1))))))

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

(dispatch! (make-resize-message 24 80))
(unless
  (and (editor-layout-ready? editor)
       (= (editor-frame-rows editor) 24)
       (= (editor-frame-columns editor) 80)
       (view-viewport-ready? (editor-active-view editor)))
  (error 'repl-tests
         "resize did not establish the editor viewport layout"))

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
       (= (length (editor-window-leaves editor)) 2)
       (exists
         (lambda (view)
           (eq? (view-buffer view) buffer))
         (editor-visible-views editor))
       (exists
         (lambda (view)
           (eq? (view-buffer view) repl-buffer))
         (editor-visible-views editor))
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
       (not (buffer-setting-ref repl-buffer 'truncate-lines #t))
       (view-viewport-ready? (editor-active-view editor))
       (= (view-viewport-rows (editor-active-view editor)) 11)
       (= (view-viewport-columns (editor-active-view editor)) 80)
       (not (buffer-modified? repl-buffer))
       (string=? (buffer-string repl-buffer)
                 "Soda Chez Scheme REPL\n> ")
       (let ([frame (render-editor-frame editor 24 80)])
         (and
           (frame-has-row-prefix?
             frame 24 21 "Soda Chez Scheme REPL")
           (frame-has-row-prefix?
             frame 24 2 "> "))))
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

(dispatch! (make-resize-message 24 12))
(let ([frame (render-editor-frame editor 24 12)])
  (unless
    (and
      (frame-has-row-prefix? frame 24 12 "Soda Chez   ")
      (frame-has-row-prefix? frame 24 12 "Scheme REPL ")
      (frame-has-row-prefix? frame 24 12 ">           "))
    (error 'repl-tests
           "REPL transcript did not soft-wrap to its viewport")))
(dispatch! (make-resize-message 24 80))

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
(unless (string=? (repl-input) "(soda-no-such-binding-xyz\n  ")
  (error 'repl-tests
         "empty completion state captured the following REPL Enter"))
(let ([frame (render-editor-frame editor 24 80)])
  (unless
    (and
      (frame-has-row-prefix? frame 24 4 ".   ")
      (string=?
        (repl-input)
        "(soda-no-such-binding-xyz\n  "))
    (error 'repl-tests
           "continuation prompt did not preserve logical REPL input"
           (repl-input))))
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

(editor-delete-other-windows! editor)
(dispatch! (make-command-message 'scheme.open-repl #f))
(unless
  (and
    (= (length (editor-window-leaves editor)) 2)
    (eq? (view-buffer (editor-active-view editor)) buffer)
    (exists
      (lambda (view)
        (eq? (view-buffer view) repl-buffer))
      (editor-visible-views editor)))
  (error 'repl-tests
         "REPL toggle did not recreate a missing editor window"))
(dispatch! (make-command-message 'scheme.open-repl #f))

(define first-source-revision (buffer-revision repl-buffer))
(define first-evaluation-source
  "(begin\n  (define repl-value 40)\n  (define repl-procedure (case-lambda [() 0] [(left right . rest) left]))\n  (display \"hello\")\n  (+ repl-value 2))")
(dispatch!
  (make-command-message
    'scheme.eval-expression
    first-evaluation-source))

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
         first-evaluation-source)
       (let ([display-map
               (view-effective-display-map
                 (editor-active-view editor))])
         (and
           display-map
           (exists
             (lambda (run)
               (and
                 (eq? (display-run-owner run)
                      'interaction.continuation-prompt)
                 (< (interaction-session-last-input-start session)
                    (display-run-start run)
                    (interaction-session-last-input-end session))))
             (display-map-runs display-map))))
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

(let* ([evaluator (interaction-session-evaluator session)]
       [binding
         (chez-evaluator-binding-metadata
           evaluator
           'repl-value)]
       [procedure-binding
         (chez-evaluator-binding-metadata
           evaluator
           'repl-procedure)])
  (unless
    (and
      (memq 'repl-value
            (chez-evaluator-runtime-symbols evaluator))
      (positive? (chez-evaluator-generation evaluator))
      (runtime-binding? binding)
      (eq? (runtime-binding-kind binding) 'variable)
      (string=? (runtime-binding-preview binding) "40")
      (runtime-binding? procedure-binding)
      (equal?
        (runtime-binding-signature-formals
          procedure-binding)
        '(() (arg1 arg2 . args)))
      (equal?
        (runtime-binding-signatures procedure-binding)
        '("(repl-procedure)"
          "(repl-procedure arg1 arg2 . args)")))
    (error 'repl-tests
           "evaluation did not update the runtime binding catalog")))

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
(press-key! 'up #f 2)
(unless
  (string=?
    (repl-input)
    (car (reverse history-before-navigation)))
  (error 'repl-tests
         "M-Up did not select the newest REPL history entry"))
(press-key! 'up #f 2)
(unless
  (string=?
    (repl-input)
    (list-ref
      history-before-navigation
      (- (length history-before-navigation) 2)))
  (error 'repl-tests
         "repeated M-Up did not move backward through REPL history"))
(press-key! 'down #f 2)
(unless
  (string=?
    (repl-input)
    (car (reverse history-before-navigation)))
  (error 'repl-tests
         "M-Down did not move forward through REPL history"))
(press-key! 'down #f 2)
(unless
  (and (string=? (repl-input) "pending-draft")
       (not (interaction-session-history-index session)))
  (error 'repl-tests
         "history navigation did not restore the pending draft"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(insert-text! "(+")
(press-key! 'character (char->integer #\p) 2)
(unless
  (string=? (repl-input) "(+ repl-value 3)")
  (error 'repl-tests
         "M-p did not search REPL history by prefix"))
(press-key! 'character (char->integer #\p) 2)
(unless
  (string=? (repl-input) "(+ repl-value 1)")
  (error 'repl-tests
         "repeated M-p did not continue prefix history search"))
(press-key! 'character (char->integer #\n) 2)
(unless
  (string=? (repl-input) "(+ repl-value 3)")
  (error 'repl-tests
         "M-n did not search forward with the retained prefix"))
(press-key! 'character (char->integer #\n) 2)
(unless
  (string=? (repl-input) "(+")
  (error 'repl-tests
         "forward prefix search did not restore its draft"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(insert-text! "repl-value")
(press-key! 'character (char->integer #\P) 2)
(unless
  (string=? (repl-input) "(+ repl-value 3)")
  (error 'repl-tests
         "M-P did not search REPL history by containment"))
(press-key! 'character (char->integer #\N) 2)
(unless
  (string=? (repl-input) "repl-value")
  (error 'repl-tests
         "M-N did not restore the contains-search draft"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(insert-text! "first\nsecond")
(press-key! 'character (char->integer #\<) 2)
(unless
  (= (view-caret (editor-active-view editor))
     (interaction-session-input-start session))
  (error 'repl-tests
         "M-< did not move to the start of the REPL entry"))
(press-key! 'character (char->integer #\a) 4)
(unless
  (= (view-caret (editor-active-view editor))
     (interaction-session-input-start session))
  (error 'repl-tests
         "C-a moved into the protected REPL prompt"))
(let* ([fields
         (interaction-transcript-fields
           (interaction-session-transcript session)
           repl-buffer)]
       [historical-prompt
         (find
           (lambda (field)
             (and
               (eq? (interaction-field-kind field) 'prompt)
               (< (interaction-field-end field)
                  (interaction-session-prompt-start session))))
           (reverse fields))])
  (unless historical-prompt
    (error 'repl-tests
           "interaction transcript did not retain historical fields"))
  (view-set-caret!
    (editor-active-view editor)
    (interaction-field-start historical-prompt))
  (press-key! 'character (char->integer #\a) 4)
  (unless
    (= (view-caret (editor-active-view editor))
       (interaction-field-end historical-prompt))
    (error 'repl-tests
           "C-a did not use the prompt field as a soft line beginning")))
(press-key! 'character (char->integer #\>) 2)
(unless
  (= (view-caret (editor-active-view editor))
     (bytevector-length (buffer-bytes repl-buffer)))
  (error 'repl-tests
         "M-> did not move to the end of the REPL entry"))
(press-key! 'up #f 0)
(unless
  (< (view-caret (editor-active-view editor))
     (bytevector-length (buffer-bytes repl-buffer)))
  (error 'repl-tests
         "Up did not move within a multiline REPL entry"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))
(press-key! 'up #f 0)
(unless
  (string=?
    (repl-input)
    (car (reverse history-before-navigation)))
  (error 'repl-tests
         "Up at the first entry line did not enter REPL history"))
(press-key! 'down #f 0)
(unless (string=? (repl-input) "")
  (error 'repl-tests
         "Down at the last entry line did not restore the draft"))

(insert-text! "(if test\nx")
(press-key! 'tab 9 0)
(unless (string=? (repl-input) "(if test\n    x")
  (error 'repl-tests
         "Tab did not reindent the current REPL entry line"))
(dispatch! (make-command-message 'scheme.repl-clear-input #f))

(define unindented-entry
  " (define (entry-value x)\n(+ x\n1))")
(insert-text! unindented-entry)
(press-key! 'character (char->integer #\q) 2)
(unless
  (and
    (string=?
      (repl-input)
      "(define (entry-value x)\n  (+ x\n     1))")
    (=
      (view-caret (editor-active-view editor))
      (bytevector-length (buffer-bytes repl-buffer))))
  (error 'repl-tests
         "M-q did not reindent the complete REPL entry"))
(dispatch! (make-command-message 'edit.undo #f))
(unless (string=? (repl-input) unindented-entry)
  (error 'repl-tests
         "whole-entry reindent was not one undo transaction"))
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
       (string=? (repl-input) "(+ 1\n   "))
  (error 'repl-tests
         "Enter submitted an incomplete Scheme form"))
(insert-text! "2)")
(press-key! 'enter 13 0)
(unless
  (and (= (interaction-session-generation session)
          (+ generation-before-multiline 1))
       (string=?
         (car (reverse (interaction-session-history session)))
         "(+ 1\n   2)")
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
    "(begin (define (soda-debug-inner debug-local) (set! debug-local debug-local) (car debug-local)) (soda-debug-inner 41))"))
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
       (equal?
         (map
           debugger-action-id
           (debugger-session-actions
             (interaction-session-debugger session)))
         '(retry use-value edit-and-retry abort))
       (eq?
         (debugger-action-id
           (debugger-actions-default
             (debugger-session-actions
               (interaction-session-debugger session))))
         'retry)
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
    (= (length (editor-window-leaves editor)) 2)
    (exists
      (lambda (view)
        (eq? (view-buffer view) buffer))
      (editor-visible-views editor))
    (exists
      (lambda (view)
        (eq? (view-buffer view) debugger-buffer))
      (editor-visible-views editor))
    (not
      (exists
        (lambda (view)
          (eq? (view-buffer view) repl-buffer))
        (editor-visible-views editor)))
    (eq? (buffer-major-mode-name debugger-buffer)
         'debugger-mode)
    (string-contains?
      (buffer-string debugger-buffer)
      "Soda Scheme Debugger")
    (string-contains?
      (buffer-string debugger-buffer)
      "Actions:\n> retry [restart] Retry")
    (string-contains?
      (buffer-string debugger-buffer)
      "use-value [resume] Use value <expression>")
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
(dispatch!
  (make-command-message
    'scheme.debug-inspect-condition
    #f))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "Inspector path: condition")
  (error 'repl-tests
         "debug inspector did not expose the original condition"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-continuation
    #f))
(define code-frame-index
  (let loop
    ([children
       (inspector-node-children
         (debugger-session-inspection-node debugger))]
     [index 0])
    (cond
      [(null? children) #f]
      [(and
         (eq? (inspector-child-role (car children))
              'frame)
         (inspector-node-has-capability?
           (inspector-child-node (car children))
           'code))
       index]
      [else
       (loop (cdr children) (+ index 1))])))
(unless code-frame-index
  (error 'repl-tests
         "continuation inspector did not expose procedure code"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-ref
    code-frame-index))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-code
    #f))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "procedure code")
  (error 'repl-tests
         "debugger did not inspect continuation procedure code"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-top
    #f))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "Inspector path: raise continuation\n")
  (error 'repl-tests
         "debugger did not restore the continuation inspector root"))
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
(let ([local-frame
        (find
          (lambda (frame)
            (pair? (debugger-frame-variables frame)))
          (debugger-session-frames debugger))])
  (when local-frame
    (debugger-session-next-frame!
      debugger
      (-
        (debugger-frame-index local-frame)
        (debugger-session-selected-index debugger)))
    (dispatch!
      (make-command-message
        'scheme.debug-inspect-local
        0))
    (unless
      (string-contains?
        (buffer-string debugger-buffer)
        "Inspector path: frame[")
      (error 'repl-tests
             "debug inspector did not expose a frame local"))))
(define assignable-local
  (let frame-loop ([frames (debugger-session-frames debugger)])
    (and
      (pair? frames)
      (let ([frame (car frames)])
        (debugger-session-next-frame!
          debugger
          (-
            (debugger-frame-index frame)
            (debugger-session-selected-index debugger)))
        (or
          (let variable-loop
            ([index 0]
             [variables
               (debugger-frame-variables frame)])
            (and
              (pair? variables)
              (begin
                (debugger-session-inspect-local!
                  debugger
                  index)
                (if
                  (memq
                    'set-value
                    (debugger-session-inspection-capabilities
                      debugger))
                  (cons
                    (debugger-frame-index frame)
                    index)
                  (variable-loop
                    (+ index 1)
                    (cdr variables))))))
          (frame-loop (cdr frames)))))))
(unless assignable-local
  (error 'repl-tests
         "debugger did not expose an assignable frame variable"))
(dispatch!
  (make-command-message
    'scheme.debug-set-value
    "99"))
(unless
  (and
    (string-contains?
      (editor-status-message editor)
      "Set inspected value to 99")
    (string-contains?
      (buffer-string debugger-buffer)
      "Object: 99"))
  (error 'repl-tests
         "debugger did not update an assignable frame variable"))
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
  (and
    (string-contains?
      (editor-status-message editor)
      "=> 42")
    (string-contains?
      (buffer-string debugger-buffer)
      "Frame evaluations:")
    (string-contains?
      (buffer-string debugger-buffer)
      "=> frame "))
  (error 'repl-tests
         "debug frame evaluation did not persist its value"))
(dispatch!
  (make-command-message
    'scheme.debug-eval-frame
    "(car 42)"))
(unless
  (and
    (string-contains?
      (editor-status-message editor)
      "Debugger evaluation failed:")
    (string-contains?
      (buffer-string debugger-buffer)
      ": (car 42)"))
  (error 'repl-tests
         "debug frame evaluation did not persist its condition"))
(dispatch!
  (make-command-message
    'scheme.debug-eval-frame
    "(let ([v (make-vector 70)]) (do ([i 0 (+ i 1)]) ((= i 70) v) (vector-set! v i i)))"))
(unless
  (and
    (string-contains?
      (buffer-string debugger-buffer)
      "Children 0-32 of 70:")
    (string-contains?
      (buffer-string debugger-buffer)
      "  31 31 = 31"))
  (error 'repl-tests
         "debug Inspector did not show the first child page"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-next-page
    #f))
(unless
  (and
    (= (debugger-session-inspection-page-start debugger) 32)
    (string-contains?
      (buffer-string debugger-buffer)
      "Children 32-64 of 70:")
    (string-contains?
      (buffer-string debugger-buffer)
      "  32 32 = 32"))
  (error 'repl-tests
         "debug Inspector did not advance to the next child page"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-previous-page
    #f))
(unless
  (= (debugger-session-inspection-page-start debugger) 0)
  (error 'repl-tests
         "debug Inspector did not return to the previous child page"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-print
    #f))
(unless
  (and
    (eq? (debugger-session-inspection-output-style debugger) 'print)
    (string-contains?
      (buffer-string debugger-buffer)
      "Inspector print:\n#("))
  (error 'repl-tests
         "debug Inspector did not project pretty-printed output"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-write
    #f))
(unless
  (and
    (eq? (debugger-session-inspection-output-style debugger) 'write)
    (string-contains?
      (debugger-session-inspection-output-text debugger)
      "#(0 1 2"))
  (error 'repl-tests
         "debug Inspector did not retain written output"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-find
    "(lambda (value) (and (integer? value) (>= value 65)))"))
(unless
  (and
    (string-contains?
      (buffer-string debugger-buffer)
      "Inspector path: result[0] / find result")
    (string-contains?
      (buffer-string debugger-buffer)
      "Object: 65"))
  (error 'repl-tests
         "debug Inspector did not navigate to a found object"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-find-next
    #f))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "Object: 66")
  (error 'repl-tests
         "debug Inspector did not navigate to the next found object"))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-top
    #f))
(dispatch!
  (make-command-message
    'scheme.debug-inspect-find
    #f))
(unless
  (and
    (editor-active-prompt editor)
    (string=?
      (prompt-request-prompt
        (prompt-session-request
          (editor-active-prompt editor)))
      "Find object matching predicate: "))
  (error 'repl-tests
         "debug Inspector find command did not open its predicate prompt"))
(editor-abort-prompt! editor)
(dispatch!
  (make-command-message
    'scheme.debug-eval-frame
    "(list 'alpha 'beta)"))
(unless
  (and
    (string-contains?
      (buffer-string debugger-buffer)
      "Inspector path: result[0]")
    (string-contains?
      (buffer-string debugger-buffer)
      "car = alpha"))
  (error 'repl-tests
         "debug frame evaluation did not expose an inspectable result"))
(dispatch!
  (make-command-message 'scheme.debug-inspect-ref 0))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "Inspector path: result[0] / car")
  (error 'repl-tests
         "debug inspector did not descend into a child"))
(dispatch!
  (make-command-message 'scheme.debug-inspect-up #f))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "Inspector path: result[0]\n")
  (error 'repl-tests
         "debug inspector did not return to its parent"))
(dispatch!
  (make-command-message 'scheme.debug-inspect-ref 0))
(dispatch!
  (make-command-message 'scheme.debug-inspect-top #f))
(unless
  (string-contains?
    (buffer-string debugger-buffer)
    "Inspector path: result[0]\n")
  (error 'repl-tests
         "debug inspector did not return to its root"))
(dispatch!
  (make-command-message 'scheme.debug-apply "length"))
(unless
  (and
    (string-contains?
      (editor-status-message editor)
      "Inspector apply => 2")
    (string-contains?
      (buffer-string debugger-buffer)
      "Inspector path: apply result[0]")
    (string-contains?
      (buffer-string debugger-buffer)
      "Object: 2"))
  (error 'repl-tests
         "debug inspector did not apply a procedure to its object"))
(dispatch!
  (make-command-message 'scheme.debug-action #f))
(let* ([completion
         (editor-active-prompt-completion editor)]
       [selected
         (and
           completion
           (completion-session-selected-item completion))]
       [actions
         (and
           completion
           (map
             (lambda (item)
               (debugger-action-id
                 (completion-item-payload item)))
             (completion-session-items completion)))])
  (unless
    (and
      selected
      (eq?
        (debugger-action-id
          (completion-item-payload selected))
        'retry)
      (= (length actions) 4)
      (for-all
        (lambda (id)
          (and (memq id actions) #t))
        '(retry use-value edit-and-retry abort)))
    (error 'repl-tests
           "debugger action selector did not project session actions")))
(let ([reply (editor-accept-prompt! editor)])
  (dispatch!
    (make-internal-command-message
      (prompt-reply-command reply)
      (prompt-reply-result reply))))
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
       (= (length (editor-window-leaves editor)) 2)
       (exists
         (lambda (view)
           (eq? (view-buffer view) buffer))
         (editor-visible-views editor))
       (exists
         (lambda (view)
           (eq? (view-buffer view) repl-buffer))
         (editor-visible-views editor))
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
