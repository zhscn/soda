(library (soda test fundamental-editing)
  (export run-fundamental-editing-tests!)
  (import (rnrs)
          (soda bootstrap)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host render-service)
          (soda host value)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base fundamental-editing)
          (soda packages base history)
          (soda packages base text-motion)
          (soda tui frontend)
          (soda view frame)
          (soda view text-layout)
          (soda view theme))

  (define (application-command-context application)
    (let* ([state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [view (soda-application-view application)]
           [buffer (soda-application-buffer application)]
           [active (surface-active-context surface (host-state-views state))])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state view)
        #f '() #f active 'fundamental-test)))

  (define (buffer-string buffer)
    (snapshot-string (buffer-state-document (buffer-state buffer))))

  (define (run-fundamental-editing-tests!)
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [editing (soda-application-editing application)]
           [inserted
            (command-runtime-start!
              runtime 'fundamental.insert-text (application-command-context application)
              (list (string->utf8 "a😀")))]
           [backward
            (command-runtime-start!
              runtime 'fundamental.backward-char (application-command-context application))]
           [deleted
            (command-runtime-start!
              runtime 'fundamental.delete-forward (application-command-context application))]
           [context
            (fundamental-input-context
              editing
              (surface-active-context (soda-application-surface application)
                                      (host-state-views state))
              view)]
           [disposition
            (fundamental-input-disposition
              (application-command-context application)
              (input-dispatch context (make-text-input-event 'text (string->utf8 "b"))))]
           [enter
            (input-dispatch
              context (make-key-event 'enter 13 #f #f 0 'press (make-bytevector 0)))]
           [backspace
            (input-dispatch
              context (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0)))])
      (unless (and (eq? (command-invocation-phase inserted) 'completed)
                   (eq? (command-invocation-phase backward) 'completed)
                   (eq? (command-invocation-phase deleted) 'completed)
                   (string=? (buffer-string buffer) "a")
                   (= (selection-range-from
                        (selection-primary-range (view-state-selection (view-state view))))
                      1)
                   (= (input-context-view-id context) (view-id view))
                   (= (input-context-buffer-id context) (buffer-id buffer))
                   (command-invoke-message? disposition)
                   (eq? (command-invoke-message-name disposition)
                        'fundamental.insert-text)
                   (eq? (input-disposition-kind enter) 'command)
                   (eq? (input-disposition-value enter) 'fundamental.newline)
                   (eq? (input-disposition-kind backspace) 'command)
                   (eq? (input-disposition-value backspace)
                        'fundamental.delete-backward))
        (error 'fundamental-editing-tests
               "fundamental editing did not produce stable editor state"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [history (soda-application-history application)])
      (unless (not (history-modified? history (buffer-id buffer)))
        (error 'fundamental-editing-tests "fresh Buffer should begin at its History save point"))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "history")))
      (unless (history-modified? history (buffer-id buffer))
        (error 'fundamental-editing-tests "editing did not advance History past its save point"))
      (command-runtime-start! runtime 'history.undo (application-command-context application))
      (unless (string=? (buffer-string buffer) "")
        (error 'fundamental-editing-tests "history.undo did not replay the inverse change"))
      (unless (not (history-modified? history (buffer-id buffer)))
        (error 'fundamental-editing-tests "undo did not return to the History save point"))
      (command-runtime-start! runtime 'history.redo (application-command-context application))
      (unless (string=? (buffer-string buffer) "history")
        (error 'fundamental-editing-tests "history.redo did not replay the original change"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "alpha beta")))
      (command-runtime-start!
        runtime 'fundamental.set-mark (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.backward-word (application-command-context application))
      (let ([region (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-anchor region) 10)
                     (= (selection-range-head region) 6))
          (error 'fundamental-editing-tests
                 "set-mark and motion did not form the expected region")))
      (command-runtime-start!
        runtime 'fundamental.kill-region (application-command-context application))
      (unless (and (string=? (buffer-string buffer) "alpha ")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      6))
        (error 'fundamental-editing-tests
               "kill-region did not delete the primary active region"))
      (command-runtime-start!
        runtime 'fundamental.yank (application-command-context application))
      (unless (string=? (buffer-string buffer) "alpha beta")
        (error 'fundamental-editing-tests
               "yank did not restore the newest kill-ring entry"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "abc\ndef")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-line (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.open-line (application-command-context application))
      (unless (and (string=? (buffer-string buffer) "abc\n\ndef")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      4))
        (error 'fundamental-editing-tests "open-line did not preserve point"))
      (command-runtime-start!
        runtime 'fundamental.kill-line (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.kill-word (application-command-context application))
      (unless (string=? (buffer-string buffer) "abc\n")
        (error 'fundamental-editing-tests "line and word kill did not use text boundaries"))
      (command-runtime-start!
        runtime 'fundamental.mark-whole-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.exchange-point-and-mark (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-anchor range) 4)
                     (= (selection-range-head range) 0))
          (error 'fundamental-editing-tests "mark-whole-buffer or point exchange is incorrect")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "ab\n1234\nz")))
      (command-runtime-start!
        runtime 'fundamental.previous-line (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.forward-char (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.transpose-characters (application-command-context application))
      (unless (string=? (buffer-string buffer) "ab\n1324\nz")
        (error 'fundamental-editing-tests "transpose-characters did not preserve grapheme ranges"))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.end-of-buffer (application-command-context application))
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 9)
        (error 'fundamental-editing-tests "Buffer boundary motion is incorrect"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [view (soda-application-view application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11")))
      (command-runtime-start!
        runtime 'fundamental.scroll-down (application-command-context application))
      (unless (= (viewport-first-line (view-state-viewport (view-state view))) 10)
        (error 'fundamental-editing-tests "scroll-down did not advance the Viewport"))
      (command-runtime-start!
        runtime 'fundamental.scroll-up (application-command-context application))
      (unless (= (viewport-first-line (view-state-viewport (view-state view))) 0)
        (error 'fundamental-editing-tests "scroll-up did not restore the Viewport"))
      (soda-application-close! application))

    (let* ([document (make-document "a\n")]
           [snapshot (document-snapshot document)]
           [selection (make-selection (list (make-selection-range 2 2)))]
           [layout (layout-text-snapshot snapshot selection 0 20 3)])
      (unless (and (= (text-layout-cursor-row layout) 1)
                   (= (text-layout-cursor-column layout) 0))
        (error 'fundamental-editing-tests
               "trailing newline caret did not remain on its empty line"))
      (snapshot-close! snapshot)
      (document-close! document))

    (let ([text (string->text "alpha _β gamma\nline")])
      (unless (and (= (text-forward-word-offset text 0) 5)
                   (= (text-forward-word-offset text 5) 9)
                   (= (text-forward-word-offset text 9) 15)
                   (= (text-backward-word-offset text 15) 10)
                   (= (text-backward-word-offset text 10) 6)
                   (= (text-line-start-offset text 18) 16)
                   (= (text-line-end-offset text 18) 20))
        (error 'fundamental-editing-tests
               "Unicode word or logical-line motion differs"))
      (text-close! text))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [_insert
            (command-runtime-start!
              runtime 'fundamental.insert-text (application-command-context application)
              (list (string->utf8 "alpha _β gamma\nline")))]
           [backward-word
            (command-runtime-start!
              runtime 'fundamental.backward-word (application-command-context application))]
           [line-start
            (command-runtime-start!
              runtime 'fundamental.beginning-of-line
              (application-command-context application))]
           [line-end
            (command-runtime-start!
              runtime 'fundamental.end-of-line (application-command-context application))])
      (unless (and (eq? (command-invocation-phase backward-word) 'completed)
                   (eq? (command-invocation-phase line-start) 'completed)
                   (eq? (command-invocation-phase line-end) 'completed)
                   (string=? (buffer-string buffer) "alpha _β gamma\nline")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      20))
        (error 'fundamental-editing-tests
               "fundamental word and line commands did not publish View state"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [view (soda-application-view application)]
           [buffer (soda-application-buffer application)]
           [editing (soda-application-editing application)]
           [frontend
            (make-frontend
              state surface
              (lambda (active current-view)
                (fundamental-input-context editing active current-view))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme) #f)
              (make-render-service) default-theme)])
      (define (send! event)
        (frontend-enqueue!
          frontend (make-surface-input-message (surface-id surface) event))
        (frontend-step! frontend))
      (send! (make-text-input-event 'text (string->utf8 "a")))
      (send! (make-key-event 'enter 13 #f #f 0 'press (make-bytevector 0)))
      (send! (make-text-input-event 'text (string->utf8 "b")))
      (send! (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0)))
      (unless (and (string=? (buffer-string buffer) "a\n")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      2))
        (error 'fundamental-editing-tests
               "fundamental frontend input did not advance its caret"))
      (frontend-close! frontend)
      (soda-application-close! application))))
