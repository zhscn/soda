(library (soda editor tui-application-commands)
  (export install-tui-application-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor keymap)
          (soda editor state)
          (soda editor tui-application)
          (soda tui application))

  (define (active-application-state context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [session
             (editor-tui-session-for-buffer
               editor
               (buffer-id (view-buffer view)))])
      (and
        session
        (cons
          session
          (tui-session-ensure-view-state! session (view-id view))))))

  (define (entry-index entries key)
    (let loop ([remaining entries] [index 0])
      (cond
        [(null? remaining) #f]
        [(equal? key (tui-focus-entry-node-key (car remaining))) index]
        [else (loop (cdr remaining) (+ index 1))])))

  (define (move-focus! context delta)
    (let ([target (active-application-state context)])
      (when target
        (let* ([state (cdr target)]
               [entries
                 (filter
                   tui-focus-entry-enabled?
                   (tui-view-state-focus-ring state))]
               [count (length entries)])
          (when (positive? count)
            (let* ([index
                     (entry-index
                       entries
                       (tui-view-state-focused-node state))]
                   [next
                     (if index
                         (mod (+ index delta) count)
                         (if (negative? delta) (- count 1) 0))])
              (tui-view-state-set-focused-node!
                state
                (tui-focus-entry-node-key (list-ref entries next)))
              (editor-invalidate!
                (command-context-editor context)
                'application)))))
      '()))

  (define (install-tui-application-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'tui.focus-next
        (lambda (context) (move-focus! context 1))
        "Move to the next focusable application component."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'tui.focus-previous
        (lambda (context) (move-focus! context -1))
        "Move to the previous focusable application component."))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'tab 9 0))
        'tui.focus-next)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'tab 9 1))
        'tui.focus-previous)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'tui.application
        keymap))
    editor))
