(library (soda editor dashboard)
  (export install-dashboard!
          dashboard-definition
          dashboard-model?
          dashboard-model-entries
          dashboard-model-selection
          dashboard-entry?
          dashboard-entry-buffer-id
          dashboard-entry-label
          dashboard-entry-mode
          dashboard-entry-modified?)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor keymap)
          (soda editor language)
          (soda editor state)
          (soda editor tui-application)
          (soda editor tui-application-runtime)
          (soda tui application))

  (define-record-type dashboard-entry
    (fields buffer-id label mode modified?))

  (define-record-type dashboard-model
    (fields entries selection viewport))

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

  (define (selected-entry model)
    (and (pair? (dashboard-model-entries model))
         (list-ref
           (dashboard-model-entries model)
           (dashboard-model-selection model))))

  (define (visible-row-count context)
    (let ([state (tui-application-context-view-state context)])
      (max 1 (- (if state (tui-view-state-height state) 10) 1))))

  (define (move-selection model delta context)
    (let* ([entries (dashboard-model-entries model)]
           [count (length entries)])
      (if (zero? count)
          model
          (let* ([selection
                   (mod (+ (dashboard-model-selection model) delta) count)]
                 [rows (visible-row-count context)]
                 [old-viewport (dashboard-model-viewport model)]
                 [viewport
                   (cond
                     [(< selection old-viewport) selection]
                     [(>= selection (+ old-viewport rows))
                      (+ 1 (- selection rows))]
                     [else old-viewport])])
            (make-dashboard-model entries selection viewport)))))

  (define (refresh-model model context)
    (let* ([editor (tui-application-context-editor context)]
           [own-buffer-id (tui-application-context-buffer-id context)]
           [selected (selected-entry model)]
           [selected-id (and selected (dashboard-entry-buffer-id selected))]
           [entries (editor-buffer-entries editor own-buffer-id)]
           [selection
             (let loop ([remaining entries] [index 0])
               (cond
                 [(null? remaining) 0]
                 [(and selected-id
                       (= selected-id
                          (dashboard-entry-buffer-id (car remaining))))
                  index]
                 [else (loop (cdr remaining) (+ index 1))]))])
      (make-dashboard-model
        entries selection
        (min selection (dashboard-model-viewport model)))))

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
            0 0)
          '()))
      (lambda (model message context)
        (case (tui-message-payload message)
          [(next) (tui-result (move-selection model 1 context) '() '())]
          [(previous) (tui-result (move-selection model -1 context) '() '())]
          [(refresh) (tui-result (refresh-model model context) '() '())]
          [else (tui-result model '() '())]))
      (lambda (model context)
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
                  (and (pair? (dashboard-model-entries model))
                       (dashboard-model-selection model)))
                (cons (dashboard-model-viewport model) 0))
              (make-tui-layout (tui-flex 1) (tui-flex 1))))))
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

  (define (send-dashboard! context payload)
    (let* ([editor (command-context-editor context)]
           [session (active-dashboard-session editor)])
      (when session
        (tui-send! editor (tui-session-id session) payload
                   (view-id (command-context-view context))))
      '()))

  (define (open-dashboard-command context)
    (let* ([editor (command-context-editor context)]
           [existing
             (find
               (lambda (session)
                 (eq? (tui-application-definition-name
                        (tui-session-definition session))
                      'dashboard))
               (editor-tui-sessions editor))])
      (if existing
          (editor-set-view-buffer!
            editor
            (view-id (command-context-view context))
            (tui-session-buffer-id existing))
          (tui-open! editor 'dashboard #f 'edit
                     (view-id (command-context-view context))))
      (send-dashboard! context 'refresh)))

  (define (visit-buffer-command context)
    (let* ([editor (command-context-editor context)]
           [session (active-dashboard-session editor)]
           [entry (and session (selected-entry (tui-session-model session)))])
      (when entry
        (editor-set-view-buffer!
          editor
          (view-id (command-context-view context))
          (dashboard-entry-buffer-id entry)))
      '()))

  (define (bind-key! keymap key codepoint modifiers command)
    (keymap-bind!
      keymap
      (list (make-key-stroke key codepoint modifiers))
      command))

  (define (install-dashboard! editor)
    (editor-register-tui-application! editor dashboard-definition)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'dashboard-mode 'fundamental-mode #f 'interface
        'dashboard-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-key! keymap 'down #f 0 'dashboard.next)
      (bind-key! keymap 'up #f 0 'dashboard.previous)
      (bind-key! keymap 'enter #f 0 'dashboard.visit-buffer)
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
