(library (soda editor dashboard)
  (export install-dashboard!
          dashboard-definition
          dashboard-model?
          dashboard-model-entries
          dashboard-model-workbench-id
          dashboard-view-selection
          dashboard-entry?
          dashboard-entry-buffer-id
          dashboard-entry-label
          dashboard-entry-mode
          dashboard-entry-modified?)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor display-placement)
          (soda editor keymap)
          (soda editor language)
          (soda editor project-target)
          (soda editor state)
          (soda editor tui-application)
          (soda editor tui-state)
          (soda editor tui-application-runtime)
          (soda editor workbench)
          (soda tui application))

  (define-record-type dashboard-entry
    (fields buffer-id label mode modified?))

  (define-record-type dashboard-model
    (fields entries workbench-id))

  (define (buffer-label buffer)
    (or (buffer-resource buffer)
        (string-append "*buffer-" (number->string (buffer-id buffer)) "*")))

  (define (editor-buffer-entries editor own-buffer-id)
    (map
      (lambda (buffer)
        (make-dashboard-entry
          (buffer-id buffer)
          (buffer-label buffer)
          (buffer-major-mode-name buffer)
          (buffer-modified? buffer)))
      (filter
        (lambda (buffer) (not (= (buffer-id buffer) own-buffer-id)))
        (editor-buffers editor))))

  (define (dashboard-view-selection model state)
    (let* ([entries (dashboard-model-entries model)]
           [selected-id
             (and state (tui-view-state-transient-state state))])
      (if
        (null? entries)
        #f
        (let loop ([remaining entries] [index 0])
          (cond
            [(null? remaining) 0]
            [(and selected-id
                  (= selected-id
                     (dashboard-entry-buffer-id (car remaining))))
             index]
            [else (loop (cdr remaining) (+ index 1))])))))

  (define (selected-entry model state)
    (let ([selection
            (dashboard-view-selection
              model state)])
      (and selection
           (list-ref (dashboard-model-entries model) selection))))

  (define (visible-row-count context)
    (let ([state (tui-application-context-view-state context)])
      (max 1 (- (if state (tui-view-state-height state) 10) 1))))

  (define (move-selection model delta context)
    (let* ([entries (dashboard-model-entries model)]
           [count (length entries)])
      (if (zero? count)
          (tui-result model '() '())
          (let* ([state (tui-application-context-view-state context)]
                 [current (or (dashboard-view-selection model state) 0)]
                 [selection (mod (+ current delta) count)]
                 [rows (visible-row-count context)]
                 [old-viewport
                   (if state
                       (car (tui-view-state-viewport state))
                       0)]
                 [viewport
                   (cond
                     [(< selection old-viewport) selection]
                     [(>= selection (+ old-viewport rows))
                      (+ 1 (- selection rows))]
                     [else old-viewport])]
                 [selected-id
                   (dashboard-entry-buffer-id
                     (list-ref entries selection))])
            (tui-result
              model
              '()
              (list
                (make-tui-view-action
                  'origin 'transient selected-id)
                (make-tui-view-action
                  'origin 'scroll (cons viewport 0))))))))

  (define (refresh-model model context)
    (let* ([editor (tui-application-context-editor context)]
           [own-buffer-id (tui-application-context-buffer-id context)]
           [entries (editor-buffer-entries editor own-buffer-id)])
      (make-dashboard-model
        entries
        (dashboard-model-workbench-id model))))

  (define (context-workbench-id context arguments)
    (if
      (and (integer? arguments) (exact? arguments) (positive? arguments))
      arguments
      (let* ([editor (tui-application-context-editor context)]
             [origin-id (tui-application-context-view-id context)]
             [workbench
               (and origin-id
                    (editor-workbench-for-view editor origin-id))])
        (workbench-id
          (or workbench (editor-active-workbench editor))))))

  (define (entry-row entry)
    (string-append
      (if (dashboard-entry-modified? entry) "* " "  ")
      (dashboard-entry-label entry)
      "  [" (symbol->string (dashboard-entry-mode entry)) "]"))

  (define dashboard-definition
    (make-tui-application-definition
      'dashboard
      (lambda (context arguments)
        (values
          (make-dashboard-model
            (editor-buffer-entries
              (tui-application-context-editor context)
              (tui-application-context-buffer-id context))
            (context-workbench-id context arguments))
          '()))
      (lambda (model message context)
        (case (tui-message-payload message)
          [(next) (move-selection model 1 context)]
          [(previous) (move-selection model -1 context)]
          [(refresh) (tui-result (refresh-model model context) '() '())]
          [else (tui-result model '() '())]))
      (lambda (model context)
        (let* ([state (tui-application-context-view-state context)]
               [selection (dashboard-view-selection model state)]
               [viewport
                 (if state (tui-view-state-viewport state) (cons 0 0))])
          (tui-column
            'dashboard.root
            (list
            (tui-node-with-layout
              (tui-text 'dashboard.title "Buffers" '(application.heading))
              (make-tui-layout (tui-flex 1) (tui-fixed 1)))
            (tui-node-with-layout
              (tui-scroll
                'dashboard.viewport
                (tui-list
                  'dashboard.buffers
                  (map entry-row (dashboard-model-entries model))
                  selection)
                viewport)
              (make-tui-layout (tui-flex 1) (tui-flex 1)))))))
      #f
      (lambda (model context)
        (apply string-append
          (map
            (lambda (entry) (string-append (entry-row entry) "\n"))
            (dashboard-model-entries model))))
      'dashboard-mode
      'edit
      '()))

  (define (active-dashboard-session editor)
    (let ([session (tui-active-session editor)])
      (and session
           (eq? (tui-application-definition-name
                  (tui-session-definition session))
                'dashboard)
           session)))

  (define (dashboard-session? session)
    (eq? (tui-application-definition-name
           (tui-session-definition session))
         'dashboard))

  (define (refresh-dashboard-sessions! editor)
    (for-each
      (lambda (session)
        (when (dashboard-session? session)
          (tui-send! editor (tui-session-id session) 'refresh)))
      (editor-tui-sessions editor)))

  (define (close-workbench-dashboard! editor workbench)
    (let ([session
            (find
              (lambda (candidate)
                (and
                  (dashboard-session? candidate)
                  (equal?
                    (tui-session-arguments candidate)
                    (workbench-id workbench))))
              (editor-tui-sessions editor))])
      (when session
        (tui-close! editor (tui-session-id session)))))

  (define (send-dashboard! context payload)
    (let* ([editor (command-context-editor context)]
           [session (active-dashboard-session editor)])
      (when session
        (tui-send! editor (tui-session-id session) payload
                   (view-id (command-context-view context))))
      '()))

  (define (open-dashboard-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [workbench
             (editor-workbench-for-view editor (view-id view))]
           [workbench-id (workbench-id workbench)]
           [existing
             (find
               (lambda (session)
                 (and
                   (eq? (tui-application-definition-name
                          (tui-session-definition session))
                        'dashboard)
                   (equal? (tui-session-arguments session) workbench-id)))
               (editor-tui-sessions editor))])
      (if existing
          (let ([buffer
                  (editor-buffer-ref
                    editor (tui-session-buffer-id existing))])
            (editor-display-buffer!
              editor
              (make-display-request
                (buffer-id buffer)
                'edit
                (view-id view)
                #f
                (buffer-creation-context buffer))))
          (let ([target
                  (editor-project-target editor view 'workspace)])
            (if target
                (tui-open!
                  editor 'dashboard workbench-id 'edit
                  (view-id view)
                  (project-target-resource-context target))
                (tui-open!
                  editor 'dashboard workbench-id 'edit
                  (view-id view)))))
      (send-dashboard! context 'refresh)))

  (define (visit-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [session (active-dashboard-session editor)]
           [entry
             (and
               session
               (selected-entry
                 (tui-session-model session)
                 (tui-session-view-state
                   session
                   (view-id (command-context-view context)))))])
      (when entry
        (let ([buffer
                (find
                  (lambda (candidate)
                    (= (buffer-id candidate)
                       (dashboard-entry-buffer-id entry)))
                  (editor-buffers editor))])
          (if buffer
              (editor-set-view-buffer!
                editor
                (view-id (command-context-view context))
                (buffer-id buffer))
              (begin
                (editor-set-status-message!
                  editor "Dashboard entry is no longer available")
                (send-dashboard! context 'refresh)))))
      '()))

  (define (bind-key! keymap key codepoint modifiers command)
    (keymap-bind!
      keymap
      (list (make-key-stroke key codepoint modifiers))
      command))

  (define (install-dashboard! editor)
    (editor-register-tui-application! editor dashboard-definition)
    (editor-add-hook!
      editor
      'buffer-registry-changed
      'dashboard.refresh
      (lambda (changed-editor buffer reason generation)
        (refresh-dashboard-sessions! changed-editor)))
    (editor-add-hook!
      editor
      'workbench-before-close
      'dashboard.close-with-workbench
      close-workbench-dashboard!)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'dashboard-mode 'fundamental-mode #f 'interface
        'dashboard-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-key! keymap 'down #f 0 'dashboard.next)
      (bind-key! keymap 'up #f 0 'dashboard.previous)
      (bind-key! keymap 'enter 13 0 'dashboard.visit-buffer)
      (for-each
        (lambda (entry)
          (bind-key! keymap 'character
                     (char->integer (car entry)) 0 (cdr entry)))
        '((#\n . dashboard.next)
          (#\p . dashboard.previous)
          (#\j . dashboard.next)
          (#\k . dashboard.previous)
          (#\g . dashboard.refresh)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'dashboard-mode-map keymap))
    (for-each
      (lambda (spec)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car spec) (cadr spec) (caddr spec))))
      (list
        (list 'dashboard.open open-dashboard-command
              "Open the workspace dashboard.")
        (list 'dashboard.next
              (lambda (context) (send-dashboard! context 'next))
              "Select the next dashboard item.")
        (list 'dashboard.previous
              (lambda (context) (send-dashboard! context 'previous))
              "Select the previous dashboard item.")
        (list 'dashboard.refresh
              (lambda (context) (send-dashboard! context 'refresh))
              "Refresh dashboard data.")
        (list 'dashboard.visit-buffer visit-buffer-command
              "Display the selected dashboard buffer.")))
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\b) 4))
      'dashboard.open)
    editor))
