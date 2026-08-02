(library (soda editor completion-commands)
  (export install-completion-commands!
          editor-auto-trigger-completion!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor keymap)
          (soda editor language)
          (soda editor state))

  (define (default-identifier-character? character)
    (or (char-alphabetic? character)
        (char-numeric? character)
        (char=? character #\_)))

  (define (buffer-identifier-character? buffer)
    (let* ([profile (buffer-language-profile buffer)]
           [policy
             (and
               profile
               (language-profile-lexical profile))])
      (or policy default-identifier-character?)))

  (define (string-member? value values)
    (exists (lambda (candidate) (string=? value candidate)) values))

  (define (buffer-words value identifier-character?)
    (let ([length (string-length value)]
          [seen (make-hashtable string-hash string=?)])
      (define (add-word word words)
        (if (hashtable-contains? seen word)
            words
            (begin
              (hashtable-set! seen word #t)
              (cons word words))))
      (let loop ([index 0] [start #f] [words '()])
        (cond
          [(= index length)
           (if start
               (reverse
                 (add-word
                   (substring value start index)
                   words))
               (reverse words))]
          [(identifier-character? (string-ref value index))
           (loop (+ index 1) (or start index) words)]
          [start
           (let ([word (substring value start index)])
             (loop
               (+ index 1)
               #f
               (add-word word words)))]
          [else
           (loop (+ index 1) #f words)]))))

  (define (identifier-end value start identifier-character?)
    (let ([length (string-length value)])
      (let loop ([index start])
        (if
          (and
            (< index length)
            (identifier-character? (string-ref value index)))
          (loop (+ index 1))
          index))))

  (define (snapshot-completion-text buffer caret)
    (let* ([document (buffer-document buffer)]
           [editable-start
             (or (document-editable-start document) 0)]
           [snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (if (< caret editable-start)
                    (values #f #f editable-start)
                    (values
                      (utf8->string
                        (text-subbytevector
                          text
                          editable-start
                          (text-size text)))
                      (utf8->string
                        (text-subbytevector
                          text
                          editable-start
                          caret))
                      editable-start)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (make-buffer-word-source
            words
            identifier-character?
            boundaries)
    (make-choice-source
      'buffer-word
      '((category . buffer-word))
      (or
        boundaries
        (lambda (input point)
          (let loop ([index point])
            (if
              (and
                (positive? index)
                (identifier-character?
                  (string-ref input (- index 1))))
              (loop (- index 1))
              (cons index point)))))
      (lambda (query)
        (map
          (lambda (word)
            (make-completion-item
              word
              'buffer-word
              word
              word
              word
              "buffer"
              #f
              word))
          (filter
            (lambda (word) (not (string=? word query)))
            words)))
      (lambda (value) (string-member? value words))
      (lambda (generation) #f)))

  (define (complete-at-point! editor view quiet?)
    (let* (
           [buffer (view-buffer view)]
           [caret (view-caret view)]
           [identifier-character?
             (buffer-identifier-character? buffer)]
           [boundaries
             (buffer-setting-ref
               buffer
               'completion-boundaries
               #f)])
      (call-with-values
        (lambda ()
          (snapshot-completion-text buffer caret))
        (lambda (text before editable-start)
          (if (not text)
              (editor-set-status-message!
                editor
                "Completion target is read-only")
              (let* ([source
                       (make-buffer-word-source
                         (buffer-words
                           text
                           identifier-character?)
                         identifier-character?
                         boundaries)]
                     [range
                       (choice-source-boundaries
                         source
                         before
                         (string-length before))])
                (if (not range)
                    (unless quiet?
                      (editor-set-status-message!
                        editor
                        "No completion at point"))
                    (let* ([start
                             (+
                               editable-start
                               (bytevector-length
                                 (string->utf8
                                   (substring
                                     before
                                     0
                                     (car range)))))]
                           [replacement-end
                             (+
                               editable-start
                               (bytevector-length
                                 (string->utf8
                                   (substring
                                     text
                                     0
                                     (identifier-end
                                       text
                                       (string-length before)
                                       identifier-character?)))))]
                           [completion
                             (editor-start-document-completion!
                               editor
                               source
                               start
                               caret
                               replacement-end
                               (buffer-setting-ref
                                 buffer
                                 'completion-providers
                                 '()))])
                      (when
                        (and
                          (null?
                            (completion-session-items completion))
                          (not
                            (completion-session-pending? completion)))
                        (editor-cancel-completion! editor)
                        (unless quiet?
                          (editor-set-status-message!
                            editor
                            "No completions")))))))))
      '()))

  (define (complete-at-point-command context)
    (complete-at-point!
      (command-context-editor context)
      (command-context-view context)
      #f))

  (define (string-last-character value)
    (and
      (positive? (string-length value))
      (string-ref value (- (string-length value) 1))))

  (define (trigger-character? buffer character)
    (exists
      (lambda (candidate)
        (char=? candidate character))
      (buffer-setting-ref
        buffer
        'completion-trigger-characters
        '())))

  (define (editor-auto-trigger-completion! editor inserted-text)
    (require-open-editor
      'editor-auto-trigger-completion!
      editor)
    (unless (string? inserted-text)
      (assertion-violation
        'editor-auto-trigger-completion!
        "inserted text must be a string"
        inserted-text))
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [character (string-last-character inserted-text)]
           [identifier-character?
             (buffer-identifier-character? buffer)]
           [identifier?
             (and character (identifier-character? character))]
           [provider-trigger?
             (and character (trigger-character? buffer character))]
           [gate
             (buffer-setting-ref
               buffer
               'completion-trigger-predicate
               #f)])
      (when
        (and
          (not (editor-active-prompt editor))
          (not (view-completion view))
          (buffer-setting-ref
            buffer
            'completion-auto-trigger?
            #t)
          (pair?
            (buffer-setting-ref
              buffer
              'completion-providers
              '()))
          (or identifier? provider-trigger?)
          (or
            (not gate)
            (gate
              buffer
              (view-caret view)
              (if provider-trigger? 'trigger-character 'identifier)
              inserted-text)))
        (complete-at-point! editor view #t))
      '()))

  (define (accept-completion-command context)
    (editor-accept-completion!
      (command-context-editor context))
    '())

  (define (accept-replacing-completion-command context)
    (editor-accept-completion!
      (command-context-editor context)
      'replace)
    '())

  (define (cancel-completion-command context)
    (editor-cancel-completion!
      (command-context-editor context))
    '())

  (define (next-completion-command context)
    (editor-completion-next!
      (command-context-editor context))
    '())

  (define (previous-completion-command context)
    (editor-completion-previous!
      (command-context-editor context))
    '())

  (define (install-completion-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'completion.buffer-word
          complete-at-point-command
          "Complete the identifier at point.")
        (list
          'completion.at-point
          complete-at-point-command
          "Complete the identifier at point.")
        (list
          'completion.accept
          accept-completion-command
          "Apply the selected completion candidate.")
        (list
          'completion.accept-replace
          accept-replacing-completion-command
          "Apply the selected completion candidate and replace its suffix.")
        (list
          'completion.cancel
          cancel-completion-command
          "Cancel completion.")
        (list
          'completion.next
          next-completion-command
          "Select the next completion candidate.")
        (list
          'completion.previous
          previous-completion-command
          "Select the previous completion candidate.")))
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind! keymap (list (car entry)) (cdr entry)))
        (list
          (cons (make-key-stroke 'enter 13 0) 'completion.accept)
          (cons (make-key-stroke 'character 106 4) 'completion.accept)
          (cons (make-key-stroke 'enter 13 2) 'completion.accept-replace)
          (cons (make-key-stroke 'escape 27 0) 'completion.cancel)
          (cons (make-key-stroke 'tab 9 0) 'completion.next)
          (cons (make-key-stroke 'tab 9 1) 'completion.previous)
          (cons (make-key-stroke 'down #f 0) 'completion.next)
          (cons (make-key-stroke 'up #f 0) 'completion.previous)
          (cons (make-key-stroke 'character 110 4) 'completion.next)
          (cons (make-key-stroke 'character 112 4) 'completion.previous)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'completion.menu
        keymap))
    (editor-bind-key!
      editor
      (list (make-key-stroke 'character 47 2))
      'completion.at-point)
    editor))
