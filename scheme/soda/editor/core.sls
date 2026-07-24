(library (soda editor core)
  (export make-editor
          editor?
          editor-close!
          editor-closed?
          editor-buffers
          editor-active-view
          editor-command-registry
          editor-keymap
          editor-pending-keys
          editor-status-message
          editor-register-command!
          editor-bind-key!
          editor-execute-command!
          editor-update!
          make-editor-message
          editor-message?
          editor-message-kind
          editor-message-payload
          view?
          view-id
          view-buffer
          view-caret
          view-first-line
          view-viewport-rows
          view-viewport-columns
          view-set-first-line!
          command-effect?
          command-effect-kind
          command-effect-payload)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor input)
          (soda editor keymap))

  (define-record-type (view %make-view view?)
    (fields
      (immutable id view-id)
      (immutable buffer view-buffer)
      (mutable caret view-caret view-caret-set!)
      (mutable preferred-column
               view-preferred-column
               view-preferred-column-set!)
      (mutable first-line view-first-line view-first-line-set!)
      (mutable viewport-rows
               view-viewport-rows
               view-viewport-rows-set!)
      (mutable viewport-columns
               view-viewport-columns
               view-viewport-columns-set!)))

  (define-record-type (editor %make-editor editor?)
    (fields
      (immutable buffers editor-buffers)
      (immutable active-view editor-active-view)
      (immutable commands editor-command-registry)
      (immutable keymap editor-keymap)
      (mutable pending-keys
               editor-pending-keys
               editor-pending-keys-set!)
      (mutable status-message
               editor-status-message
               editor-status-message-set!)
      (mutable closed? editor-closed? editor-closed?-set!)))

  (define-record-type editor-message
    (fields kind payload))

  (define (require-open-editor who value)
    (unless (editor? value)
      (assertion-violation who "expected an editor" value))
    (when (editor-closed? value)
      (assertion-violation who "editor is closed" value)))

  (define (view-set-first-line! value line)
    (unless (view? value)
      (assertion-violation
        'view-set-first-line!
        "expected a view"
        value))
    (unless (and (integer? line) (exact? line) (not (negative? line)))
      (assertion-violation
        'view-set-first-line!
        "line must be a non-negative exact integer"
        line))
    (view-first-line-set! value line))

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
      (call-with-values
        (lambda ()
          (call-with-buffer-transaction
            buffer
            (lambda (transaction)
              (transaction-replace! transaction start end bytes))))
        (lambda (result committed-change)
          (set! change committed-change)))
      (change-close! change)))

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

  (define (move-caret! view offset)
    (view-caret-set! view offset)
    (view-preferred-column-set! view #f))

  (define (move-vertical! view delta)
    (let ([document (buffer-document (view-buffer view))])
      (with-document-text
        document
        (lambda (text)
          (let* ([position (text-position text (view-caret view))]
                 [line (car position)]
                 [column
                   (or (view-preferred-column view) (cdr position))]
                 [target
                   (max 0
                        (min (+ line delta)
                             (- (text-line-count text) 1)))]
                 [line-start (text-line-start text target)]
                 [line-end (text-line-content-end text target)])
            (view-caret-set! view (min (+ line-start column) line-end))
            (view-preferred-column-set! view column))))))

  (define (ensure-view-visible! view)
    (let* ([document (buffer-document (view-buffer view))]
           [caret-line
             (with-document-text
               document
               (lambda (text)
                 (car (text-position text (view-caret view)))))]
           [first-line (view-first-line view)]
           [rows (max 1 (view-viewport-rows view))])
      (cond
        [(< caret-line first-line)
         (view-first-line-set! view caret-line)]
        [(>= caret-line (+ first-line rows))
         (view-first-line-set! view (- caret-line (- rows 1)))])))

  (define (context-view context)
    (command-context-view context))

  (define (context-buffer context)
    (view-buffer (context-view context)))

  (define (context-document context)
    (buffer-document (context-buffer context)))

  (define (no-effects)
    '())

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
        (move-caret! view (+ caret (bytevector-length bytes))))
      (no-effects)))

  (define (backward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [start
             (with-document-text
               (context-document context)
               (lambda (text)
                 (previous-character-offset text caret)))])
      (when (< start caret)
        (replace! (context-buffer context)
                  start
                  caret
                  (make-bytevector 0)))
      (move-caret! view start)
      (no-effects)))

  (define (forward-delete-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)]
           [end
             (with-document-text
               (context-document context)
               (lambda (text)
                 (next-character-offset text caret)))])
      (when (> end caret)
        (replace! (context-buffer context)
                  caret
                  end
                  (make-bytevector 0)))
      (no-effects)))

  (define (newline-command context)
    (let* ([view (context-view context)]
           [caret (view-caret view)])
      (replace! (context-buffer context)
                caret
                caret
                (make-bytevector 1 10))
      (move-caret! view (+ caret 1))
      (no-effects)))

  (define (backward-character-command context)
    (let ([view (context-view context)])
      (move-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (previous-character-offset text (view-caret view))))))
    (no-effects))

  (define (forward-character-command context)
    (let ([view (context-view context)])
      (move-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (next-character-offset text (view-caret view))))))
    (no-effects))

  (define (previous-line-command context)
    (move-vertical! (context-view context) -1)
    (no-effects))

  (define (next-line-command context)
    (move-vertical! (context-view context) 1)
    (no-effects))

  (define (line-start-command context)
    (let ([view (context-view context)])
      (move-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (text-line-start
              text
              (car (text-position text (view-caret view))))))))
    (no-effects))

  (define (line-end-command context)
    (let ([view (context-view context)])
      (move-caret!
        view
        (with-document-text
          (context-document context)
          (lambda (text)
            (text-line-content-end
              text
              (car (text-position text (view-caret view))))))))
    (no-effects))

  (define (quit-command context)
    (list (make-command-effect 'quit #f)))

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

  (define (stroke key codepoint modifiers)
    (make-key-stroke key codepoint modifiers))

  (define (install-default-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)))
      (list
        (list 'editor.quit quit-command "Leave the editor.")
        (list 'edit.self-insert self-insert-command "Insert event text.")
        (list 'edit.backward-delete
              backward-delete-command
              "Delete the previous character.")
        (list 'edit.forward-delete
              forward-delete-command
              "Delete the next character.")
        (list 'edit.newline newline-command "Insert a newline.")
        (list 'move.backward-character
              backward-character-command
              "Move backward by one character.")
        (list 'move.forward-character
              forward-character-command
              "Move forward by one character.")
        (list 'move.previous-line previous-line-command "Move to the previous line.")
        (list 'move.next-line next-line-command "Move to the next line.")
        (list 'move.line-start line-start-command "Move to the start of the line.")
        (list 'move.line-end line-end-command "Move to the end of the line.")))
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
        (cons (stroke 'end #f 0) 'move.line-end))))

  (define (make-editor buffer)
    (unless (buffer? buffer)
      (assertion-violation 'make-editor "expected a buffer" buffer))
    (when (buffer-closed? buffer)
      (assertion-violation 'make-editor "buffer is closed" buffer))
    (let* ([view (%make-view 1 buffer 0 #f 0 1 1)]
           [editor
             (%make-editor
               (list buffer)
               view
               (make-command-registry)
               (make-keymap)
               '()
               #f
               #f)])
      (install-default-commands! editor)
      editor))

  (define (editor-close! editor)
    (when (and (editor? editor) (not (editor-closed? editor)))
      (for-each
        (lambda (buffer)
          (unless (buffer-closed? buffer)
            (buffer-close! buffer)))
        (editor-buffers editor))
      (editor-pending-keys-set! editor '())
      (editor-closed?-set! editor #t)))

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

  (define (condition->string condition)
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (write condition port)
        (extract))))

  (define (run-interactive-command editor name event)
    (guard (condition
             [else
              (editor-status-message-set!
                editor
                (condition->string condition))
              '()])
      (editor-status-message-set! editor #f)
      (editor-execute-command! editor name event #f)))

  (define (handle-key-message! editor event)
    (unless (key-event? event)
      (assertion-violation
        'editor-update!
        "key message payload must be a key event"
        event))
    (if (eq? (key-event-type event) 'release)
        '()
        (let* ([pending (editor-pending-keys editor)]
               [sequence
                 (append pending (list (key-event->key-stroke event)))])
          (call-with-values
            (lambda () (keymap-resolve (editor-keymap editor) sequence))
            (lambda (status command)
              (case status
                [(prefix)
                 (editor-pending-keys-set! editor sequence)
                 '()]
                [(command)
                 (editor-pending-keys-set! editor '())
                 (run-interactive-command editor command event)]
                [else
                 (editor-pending-keys-set! editor '())
                 (if (and (null? pending)
                          (positive?
                            (bytevector-length (key-event-text event))))
                     (run-interactive-command
                       editor
                       'edit.self-insert
                       event)
                     (begin
                       (when (pair? pending)
                         (editor-status-message-set!
                           editor
                           "Undefined key sequence"))
                       '()))]))))))

  (define (editor-update! editor message)
    (require-open-editor 'editor-update! editor)
    (unless (editor-message? message)
      (assertion-violation
        'editor-update!
        "expected an editor message"
        message))
    (case (editor-message-kind message)
      [(key) (handle-key-message! editor (editor-message-payload message))]
      [(resize)
       (let ([payload (editor-message-payload message)]
             [view (editor-active-view editor)])
         (unless (and (pair? payload)
                      (integer? (car payload))
                      (exact? (car payload))
                      (integer? (cdr payload))
                      (exact? (cdr payload))
                      (>= (car payload) 2)
                      (positive? (cdr payload)))
           (assertion-violation
             'editor-update!
             "resize payload must be a rows and columns pair"
             payload))
         (view-viewport-rows-set! view (- (car payload) 1))
         (view-viewport-columns-set! view (cdr payload))
         (ensure-view-visible! view)
         '())]
      [(command)
       (let ([payload (editor-message-payload message)])
         (unless (and (vector? payload) (= (vector-length payload) 2))
           (assertion-violation
             'editor-update!
             "command message payload must contain name and argument"
             payload))
         (editor-execute-command!
           editor
           (vector-ref payload 0)
           #f
           (vector-ref payload 1)))]
      [else
       (assertion-violation
         'editor-update!
         "unknown editor message kind"
         (editor-message-kind message))])))
