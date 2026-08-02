(library (soda editor comint)
  (export activate-interaction-view!
          comint-session-buffer
          comint-current-input
          comint-replace-input!
          comint-stash-current-input!
          comint-commit-input!
          comint-append-output!
          comint-insert-output!
          comint-insert-newline!
          comint-insert-newline-with-indent!
          comint-line-beginning-position
          comint-move-session-views-to-end!
          comint-history-previous-command
          comint-history-next-command
          comint-history-search-previous-prefix-command
          comint-history-search-next-prefix-command
          comint-history-search-previous-contains-command
          comint-history-search-next-contains-command
          comint-clear-input-command
          install-comint-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor display)
          (soda editor display-placement)
          (soda editor interaction)
          (soda editor interaction-transcript)
          (soda editor state))

  (define (activate-interaction-view! editor session keymap-layers)
    (let* ([buffer-id (interaction-session-buffer-id session)]
           [origin-view-id (view-id (editor-active-view editor))]
           [request
             (make-display-request
               buffer-id
               'tools
               origin-view-id
               #f
               (editor-view-resource-context
                 editor
                 origin-view-id))]
           [plan (editor-plan-display editor request)]
           [view
             (editor-display-buffer! editor request)])
      (unless (eq? (display-plan-action plan) 'reuse)
        (view-set-first-line! view 0)
        (view-set-first-column! view 0))
      (view-set-keymap-layers! view keymap-layers)
      (view-set-caret! view (buffer-byte-size (view-buffer view)))
      (ensure-view-visible! view)
      view))

  (define (comint-session-buffer editor session)
    (editor-buffer-ref
      editor
      (interaction-session-buffer-id session)))

  (define (comint-current-input editor session)
    (let ([buffer (comint-session-buffer editor session)])
      (interaction-transcript-current-input
        (interaction-session-transcript session)
        buffer)))

  (define (comint-move-session-views-to-end!
            editor
            session
            end)
    (for-each
      (lambda (view)
        (when
          (= (buffer-id (view-buffer view))
             (interaction-session-buffer-id session))
          (view-set-caret! view end)
          (ensure-view-visible! view)))
      (editor-views editor)))

  (define (comint-replace-input! editor session input)
    (let* ([buffer (comint-session-buffer editor session)]
           [end
             (interaction-transcript-replace-input!
               (interaction-session-transcript session)
               buffer
               input)])
      (comint-move-session-views-to-end!
        editor
        session
        end)
      input))

  (define (comint-stash-current-input! editor session)
    (interaction-transcript-stash-input!
      (interaction-session-transcript session)
      (comint-current-input editor session)))

  (define (comint-commit-input! editor session)
    (let ([end
            (interaction-transcript-commit-input!
              (interaction-session-transcript session)
              (comint-session-buffer editor session))])
      (comint-move-session-views-to-end!
        editor
        session
        end)
      end))

  (define (comint-append-output! editor session output)
    (let ([end
            (interaction-transcript-append-output!
              (interaction-session-transcript session)
              (comint-session-buffer editor session)
              output)])
      (comint-move-session-views-to-end!
        editor
        session
        end)
      end))

  (define (comint-insert-output!
            editor
            session
            output
            prompt-size)
    (let* ([buffer (comint-session-buffer editor session)]
           [start (interaction-session-input-start session)]
           [size
             (if
               (bytevector? output)
               (bytevector-length output)
               (bytevector-length (string->utf8 output)))]
           [views
             (filter
               (lambda (view)
                 (= (buffer-id (view-buffer view))
                    (interaction-session-buffer-id session)))
               (editor-views editor))]
           [carets (map view-caret views)]
           [end
             (interaction-transcript-insert-output!
               (interaction-session-transcript session)
               buffer
               output
               prompt-size)])
      (for-each
        (lambda (view caret)
          (when (>= caret start)
            (view-set-caret! view (+ caret size)))
          (ensure-view-visible! view))
        views
        carets)
      end))

  (define (comint-insert-newline-with-indent! view indentation)
    (unless
      (and
        (integer? indentation)
        (exact? indentation)
        (not (negative? indentation)))
      (assertion-violation
        'comint-insert-newline-with-indent!
        "indentation must be a non-negative exact integer"
        indentation))
    (let* ([buffer (view-buffer view)]
           [caret (view-caret view)]
           [bytes (make-bytevector (+ indentation 1) 32)]
           [change #f])
      (bytevector-u8-set! bytes 0 10)
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (transaction-insert!
                    transaction
                    caret
                    bytes))))
            (lambda (result committed-change)
              (set! change committed-change)
              (view-set-caret!
                view
                (+ caret (bytevector-length bytes)))
              (view-set-first-column! view 0)
              (ensure-view-visible! view))))
        (lambda ()
          (when change
            (change-close! change)))))
    '())

  (define (comint-insert-newline! view)
    (comint-insert-newline-with-indent! view 0))

  (define (active-interaction who context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [session
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))])
      (or
        session
        (assertion-violation
          who
          "active buffer is not an interaction transcript"
          (buffer-id buffer)))))

  (define (comint-history-previous-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (active-interaction
               'interaction.history-previous
               context)]
           [input
             (interaction-session-history-previous!
               session
               (comint-current-input editor session))])
      (when input
        (comint-replace-input! editor session input))
      '()))

  (define (comint-history-next-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (active-interaction
               'interaction.history-next
               context)]
           [input
             (interaction-session-history-next! session)])
      (when input
        (comint-replace-input! editor session input))
      '()))

  (define (comint-history-search-command context direction kind)
    (let* ([editor (command-context-editor context)]
           [session
             (active-interaction
               'interaction.history-search
               context)]
           [current-input (comint-current-input editor session)]
           [input
             (case direction
               [(previous)
                (interaction-session-history-search-previous!
                  session
                  current-input
                  kind)]
               [(next)
                (interaction-session-history-search-next!
                  session
                  current-input
                  kind)]
               [else
                (assertion-violation
                  'interaction.history-search
                  "unknown history search direction"
                  direction)])])
      (when input
        (comint-replace-input! editor session input))
      '()))

  (define (comint-history-search-previous-prefix-command context)
    (comint-history-search-command context 'previous 'prefix))

  (define (comint-history-search-next-prefix-command context)
    (comint-history-search-command context 'next 'prefix))

  (define (comint-history-search-previous-contains-command context)
    (comint-history-search-command context 'previous 'contains))

  (define (comint-history-search-next-contains-command context)
    (comint-history-search-command context 'next 'contains))

  (define (comint-entry-start-command context)
    (let* ([session
             (active-interaction
               'interaction.entry-start
               context)]
           [view (command-context-view context)])
      (view-set-caret!
        view
        (interaction-session-input-start session))
      '()))

  (define (comint-entry-end-command context)
    (let* ([session
             (active-interaction
               'interaction.entry-end
               context)]
           [view (command-context-view context)])
      (view-set-caret!
        view
        (buffer-byte-size (comint-session-buffer
                       (command-context-editor context)
                       session)))
      '()))

  (define (comint-line-beginning-position session buffer offset)
    (call-with-buffer-text
      buffer
      (lambda (text)
        (let* ([line
                 (car (text-position text offset))]
               [line-start (text-line-start text line)]
               [line-end (text-line-content-end text line)]
               [prompt
                 (find
                   (lambda (field)
                     (and
                       (eq? (interaction-field-kind field) 'prompt)
                       (<= line-start
                           (interaction-field-start field)
                           (interaction-field-end field)
                           line-end)))
                   (interaction-transcript-fields
                     (interaction-session-transcript session)
                     buffer))])
          (if prompt
              (interaction-field-end prompt)
              line-start)))))

  (define (comint-line-start-command context)
    (let* ([session
             (active-interaction
               'interaction.line-start
               context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)])
      (view-set-caret!
        view
        (if (command-context-prefix context)
            (call-with-buffer-text
              buffer
              (lambda (text)
                (text-line-start
                  text
                  (car
                    (text-position
                      text
                      (view-caret view))))))
            (comint-line-beginning-position
              session
              buffer
              (view-caret view))))
      '()))

  (define (comint-line-or-history-command context direction)
    (let* ([editor (command-context-editor context)]
           [session
             (active-interaction
               'interaction.line-or-history
               context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [move?
             (call-with-buffer-text
               buffer
               (lambda (text)
                 (let ([line
                         (car
                           (text-position text (view-caret view)))]
                       [input-line
                         (car
                           (text-position
                             text
                             (interaction-session-input-start session)))]
                       [end-line
                         (car
                           (text-position text (text-size text)))])
                   (case direction
                     [(previous) (> line input-line)]
                     [(next) (< line end-line)]
                     [else
                      (assertion-violation
                        'interaction.line-or-history
                        "unknown line movement direction"
                        direction)]))))])
      (if move?
          (editor-execute-command!
            editor
            (if
              (eq? direction 'previous)
              'move.previous-line
              'move.next-line)
            (command-context-event context)
            #f
            (command-context-prefix context))
          (if
            (eq? direction 'previous)
            (comint-history-previous-command context)
            (comint-history-next-command context)))))

  (define (comint-previous-line-or-history-command context)
    (comint-line-or-history-command context 'previous))

  (define (comint-next-line-or-history-command context)
    (comint-line-or-history-command context 'next))

  (define (comint-clear-input-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (active-interaction
               'interaction.clear-input
               context)])
      (comint-replace-input! editor session "")
      (interaction-session-reset-history-navigation! session)
      '()))

  (define (install-comint-commands! editor)
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
          'interaction.history-previous
          comint-history-previous-command
          "Replace interaction input with the previous history entry.")
        (list
          'interaction.history-next
          comint-history-next-command
          "Replace interaction input with the next history entry.")
        (list
          'interaction.history-previous-prefix
          comint-history-search-previous-prefix-command
          "Search backward for interaction input with the same prefix.")
        (list
          'interaction.history-next-prefix
          comint-history-search-next-prefix-command
          "Search forward for interaction input with the same prefix.")
        (list
          'interaction.history-previous-contains
          comint-history-search-previous-contains-command
          "Search backward for interaction input containing the entry.")
        (list
          'interaction.history-next-contains
          comint-history-search-next-contains-command
          "Search forward for interaction input containing the entry.")
        (list
          'interaction.entry-start
          comint-entry-start-command
          "Move to the start of the editable interaction entry.")
        (list
          'interaction.entry-end
          comint-entry-end-command
          "Move to the end of the editable interaction entry.")
        (list
          'interaction.line-start
          comint-line-start-command
          "Move to the line start without crossing the interaction prompt.")
        (list
          'interaction.previous-line-or-history
          comint-previous-line-or-history-command
          "Move up in the entry or to the previous history entry.")
        (list
          'interaction.next-line-or-history
          comint-next-line-or-history-command
          "Move down in the entry or to the next history entry.")
        (list
          'interaction.clear-input
          comint-clear-input-command
          "Clear the editable input in an interaction transcript.")))
    editor))
