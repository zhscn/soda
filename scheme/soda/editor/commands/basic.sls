(library (soda editor commands basic)
  (export install-basic-commands!
          editor-register-command!
          editor-bind-key!
          editor-execute-command!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor event)
          (soda editor keymap)
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
               [column (or (view-preferred-column view) (cdr position))]
               [target
                 (max 0
                      (min (+ line delta)
                           (- (text-line-count text) 1)))]
               [line-start (text-line-start text target)]
               [line-end (text-line-content-end text target)])
          (view-set-vertical-caret!
            view
            (min (+ line-start column) line-end)
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
           [caret (view-caret view)])
      (unless (zero? (bytevector-length bytes))
        (replace! (context-buffer context) caret caret bytes)
        (view-set-caret! view (+ caret (bytevector-length bytes))))
      '()))

  (define (backward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [start
             (with-document-text
               (context-document context)
               (lambda (text)
                 (previous-character-offset text caret)))])
      (when (< start caret)
        (replace!
          (context-buffer context)
          start
          caret
          (make-bytevector 0)))
      (view-set-caret! view start)
      '()))

  (define (forward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [end
             (with-document-text
               (context-document context)
               (lambda (text)
                 (next-character-offset text caret)))])
      (when (> end caret)
        (replace!
          (context-buffer context)
          caret
          end
          (make-bytevector 0)))
      '()))

  (define (newline-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)])
      (replace!
        (context-buffer context)
        caret
        caret
        (make-bytevector 1 10))
      (view-set-caret! view (+ caret 1))
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

  (define (quit-command context)
    (list (make-command-effect 'quit #f)))

  (define (keyboard-quit-command context)
    (let ([editor (command-context-editor context)]
          [view (command-context-view context)])
      (view-reset-input-states! view)
      (editor-set-pending-keys! editor '())
      (editor-set-status-message! editor #f)
      '()))

  (define editor-register-command!
    (case-lambda
      [(editor name procedure)
       (require-open-editor 'editor-register-command! editor)
       (register-command!
         (editor-command-registry editor)
         name
         procedure)]
      [(editor name procedure documentation)
       (require-open-editor 'editor-register-command! editor)
       (register-command!
         (editor-command-registry editor)
         name
         procedure
         documentation)]))

  (define (editor-bind-key! editor sequence command)
    (require-open-editor 'editor-bind-key! editor)
    (unless (command-registered?
              (editor-command-registry editor)
              command)
      (assertion-violation
        'editor-bind-key!
        "cannot bind an unknown command"
        command))
    (keymap-bind! (editor-keymap editor) sequence command))

  (define editor-execute-command!
    (case-lambda
      [(editor name)
       (editor-execute-command! editor name #f #f)]
      [(editor name event argument)
       (require-open-editor 'editor-execute-command! editor)
       (let ([effects
               (execute-command!
                 (editor-command-registry editor)
                 name
                 (make-command-context
                   editor
                   (editor-active-view editor)
                   event
                   argument))])
         (ensure-view-visible! (editor-active-view editor))
         effects)]))

  (define (stroke key codepoint modifiers)
    (make-key-stroke key codepoint modifiers))

  (define (install-basic-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)))
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
          "Move to the end of the line.")))
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
        (cons (stroke 'up #f 0) 'move.previous-line)
        (cons (stroke 'down #f 0) 'move.next-line)
        (cons (stroke 'home #f 0) 'move.line-start)
        (cons (stroke 'end #f 0) 'move.line-end)))
    (keymap-bind!
      (keymap-catalog-ref
        (editor-keymap-catalog editor)
        'editor.override)
      (list (stroke 'character 103 4))
      'keyboard.quit)))
