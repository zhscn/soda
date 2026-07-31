(library (soda editor scheme-repl-indentation)
  (export install-scheme-repl-indentation!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor comint)
          (soda editor edit)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor scheme-indentation)
          (soda editor state))

  (define (buffer-size buffer)
    (let ([snapshot
            (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (buffer-range-source buffer start end)
    (let ([snapshot
            (document-snapshot (buffer-document buffer))])
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

  (define (repl-command-session who context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [session
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))])
      (unless
        (and
          session
          (eq? (interaction-session-kind session) 'repl))
        (assertion-violation
          who
          "active buffer is not a REPL transcript"
          (buffer-id buffer)))
      session))

  (define (leading-whitespace-end text start end)
    (let loop ([offset start])
      (if
        (and
          (< offset end)
          (memv (text-byte-at text offset) '(9 32)))
        (loop (+ offset 1))
        offset)))

  (define (repl-indent-line-command context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [session
             (repl-command-session
               'scheme.repl-indent-line
               context)]
           [input-start
             (interaction-session-input-start session)]
           [caret
             (max input-start (view-caret view))]
           [snapshot
             (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([line
                         (car (text-position text caret))]
                       [start
                         (max
                           input-start
                           (text-line-start text line))]
                       [end (text-line-content-end text line)]
                       [whitespace-end
                         (leading-whitespace-end text start end)]
                       [indentation
                         (scheme-line-indent
                           (buffer-range-source
                             buffer
                             input-start
                             start)
                           (buffer-setting-ref
                             buffer
                             'indent-width
                             2))])
                  (when indentation
                    (let* ([replacement
                             (make-bytevector indentation 32)]
                           [old-length (- whitespace-end start)]
                           [delta (- indentation old-length)])
                      (unless
                        (and
                          (= old-length indentation)
                          (let loop ([offset start])
                            (or
                              (= offset whitespace-end)
                              (and
                                (= (text-byte-at text offset) 32)
                                (loop (+ offset 1))))))
                        (buffer-replace-range!
                          buffer
                          start
                          whitespace-end
                          replacement)
                        (view-set-caret!
                          view
                          (if
                            (<= caret whitespace-end)
                            (+ start indentation)
                            (+ caret delta))))))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot))))
    '())

  (define (string-line-position source offset)
    (let loop ([index 0] [line 0] [line-start 0])
      (if
        (= index offset)
        (values line line-start (- offset line-start))
        (if
          (char=? (string-ref source index) #\newline)
          (loop (+ index 1) (+ line 1) (+ index 1))
          (loop (+ index 1) line line-start)))))

  (define (string-line-start source target-line)
    (let ([length (string-length source)])
      (let loop ([index 0] [line 0])
        (cond
          [(= line target-line) index]
          [(= index length) length]
          [(char=? (string-ref source index) #\newline)
           (loop (+ index 1) (+ line 1))]
          [else (loop (+ index 1) line)]))))

  (define (string-line-end source start)
    (let ([length (string-length source)])
      (let loop ([index start])
        (if
          (or
            (= index length)
            (char=? (string-ref source index) #\newline))
          index
          (loop (+ index 1))))))

  (define (string-leading-whitespace-end source start end)
    (let loop ([index start])
      (if
        (and
          (< index end)
          (memv (string-ref source index) '(#\space #\tab)))
        (loop (+ index 1))
        index)))

  (define (reindented-caret source replacement caret-offset)
    (let* ([source-bytes (string->utf8 source)]
           [prefix (make-bytevector caret-offset)])
      (bytevector-copy!
        source-bytes
        0
        prefix
        0
        caret-offset)
      (let ([character-offset
              (string-length (utf8->string prefix))])
        (call-with-values
          (lambda ()
            (string-line-position source character-offset))
          (lambda (line old-start old-column)
            (let* ([old-end
                     (string-line-end source old-start)]
                   [old-leading
                     (-
                       (string-leading-whitespace-end
                         source
                         old-start
                         old-end)
                       old-start)]
                   [new-start
                     (string-line-start replacement line)]
                   [new-end
                     (string-line-end replacement new-start)]
                   [new-leading
                     (-
                       (string-leading-whitespace-end
                         replacement
                         new-start
                         new-end)
                       new-start)]
                   [new-column
                     (min
                       (- new-end new-start)
                       (if
                         (<= old-column old-leading)
                         new-leading
                         (+ new-leading
                            (- old-column old-leading))))]
                   [new-offset (+ new-start new-column)])
              (bytevector-length
                (string->utf8
                  (substring
                    replacement
                    0
                    new-offset)))))))))

  (define (repl-indent-entry-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [session
             (repl-command-session
               'scheme.repl-indent-entry
               context)]
           [start (interaction-session-input-start session)]
           [end (buffer-size buffer)]
           [source (comint-current-input editor session)]
           [replacement
             (scheme-reindent-entry
               source
               (buffer-setting-ref buffer 'indent-width 2))])
      (unless (string=? source replacement)
        (let ([caret
                (reindented-caret
                  source
                  replacement
                  (max
                    0
                    (min
                      (- end start)
                      (- (view-caret view) start))))])
          (buffer-replace-range!
            buffer
            start
            end
            (string->utf8 replacement))
          (view-set-caret! view (+ start caret))))
      '()))

  (define (install-scheme-repl-indentation! editor keymap)
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
          'scheme.repl-indent-line
          repl-indent-line-command
          "Reindent the current REPL entry line.")
        (list
          'scheme.repl-indent-entry
          repl-indent-entry-command
          "Reindent the complete REPL entry.")))
    (keymap-bind!
      keymap
      (list (make-key-stroke 'tab 9 0))
      'scheme.repl-indent-line)
    (keymap-bind!
      keymap
      (list
        (make-key-stroke
          'character
          (char->integer #\q)
          2))
      'scheme.repl-indent-entry)
    editor))
