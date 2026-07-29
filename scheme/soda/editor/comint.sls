(library (soda editor comint)
  (export activate-interaction-view!
          comint-session-buffer
          comint-current-input
          comint-replace-input!
          comint-stash-current-input!
          comint-commit-input!
          comint-append-output!
          comint-insert-newline!
          comint-move-session-views-to-end!
          comint-history-previous-command
          comint-history-next-command
          comint-clear-input-command
          install-comint-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor display)
          (soda editor interaction)
          (soda editor interaction-transcript)
          (soda editor state))

  (define (buffer-size buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (view-for-buffer editor target-buffer-id)
    (find
      (lambda (view)
        (= (buffer-id (view-buffer view)) target-buffer-id))
      (editor-views editor)))

  (define (buffer-end-viewport-minimum buffer)
    (let ([snapshot
            (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([end (text-size text)]
                       [position (text-position text end)]
                       [tab-width
                         (let ([setting
                                 (buffer-setting-ref
                                   buffer
                                   'tab-width
                                   8)])
                           (if
                             (and
                               (integer? setting)
                               (exact? setting)
                               (positive? setting))
                             setting
                             8))])
                  (cons
                    (+ (car position) 1)
                    (+ (text-cell-column text end tab-width) 1))))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (activate-interaction-view! editor session keymap-layers)
    (let* ([buffer-id (interaction-session-buffer-id session)]
           [existing (view-for-buffer editor buffer-id)]
           [reference (editor-base-view editor)]
           [view
             (or
               existing
               (editor-open-view! editor buffer-id))])
      (unless existing
        (let ([minimum
                (buffer-end-viewport-minimum
                  (view-buffer view))])
          (view-set-viewport!
            view
            (max
              (view-viewport-rows reference)
              (car minimum))
            (max
              (view-viewport-columns reference)
              (cdr minimum))))
        (view-set-first-line! view 0)
        (view-set-first-column! view 0))
      (view-set-keymap-layers! view keymap-layers)
      (view-set-caret! view (buffer-size (view-buffer view)))
      (ensure-view-visible! view)
      (editor-set-active-view! editor (view-id view))
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

  (define (comint-insert-newline! view)
    (let* ([buffer (view-buffer view)]
           [caret (view-caret view)]
           [change #f])
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
                    (make-bytevector 1 10)))))
            (lambda (result committed-change)
              (set! change committed-change)
              (view-set-caret! view (+ caret 1))
              (ensure-view-visible! view))))
        (lambda ()
          (when change
            (change-close! change)))))
    '())

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
          (car entry)
          (cadr entry)
          (caddr entry)))
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
          'interaction.clear-input
          comint-clear-input-command
          "Clear the editable input in an interaction transcript.")))
    editor))
