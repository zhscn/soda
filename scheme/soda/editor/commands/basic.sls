(library (soda editor commands basic)
  (export install-basic-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor display)
          (soda editor event)
          (soda editor kill)
          (soda editor keymap)
          (soda editor motion-runtime)
          (soda editor state))

  (define (with-document-text document procedure)
    (let ([snapshot (document-snapshot document)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (replace! buffer start end bytes)
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-replace! transaction start end bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change
            (change-close! change))))))

  (define (previous-character-offset text caret)
    (if (zero? caret)
        0
        (let loop ([offset (- caret 1)])
          (if (or (zero? offset)
                  (not (= (bitwise-and (text-byte-at text offset) #xc0) #x80)))
              offset
              (loop (- offset 1))))))

  (define (next-character-offset text caret)
    (let ([size (text-size text)])
      (if (>= caret size)
          size
          (let loop ([offset (+ caret 1)])
            (if (or (>= offset size)
                    (not (= (bitwise-and (text-byte-at text offset) #xc0) #x80)))
                offset
                (loop (+ offset 1)))))))

  (define (context-view context)
    (command-context-view context))

  (define (context-buffer context)
    (view-buffer (context-view context)))

  (define (context-document context)
    (buffer-document (context-buffer context)))

  (define (move-vertical! view delta)
    (with-document-text
      (buffer-document (view-buffer view))
      (lambda (text)
        (let* ([position (text-position text (view-caret view))]
               [line (car position)]
               [tab-width
                 (let ([setting
                         (buffer-setting-ref
                           (view-buffer view)
                           'tab-width
                           8)])
                   (if (and (integer? setting)
                            (exact? setting)
                            (positive? setting))
                       setting
                       8))]
               [column
                 (or
                   (view-preferred-column view)
                   (text-cell-column
                     text
                     (view-caret view)
                     tab-width))]
               [target
                 (max 0
                      (min (+ line delta)
                           (- (text-line-count text) 1)))]
               [target-offset
                 (text-offset-at-cell-column
                   text
                   target
                   column
                   tab-width)])
          (view-set-vertical-caret!
            view
            target-offset
            column)))))

  (define (self-insert-command context)
    (let* ([event (command-context-event context)]
           [argument (command-context-argument context)]
           [bytes
             (cond
               [(bytevector? argument) argument]
               [(and event (key-event? event)) (key-event-text event)]
               [else (make-bytevector 0)])]
           [view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end (if region (cdr region) caret)])
      (unless (zero? (bytevector-length bytes))
        (replace! (context-buffer context) start end bytes)
        (view-set-caret! view (+ start (bytevector-length bytes)))
        (when region
          (view-clear-mark! view)))
      '()))

  (define (backward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start
             (if region
                 (car region)
                 (with-document-text
                   (context-document context)
                   (lambda (text)
                     (previous-character-offset text caret))))]
           [end (if region (cdr region) caret)])
      (when (< start end)
        (replace!
          (context-buffer context)
          start
          end
          (make-bytevector 0)))
      (view-set-caret! view start)
      (when region
        (view-clear-mark! view))
      '()))

  (define (forward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end
             (if region
                 (cdr region)
                 (with-document-text
                   (context-document context)
                   (lambda (text)
                     (next-character-offset text caret))))])
      (when (> end start)
        (replace!
          (context-buffer context)
          start
          end
          (make-bytevector 0)))
      (when region
        (view-set-caret! view start)
        (view-clear-mark! view))
      '()))

  (define (newline-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [region (view-region view)]
           [start (if region (car region) caret)]
           [end (if region (cdr region) caret)])
      (replace!
        (context-buffer context)
        start
        end
        (make-bytevector 1 10))
      (view-set-caret! view (+ start 1))
      (when region
        (view-clear-mark! view))
      '()))

  (define (backward-character-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (previous-character-offset text (view-caret view))))))
    '())

  (define (forward-character-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (next-character-offset text (view-caret view))))))
    '())

  (define (move-word! context count)
    (let* ([view (context-view context)]
           [target
             (buffer-word-motion-target
               (context-buffer context)
               (view-caret view)
               count)])
      (view-set-caret! view target)
      '()))

  (define (forward-word-command context)
    (move-word! context 1))

  (define (backward-word-command context)
    (move-word! context -1))

  (define (previous-line-command context)
    (move-vertical! (context-view context) -1)
    '())

  (define (next-line-command context)
    (move-vertical! (context-view context) 1)
    '())

  (define (line-start-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (text-line-start
              text
              (car (text-position text (view-caret view))))))))
    '())

  (define (line-end-command context)
    (let ([view (context-view context)])
      (view-set-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (text-line-content-end
              text
              (car (text-position text (view-caret view))))))))
    '())

  (define (set-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [caret (view-caret view)])
      (view-set-mark! view caret)
      (editor-set-status-message! editor "Mark set")
      '()))

  (define (exchange-point-and-mark-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [mark (view-mark view)])
      (if (not mark)
          (editor-set-status-message! editor "No mark set")
          (let ([caret (view-caret view)])
            (view-set-mark! view caret)
            (view-set-caret! view mark)
            (editor-set-status-message!
              editor
              "Point and mark exchanged")))
      '()))

  (define (copy-region-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [region (view-region view)])
      (if (or (not region) (= (car region) (cdr region)))
          (editor-set-status-message! editor "Region is empty")
          (begin
            (editor-copy-buffer-range!
              editor
              (context-buffer context)
              (view-mark view)
              (view-caret view))
            (view-deactivate-mark! view)
            (editor-set-status-message! editor "Region copied")))
      '()))

  (define (kill-range! context first second)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [start (min first second)]
           [end (max first second)])
      (when (< start end)
        (editor-kill-buffer-range!
          editor
          (context-buffer context)
          first
          second)
        (view-set-caret! view start)
        (view-clear-mark! view))
      (< start end)))

  (define (kill-region-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [region (view-region view)])
      (if (or (not region) (= (car region) (cdr region)))
          (editor-set-status-message! editor "Region is empty")
          (begin
            (kill-range!
              context
              (view-mark view)
              (view-caret view))
            (editor-set-status-message! editor "Region killed")))
      '()))

  (define (kill-word-command context)
    (let* ([view (context-view context)]
           [start (view-caret view)]
           [end
             (buffer-word-motion-target
               (context-buffer context)
               start
               1)])
      (kill-range! context start end)
      '()))

  (define (backward-kill-word-command context)
    (let* ([view (context-view context)]
           [start (view-caret view)]
           [end
             (buffer-word-motion-target
               (context-buffer context)
               start
               -1)])
      (kill-range! context start end)
      '()))

  (define (yank-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [bytes (editor-current-kill editor)]
           [region (view-region view)]
           [caret (view-caret view)]
           [start (if region (car region) caret)]
           [end (if region (cdr region) caret)])
      (if (not bytes)
          (editor-set-status-message! editor "Kill ring is empty")
          (begin
            (replace! (context-buffer context) start end bytes)
            (view-set-caret!
              view
              (+ start (bytevector-length bytes)))
            (when region
              (view-clear-mark! view))
            (editor-set-status-message! editor "Yanked")))
      '()))

  (define (apply-history-command context operation empty-message success-message)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [change (operation (context-buffer context))])
      (if (not change)
          (editor-set-status-message! editor empty-message)
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (view-set-caret! view (view-caret view))
              (editor-set-status-message! editor success-message))
            (lambda () (change-close! change))))
      '()))

  (define (undo-command context)
    (apply-history-command
      context
      buffer-undo!
      "No undo information"
      "Undo"))

  (define (redo-command context)
    (apply-history-command
      context
      buffer-redo!
      "No redo information"
      "Redo"))

  (define (quit-command context)
    (let* ([editor (command-context-editor context)]
           [buffers (editor-buffers editor)]
           [pending?
             (exists buffer-save-pending? buffers)]
           [modified?
             (exists buffer-modified? buffers)])
      (cond
        [pending?
         (editor-disarm-quit! editor)
         (editor-set-status-message!
           editor
           "Save in progress; wait before quitting")
         '()]
        [(and modified? (not (editor-quit-armed? editor)))
         (editor-arm-quit! editor)
         (editor-set-status-message!
           editor
           "Modified buffers; press C-q again to discard changes")
         '()]
        [else
         (list (make-command-effect 'quit #f))])))

  (define (keyboard-quit-command context)
    (let ([editor (command-context-editor context)]
          [view (command-context-view context)])
      (cond
        [(editor-active-prompt editor)
         (let ([reply (editor-abort-prompt! editor)])
           (if reply
               (list (make-command-effect 'prompt.reply reply))
               '()))]
        [(view-completion view)
         (editor-cancel-completion! editor)
         (view-deactivate-mark! view)
         (editor-set-pending-keys! editor '())
         (editor-set-status-message! editor #f)
         '()]
        [else
         (view-deactivate-mark! view)
         (view-reset-input-states! view)
         (editor-set-pending-keys! editor '())
         (editor-set-status-message! editor #f)
         '()])))

  (define (stroke key codepoint modifiers)
    (make-key-stroke key codepoint modifiers))

  (define (install-basic-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)
          (if (pair? (cdddr entry)) (cadddr entry) #f)))
      (list
        (list 'editor.quit quit-command "Leave the editor.")
        (list
          'keyboard.quit
          keyboard-quit-command
          "Cancel the active input state and key sequence.")
        (list 'edit.self-insert self-insert-command "Insert event text.")
        (list
          'edit.backward-delete
          backward-delete-command
          "Delete the previous character.")
        (list
          'edit.forward-delete
          forward-delete-command
          "Delete the next character.")
        (list 'edit.newline newline-command "Insert a newline.")
        (list
          'move.backward-character
          backward-character-command
          "Move backward by one character.")
        (list
          'move.forward-character
          forward-character-command
          "Move forward by one character.")
        (list
          'move.backward-word
          backward-word-command
          "Move backward by one word.")
        (list
          'move.forward-word
          forward-word-command
          "Move forward by one word.")
        (list
          'move.previous-line
          previous-line-command
          "Move to the previous line.")
        (list
          'move.next-line
          next-line-command
          "Move to the next line.")
        (list
          'move.line-start
          line-start-command
          "Move to the start of the line.")
        (list
          'move.line-end
          line-end-command
          "Move to the end of the line.")
        (list 'edit.undo undo-command "Undo the previous buffer change.")
        (list 'edit.redo redo-command "Redo the next buffer change.")
        (list 'mark.set set-mark-command "Set the mark at point.")
        (list
          'mark.exchange-point-and-mark
          exchange-point-and-mark-command
          "Exchange point and mark.")
        (list
          'edit.copy-region
          copy-region-command
          "Copy the active region to the kill ring.")
        (list
          'edit.kill-region
          kill-region-command
          "Kill the active region."
          'kill)
        (list
          'edit.kill-word
          kill-word-command
          "Kill through the end of the next word."
          'kill)
        (list
          'edit.backward-kill-word
          backward-kill-word-command
          "Kill backward through the start of the previous word."
          'kill)
        (list
          'edit.yank
          yank-command
          "Insert the newest kill-ring entry.")))
    (for-each
      (lambda (entry)
        (editor-bind-key! editor (list (car entry)) (cdr entry)))
      (list
        (cons (stroke 'character 113 4) 'editor.quit)
        (cons (stroke 'backspace 127 0) 'edit.backward-delete)
        (cons (stroke 'delete #f 0) 'edit.forward-delete)
        (cons (stroke 'enter 13 0) 'edit.newline)
        (cons (stroke 'left #f 0) 'move.backward-character)
        (cons (stroke 'right #f 0) 'move.forward-character)
        (cons (stroke 'character (char->integer #\b) 2) 'move.backward-word)
        (cons (stroke 'character (char->integer #\f) 2) 'move.forward-word)
        (cons (stroke 'up #f 0) 'move.previous-line)
        (cons (stroke 'down #f 0) 'move.next-line)
        (cons (stroke 'home #f 0) 'move.line-start)
        (cons (stroke 'end #f 0) 'move.line-end)
        (cons (stroke 'character (char->integer #\z) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\/) 4) 'edit.undo)
        (cons (stroke 'character (char->integer #\z) 5) 'edit.redo)
        (cons (stroke 'character (char->integer #\space) 4) 'mark.set)
        (cons (stroke 'character (char->integer #\w) 2) 'edit.copy-region)
        (cons (stroke 'character (char->integer #\w) 4) 'edit.kill-region)
        (cons (stroke 'character (char->integer #\d) 2) 'edit.kill-word)
        (cons (stroke 'backspace 127 2) 'edit.backward-kill-word)
        (cons (stroke 'backspace 127 4) 'edit.backward-kill-word)
        (cons (stroke 'delete #f 4) 'edit.kill-word)
        (cons (stroke 'character (char->integer #\y) 4) 'edit.yank)))
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\u) 0))
      'edit.undo)
    (editor-bind-key!
      editor
      (list
        (stroke 'character (char->integer #\x) 4)
        (stroke 'character (char->integer #\x) 4))
      'mark.exchange-point-and-mark)
    (keymap-bind!
      (keymap-catalog-ref
        (editor-keymap-catalog editor)
        'editor.override)
      (list (stroke 'character 103 4))
      'keyboard.quit)))
