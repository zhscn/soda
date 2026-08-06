(library (soda test fundamental-editing)
  (export run-fundamental-editing-tests!)
  (import (rnrs)
          (only (chezscheme) chmod delete-directory get-mode get-process-id mkdir)
          (soda bootstrap)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal operation)
          (soda host render)
          (soda host internal view)
          (soda host render-service)
          (soda host value)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base fundamental-editing)
          (soda packages base editing-options)
          (soda packages base history)
          (soda packages base text-motion)
          (soda packages completion)
          (soda packages file)
          (soda packages directory)
          (soda packages editor-options)
          (soda packages buffer-ui)
          (soda packages buffer-list)
          (soda packages search)
          (soda packages message)
          (soda packages interaction)
          (soda packages minibuffer)
          (soda packages resource)
          (soda support vfs)
          (soda tui frontend)
          (soda view decoration)
          (soda view display)
          (soda view frame)
          (soda view projection)
          (soda view text-layout)
          (soda view theme))

  (define application-command-context
    (case-lambda
      [(application) (application-command-context application #f)]
      [(application layout)
       (let* ([state (soda-application-state application)]
              [surface (soda-application-surface application)]
              [active (surface-active-context surface (host-state-views state))]
              [view (view-service-ref (host-state-views state)
                                      (active-context-view-id active))]
              [buffer (buffer-service-ref (host-state-buffers state)
                                          (active-context-buffer-id active))])
         (make-command-context
           #f
           (active-context-surface-id active)
           (active-context-window-id active)
           (view-id view)
           (buffer-id buffer)
           (buffer-state buffer)
           (view-state view)
           #f '() #f active 'fundamental-test layout))]))

  (define (buffer-string buffer)
    (snapshot-string (buffer-state-document (buffer-state buffer))))

  (define (string-contains? value needle)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and (<= index limit)
             (or (string=? (substring value index (+ index (string-length needle))) needle)
                 (loop (+ index 1)))))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (run-fundamental-editing-tests!)
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [surface (soda-application-surface application)]
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
              context (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0)))]
           [undo
            (input-dispatch
              context (make-key-event 'character (char->integer #\u) #f #f 2 'press
                                      (make-bytevector 0)))]
           [redo
            (input-dispatch
              context (make-key-event 'character (char->integer #\e) #f #f 2 'press
                                      (make-bytevector 0)))]
           [uncut
            (input-dispatch
              context (make-key-event 'character (char->integer #\u) #f #f 4 'press
                                      (make-bytevector 0)))]
           [cut-text
            (input-dispatch
              context (make-key-event 'character (char->integer #\k) #f #f 4 'press
                                      (make-bytevector 0)))]
           [justify
            (input-dispatch
              context (make-key-event 'character (char->integer #\j) #f #f 4 'press
                                      (make-bytevector 0)))]
           [set-mark
            (input-dispatch
              context (make-key-event 'character (char->integer #\6) #f #f 4 'press
                                      (make-bytevector 0)))]
           [before-surface-generation (surface-generation surface)]
           [redraw
            (command-runtime-start!
              runtime 'fundamental.redraw (application-command-context application))]
           [file-map (file-keymap (soda-application-files application))])
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
                        'fundamental.delete-backward)
                   (eq? (input-disposition-value undo) 'history.undo)
                   (eq? (input-disposition-value redo) 'history.redo)
                   (eq? (input-disposition-value uncut) 'fundamental.yank)
                   (eq? (input-disposition-value cut-text) 'fundamental.cut-text)
                   (eq? (input-disposition-value justify) 'fundamental.fill-paragraph)
                   (eq? (input-disposition-value set-mark) 'fundamental.set-mark)
                   (eq? (command-invocation-phase redraw) 'completed)
                   (= (surface-generation surface) (+ before-surface-generation 1))
                   (eq? (keymap-lookup
                          (fundamental-editing-keymap editing)
                          (list (make-key-stroke 'character (char->integer #\l) 4)))
                        'fundamental.redraw)
                   (eq? (keymap-lookup
                          file-map
                          (list (make-key-stroke 'character (char->integer #\o) 4)))
                         'file.save)
                   (eq? (keymap-lookup
                          file-map
                          (list (make-key-stroke 'character (char->integer #\r) 2)))
                         'file.revert))
        (error 'fundamental-editing-tests
               "fundamental editing did not produce stable editor state"))
      (soda-application-close! application))

    ;; A directory is a generated Buffer: item activation queues the next
    ;; ordinary file/directory command instead of giving the browser a custom
    ;; event loop.  Refresh republishes the same Buffer projection.
    (let* ([root (string-append "/tmp/soda-directory-browser-"
                                (number->string (get-process-id)))]
           [nested (string-append root "/nested")]
           [note (string-append root "/note.txt")]
           [new-note (string-append root "/new.txt")]
           [application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)])
      (dynamic-wind
        (lambda ()
          (mkdir root)
          (mkdir nested)
          (vfs-write-file note (string->utf8 "note")))
        (lambda ()
          (let ([opened
                 (command-runtime-start!
                   runtime 'directory.browse (application-command-context application)
                   (list root))])
            (unless (eq? (command-invocation-phase opened) 'completed)
              (error 'fundamental-editing-tests "directory browse command did not complete")))
          (let* ([surface (soda-application-surface application)]
                 [active (surface-active-context surface (host-state-views state))]
                 [browser-view
                  (view-service-ref (host-state-views state) (active-context-view-id active))]
                 [browser (view-buffer browser-view)]
                 [content (buffer-string browser)])
            (unless (and (string-contains? content "Directory: ")
                         (string-contains? content "nested/")
                         (string-contains? content "note.txt")
                         (string=?
                           (directory-service-path
                             (soda-application-directories application) (buffer-id browser))
                           (vfs-directory-path root)))
              (error 'fundamental-editing-tests "directory Buffer projection differs" content))
            ;; Header is not an item.  The first two item motions reach the
            ;; parent entry and then the known child directory.
            (command-runtime-start! runtime 'buffer.next-item
                                    (application-command-context application))
            (command-runtime-start! runtime 'buffer.next-item
                                    (application-command-context application))
            (command-runtime-start! runtime 'buffer.activate-item
                                    (application-command-context application))
            (host-state-run! state)
            (let* ([nested-active
                    (surface-active-context surface (host-state-views state))]
                   [nested-buffer
                    (buffer-service-ref (host-state-buffers state)
                                        (active-context-buffer-id nested-active))])
              (unless (string=?
                        (directory-service-path
                          (soda-application-directories application) (buffer-id nested-buffer))
                        (vfs-directory-path nested))
                (error 'fundamental-editing-tests "directory item did not open child directory")))
            ;; Return to the root Buffer through its ordinary stable key, add
            ;; an entry, and refresh its generated projection in place.
            (command-runtime-start! runtime 'directory.browse
                                    (application-command-context application) (list root))
            (vfs-write-file new-note (string->utf8 "new"))
            (command-runtime-start! runtime 'directory.refresh
                                    (application-command-context application))
            (let* ([refreshed-active
                    (surface-active-context surface (host-state-views state))]
                   [refreshed-buffer
                    (buffer-service-ref (host-state-buffers state)
                                        (active-context-buffer-id refreshed-active))])
              (unless (string-contains? (buffer-string refreshed-buffer) "new.txt")
                (error 'fundamental-editing-tests "directory refresh did not republish entries")))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file new-note))
          (guard (condition [else #f]) (delete-file note))
          (delete-directory nested #f)
          (delete-directory root #f))))

    ;; A Buffer List is a generated projection over the live Buffer catalog.
    ;; Its rows activate ordinary Buffers, so visiting a row does not copy
    ;; text or transfer any View-local selection into the target Buffer.
    (let* ([path (string-append "/tmp/soda-buffer-list-"
                                (number->string (get-process-id)) ".txt")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda () (vfs-write-file path (string->utf8 "listed")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [scratch (soda-application-buffer application)]
                 [interaction (soda-application-interaction application)])
            (command-runtime-start! runtime 'file.visit
                                    (application-command-context application) (list path))
            (let* ([file-context (application-command-context application)]
                   [file-id (command-context-buffer-id file-context)])
              (command-runtime-start! runtime 'fundamental.end-of-buffer file-context)
              (command-runtime-start! runtime 'fundamental.insert-text
                                      (application-command-context application)
                                      (list (string->utf8 " changed")))
              (command-runtime-start! runtime 'buffer.list
                                      (application-command-context application))
              (let* ([list-context (application-command-context application)]
                     [list-id (command-context-buffer-id list-context)]
                     [list-buffer
                      (buffer-service-ref (host-state-buffers state) list-id)]
                     [content (buffer-string list-buffer)])
                (unless (and (string-contains? content (buffer-name scratch))
                             (string-contains? content path)
                             (string-contains?
                               content (string-append "* " (number->string file-id))))
                  (error 'fundamental-editing-tests
                         "buffer.list did not project live Buffer metadata" content))
                ;; IDs increase with creation: scratch is the first row and
                ;; the visited file is the second.  Item activation must
                ;; replace the list View with the actual target Buffer.
                (command-runtime-start! runtime 'buffer.next-item
                                        (application-command-context application))
                (command-runtime-start! runtime 'buffer.next-item
                                        (application-command-context application))
                (command-runtime-start! runtime 'buffer.activate-item
                                        (application-command-context application))
                (unless (= (command-context-buffer-id
                             (application-command-context application))
                           file-id)
                  (error 'fundamental-editing-tests
                         "buffer.list activation did not select its BufferItem target"))
                (command-runtime-start! runtime 'buffer.list
                                        (application-command-context application))
                (unless (= (command-context-buffer-id
                             (application-command-context application))
                           list-id)
                  (error 'fundamental-editing-tests
                         "buffer.list did not reuse its canonical generated Buffer"))
                ;; `d` retains the Buffer List as the active context and
                ;; passes the selected row as an explicit close target.  The
                ;; normal File package still owns its save/discard prompt.
                (command-runtime-start! runtime 'buffer.next-item
                                        (application-command-context application))
                (command-runtime-start! runtime 'buffer.next-item
                                        (application-command-context application))
                (command-runtime-start! runtime 'buffer-list.close-item
                                        (application-command-context application))
                (host-state-run! state)
                (let ([request (interaction-session-request
                                 (interaction-service-current interaction))])
                  (unless (and (eq? (interaction-request-kind request) 'save-decision)
                               (string=? (interaction-request-prompt request)
                                         (string-append "Save changes to " path
                                                        "? (save/discard/cancel) ")))
                    (error 'fundamental-editing-tests
                           "buffer.list close did not preserve the file save decision")))
                (interaction-service-submit! interaction "discard")
                (host-state-run! state)
                (unless (and (not (buffer-service-ref
                                    (host-state-buffers state) file-id #f))
                             (= (command-context-buffer-id
                                 (application-command-context application))
                                list-id))
                  (error 'fundamental-editing-tests
                         "buffer.list close did not retire its explicit target"))
                (command-runtime-start! runtime 'buffer-list.refresh
                                        (application-command-context application))
                (unless (not (string-contains?
                               (buffer-string
                                 (buffer-service-ref (host-state-buffers state) list-id)) path))
                  (error 'fundamental-editing-tests
                         "buffer.list refresh retained a closed Buffer row"))))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file path)))))

    ;; Scheme startup supplies remaining argv entries to `scheme-start`.
    ;; Opening them here follows the same file.visit command path as C-x C-f.
    (let* ([path (string-append "/tmp/soda-startup-file-"
                                (number->string (get-process-id)) ".txt")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda () (vfs-write-file path (string->utf8 "startup contents")))
        (lambda ()
          (soda-application-open-files! application (list path))
          (let* ([state (soda-application-state application)]
                 [surface (soda-application-surface application)]
                 [active (surface-active-context surface (host-state-views state))]
                 [buffer (buffer-service-ref (host-state-buffers state)
                                             (active-context-buffer-id active))])
            (unless (string=? (buffer-string buffer) "startup contents")
              (error 'fundamental-editing-tests "startup file visit did not open argv file"))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file path)))))

    (let* ([path (string-append "/tmp/soda-startup-position-"
                                (number->string (get-process-id)) ".txt")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda () (vfs-write-file path (string->utf8 "first\nsecond\nthird")))
        (lambda ()
          (soda-application-open-files! application (list "+2,2" path))
          (let* ([state (soda-application-state application)]
                 [surface (soda-application-surface application)]
                 [active (surface-active-context surface (host-state-views state))]
                 [view (view-service-ref (host-state-views state)
                                         (active-context-view-id active))]
                 [point
                  (selection-range-head
                    (selection-primary-range (view-state-selection (view-state view))))])
            (unless (= point 7)
              (error 'fundamental-editing-tests
                     "startup +LINE,COLUMN did not move to the requested file position" point))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file path)))))

    ;; Nano aliases are declarative entries in the fundamental keymap.  They
    ;; reuse the same command implementations as their primary bindings.
    (let* ([application (make-soda-application)]
           [keymap (fundamental-editing-keymap (soda-application-editing application))]
           [meta (lambda (character)
                   (make-key-stroke 'character (char->integer character) 2))]
           [control (lambda (character)
                      (make-key-stroke 'character (char->integer character) 4))])
      (unless (and (eq? (keymap-lookup keymap (list (control #\y)))
                       'fundamental.scroll-up)
                   (eq? (keymap-lookup keymap (list (meta #\6)))
                       'fundamental.copy-region)
                   (eq? (keymap-lookup keymap (list (meta #\a)))
                       'fundamental.set-mark)
                   (eq? (keymap-lookup keymap (list (meta #\g)))
                       'fundamental.goto-line)
                   (eq? (keymap-lookup keymap (list (meta #\\)))
                       'fundamental.beginning-of-buffer)
                   (eq? (keymap-lookup keymap (list (meta #\/)))
                       'fundamental.end-of-buffer))
        (error 'fundamental-editing-tests "Nano editing aliases are not bound"))
      (soda-application-close! application))

    ;; Case-folded searches retain source byte spans, including a fold that
    ;; changes length (ß -> ss), so replacement remains a normal transaction.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [search (soda-application-search application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "Alpha ALPHA Straße STRASSE")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'search.forward (application-command-context application) (list "alpha"))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 0)
                     (= (selection-range-to range) 0))
          (error 'fundamental-editing-tests
                 "case-sensitive search unexpectedly matched a differently cased string")))
      (command-runtime-start!
        runtime 'search.toggle-case-sensitive (application-command-context application))
      (command-runtime-start!
        runtime 'search.forward (application-command-context application) (list "alpha"))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 0)
                     (= (selection-range-to range) 5))
          (error 'fundamental-editing-tests
                 "case-insensitive search did not select the first folded match")))
      (command-runtime-start! runtime 'search.next (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 6)
                     (= (selection-range-to range) 11))
          (error 'fundamental-editing-tests
                 "repeat search did not retain the case policy")))
      (command-runtime-start!
        runtime 'search.replace-all (application-command-context application)
        (list "strasse" "road"))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'search.toggle-whole-word (application-command-context application))
      (command-runtime-start!
        runtime 'search.forward (application-command-context application) (list "alp"))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 0)
                     (= (selection-range-to range) 0))
          (error 'fundamental-editing-tests
                 "whole-word search unexpectedly selected a word prefix")))
      (command-runtime-start!
        runtime 'search.forward (application-command-context application) (list "alpha"))
      (command-runtime-start! runtime 'search.next (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 6)
                     (= (selection-range-to range) 11))
          (error 'fundamental-editing-tests
                 "whole-word repeat did not retain its search policy")))
      (unless (and (string=? (buffer-string buffer) "Alpha ALPHA road road")
                   (eq? (keymap-lookup
                          (search-keymap search)
                          (list (make-key-stroke 'character (char->integer #\C) 2)))
                        'search.toggle-case-sensitive)
                   (eq? (keymap-lookup
                          (search-keymap search)
                          (list (make-key-stroke 'character (char->integer #\`) 2)))
                        'search.toggle-whole-word))
        (error 'fundamental-editing-tests
               "search policies or their key bindings are incorrect"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "first\nsecond\nthird")))
      (command-runtime-start! runtime 'fundamental.goto-line
                              (application-command-context application) (list 2 3))
      (command-runtime-start! runtime 'fundamental.cut-text
                              (application-command-context application))
      (unless (and (string=? (buffer-string buffer) "first\nthird")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      6))
        (error 'fundamental-editing-tests
               "cut-text did not cut the complete current logical line"))
      (command-runtime-start! runtime 'fundamental.set-mark
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.forward-char
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.cut-text
                              (application-command-context application))
      (unless (string=? (buffer-string buffer) "first\nhird")
        (error 'fundamental-editing-tests
               "cut-text did not preserve active-region semantics"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)])
      (command-runtime-start! runtime 'help.show (application-command-context application))
      (let ([help-buffer
             (buffer-service-ref
               (host-state-buffers state)
               (command-context-buffer-id (application-command-context application)))])
        (unless (and (string=? (buffer-name help-buffer) "*help*")
                     (string-contains? (buffer-string help-buffer) "C-x C-f"))
          (error 'fundamental-editing-tests "help.show did not display the Nano help Buffer"))
        (command-runtime-start! runtime 'fundamental.insert-text
                                (application-command-context application)
                                (list (string->utf8 "mutate")))
        (unless (not (string-contains? (buffer-string help-buffer) "mutate"))
          (error 'fundamental-editing-tests "help Buffer accepted an ordinary edit")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [surface (soda-application-surface application)]
           [messages (soda-application-messages application)])
      (command-runtime-start! runtime 'message.show-position
                              (application-command-context application))
      (let* ([render (render-surface surface (host-state-views state))]
             [frame (surface-render-frame render)]
             [row (- (frame-height frame) 1)])
        (unless (and (string=? (surface-status-message surface) "Line 1, column 1")
                     (eq? (keymap-lookup
                            (message-keymap messages)
                            (list (make-key-stroke 'character (char->integer #\c) 4)))
                          'message.show-position)
                     (string=? (frame-cell-grapheme (frame-cell-at frame row 0)) "L")
                     (eq? (frame-cell-face (frame-cell-at frame row 0)) 'message))
          (error 'fundamental-editing-tests
                 "position command did not publish a Surface message chrome")))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "alpha β\ngamma")))
      (command-runtime-start! runtime 'message.count-words
                              (application-command-context application))
      (unless (and (string=? (surface-status-message surface)
                           "2 lines, 3 words, 13 characters")
                   (eq? (keymap-lookup
                          (message-keymap messages)
                          (list (make-key-stroke 'character (char->integer #\d) 3)))
                        'message.count-words))
        (error 'fundamental-editing-tests
               "word count did not use the active Buffer's Unicode text"))
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-message-operation (surface-id surface) "界"))
      (let* ([frame (surface-render-frame (render-surface surface (host-state-views state)))]
             [row (- (frame-height frame) 1)])
        (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame row 0)) "界")
                     (= (frame-cell-width (frame-cell-at frame row 0)) 2)
                     (frame-cell-continuation? (frame-cell-at frame row 1)))
          (error 'fundamental-editing-tests
                 "Surface message chrome did not preserve wide grapheme cells")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [view (soda-application-view application)])
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "zero\none\ntwo")))
      (command-runtime-start! runtime 'fundamental.goto-line
                              (application-command-context application) (list 2 2))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (= (selection-range-head range) 6)
          (error 'fundamental-editing-tests "goto-line did not use logical line and byte column")))
      (command-runtime-start! runtime 'fundamental.goto-line
                              (application-command-context application) (list 3 99))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (= (selection-range-head range) 12)
          (error 'fundamental-editing-tests "goto-line did not clamp a column to line end")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)])
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "a\n  b\nc")))
      (command-runtime-start! runtime 'fundamental.mark-whole-buffer
                              (application-command-context application))
      (command-runtime-start! runtime 'editor.set-indent-width
                              (application-command-context application) (list 2))
      (command-runtime-start! runtime 'editor.toggle-tab-to-spaces
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.indent-lines
                              (application-command-context application))
      (unless (string=? (buffer-string buffer) "  a\n    b\n  c")
        (error 'fundamental-editing-tests "indent-lines did not transform each selected line once"))
      (command-runtime-start! runtime 'fundamental.unindent-lines
                              (application-command-context application))
      (unless (string=? (buffer-string buffer) "a\n  b\nc")
        (error 'fundamental-editing-tests "unindent-lines did not restore tabs and space indentation"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [view (soda-application-view application)])
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "a(b(c)d)e")))
      (command-runtime-start! runtime 'fundamental.beginning-of-buffer
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.forward-char
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.matching-delimiter
                              (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (= (selection-range-head range) 7)
          (error 'fundamental-editing-tests "matching-delimiter did not skip nested delimiters")))
      (command-runtime-start! runtime 'fundamental.matching-delimiter
                              (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (= (selection-range-head range) 1)
          (error 'fundamental-editing-tests "matching-delimiter did not scan backward from a close delimiter")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)])
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "  alpha beta\ngamma   delta")))
      (command-runtime-start! runtime 'fundamental.fill-paragraph
                              (application-command-context application))
      (unless (string=? (buffer-string buffer) "  alpha beta gamma delta")
        (error 'fundamental-editing-tests "fill-paragraph did not normalize one paragraph"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "alpha beta alpha")))
      (command-runtime-start! runtime 'search.forward
                              (application-command-context application) (list "alpha"))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 0)
                     (= (selection-range-to range) 5))
          (error 'fundamental-editing-tests "search.forward did not select its first match")))
      (command-runtime-start! runtime 'search.next (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 11)
                     (= (selection-range-to range) 16))
          (error 'fundamental-editing-tests "search.next did not repeat from the selected match")))
      (command-runtime-start! runtime 'search.previous (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 0)
                     (= (selection-range-to range) 5))
          (error 'fundamental-editing-tests "search.previous did not reverse the search direction")))
      (unless
        (eq? (keymap-lookup
               (search-keymap (soda-application-search application))
               (list (make-key-stroke 'character (char->integer #\w) 3)))
             'search.previous)
        (error 'fundamental-editing-tests "Meta-Shift-w did not bind reverse search repetition"))
      (command-runtime-start! runtime 'search.replace-all
                              (application-command-context application) (list "alpha" "A"))
      (unless (string=? (buffer-string buffer) "A beta A")
        (error 'fundamental-editing-tests "search.replace-all did not use one Buffer transaction"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [interaction (soda-application-interaction application)]
           [minibuffer (soda-application-minibuffer application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "one one one")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'search.query-replace (application-command-context application)
        (list "one" "1"))
      (host-state-run! state)
      (unless (and (interaction-service-current interaction)
                   (eq? (interaction-request-kind
                          (interaction-session-request
                            (interaction-service-current interaction)))
                        'query-replace-decision)
                   (let ([range (selection-primary-range
                                  (view-state-selection (view-state view)))])
                     (and (= (selection-range-from range) 0)
                          (= (selection-range-to range) 3))))
        (error 'fundamental-editing-tests "query replace did not prompt for its first match"))
      (let* ([session (minibuffer-service-current minibuffer)]
             [prompt-view
              (view-service-ref (host-state-views state)
                                (minibuffer-session-view-id session))]
             [prompt-buffer
              (buffer-service-ref (host-state-buffers state)
                                  (minibuffer-session-buffer-id session))]
             [active
              (surface-active-context (soda-application-surface application)
                                      (host-state-views state))]
             [event
              (make-key-event 'character (char->integer #\y) #f #f 0 'press
                              (make-bytevector 0))]
             [input-context
              (minibuffer-input-context minibuffer active prompt-view)]
             [disposition (input-dispatch input-context event)]
             [context
              (make-command-context
                #f
                (active-context-surface-id active)
                (active-context-window-id active)
                (view-id prompt-view)
                (buffer-id prompt-buffer)
                (buffer-state prompt-buffer)
                (view-state prompt-view)
                event '() #f active 'query-replace-test)])
        (unless (and (eq? (input-disposition-kind disposition) 'command)
                     (eq? (input-disposition-value disposition) 'minibuffer.accept-key))
          (error 'fundamental-editing-tests
                 "query replace prompt did not install its discrete answer keymap"))
        (command-runtime-start! runtime 'minibuffer.accept-key context))
      (host-state-run! state)
      (unless (and (string=? (buffer-string buffer) "1 one one")
                   (interaction-service-current interaction)
                   (let ([range (selection-primary-range
                                  (view-state-selection (view-state view)))])
                     (and (= (selection-range-from range) 2)
                          (= (selection-range-to range) 5))))
        (error 'fundamental-editing-tests "query replace did not advance after replace"))
      (interaction-service-submit! interaction "n")
      (host-state-run! state)
      (unless (and (string=? (buffer-string buffer) "1 one one")
                   (interaction-service-current interaction)
                   (let ([range (selection-primary-range
                                  (view-state-selection (view-state view)))])
                     (and (= (selection-range-from range) 6)
                          (= (selection-range-to range) 9))))
        (error 'fundamental-editing-tests "query replace did not advance after skip"))
      (interaction-service-submit! interaction "!")
      (host-state-run! state)
      (unless (and (string=? (buffer-string buffer) "1 one 1")
                   (not (interaction-service-current interaction)))
        (error 'fundamental-editing-tests "query replace all did not finish remaining matches"))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'search.query-replace (application-command-context application)
        (list "one" "x"))
      (host-state-run! state)
      (interaction-service-cancel! interaction)
      (host-state-run! state)
      (unless (not (interaction-service-current interaction))
        (error 'fundamental-editing-tests "query replace cancellation left a prompt session live"))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [interaction (soda-application-interaction application)]
           [minibuffer (soda-application-minibuffer application)]
           [owner (make-owner 'interaction-package-test)]
           [observed #f]
           [must-match-value #f]
           [events '()]
           [setup-input #f]
           [exit-input #f]
           [reader
            (make-interactive-reader
              'read-value
              (lambda (context arguments)
                (make-interactive-suspend
                  (make-interaction-request 'string "Value: " "accepted" #f 'free)
                  (lambda (value) (make-interactive-ready (list value))))))]
           [_listener
            (interaction-service-add-listener!
              interaction owner
              (lambda (event session) (set! events (cons event events))))]
           [_failing-listener
            (interaction-service-add-listener!
              interaction owner
              (lambda (event session)
                (assertion-violation 'interaction-listener-test "listener failure" event)))]
           [_setup-hook
            (minibuffer-service-add-hook!
              minibuffer 'setup owner
              (lambda (snapshot) (set! setup-input (prompt-snapshot-input snapshot))))]
           [_exit-hook
            (minibuffer-service-add-hook!
              minibuffer 'exit owner
              (lambda (snapshot) (set! exit-input (prompt-snapshot-input snapshot))))]
           [_command
            (command-runtime-register-command!
              runtime
              (make-command-definition
                'interaction.package-test
                (lambda (context value)
                  (set! observed value)
                  (command-handled))
                owner "Interaction package test" 'test
                (make-interactive-plan (list reader))))]
           [invocation
            (command-runtime-start-interactive!
              runtime 'interaction.package-test (application-command-context application))]
           [session (interaction-service-current interaction)])
      (unless (and session
                   (= (interaction-session-invocation-id session)
                      (command-invocation-id invocation))
                   (eq? (interaction-session-command-name session)
                        'interaction.package-test)
                   (eq? (interaction-session-reader-name session) 'read-value)
                   (eq? (interaction-request-kind (interaction-session-request session)) 'string)
                   (string=? (interaction-request-prompt (interaction-session-request session))
                             "Value: ")
                   (minibuffer-service-current minibuffer)
                   (string=? setup-input "accepted"))
        (error 'fundamental-editing-tests "interactive command did not open a reusable session"))
      (let* ([prompt-session (minibuffer-service-current minibuffer)]
             [prompt-view
              (view-service-ref
                (host-state-views state)
                (minibuffer-session-view-id prompt-session))])
        (let ([ranges
               (range-set-ranges
                 (view-projection-decorations (view-projection prompt-view)))])
          (unless (and (= (length ranges) 1)
                       (= (range-value-from (car ranges)) 0)
                       (= (range-value-to (car ranges)) 8)
                       (eq? (face-decoration-face (range-value-value (car ranges)))
                            'minibuffer.input))
            (error 'fundamental-editing-tests
                   "minibuffer input did not receive its dedicated face")))
        (let-values ([(stream failures)
                      (view-transform-display-stream prompt-view (make-display-stream '()))])
          (unless (null? failures)
            (error 'fundamental-editing-tests
                   "minibuffer prompt transform reported a failure" failures))
          (let ([fragment (car (display-stream-fragments stream))])
            (unless (and (display-text? fragment)
                         (string=? (display-text-text fragment) "Value: ")
                         (= (display-text-from fragment) 0)
                         (= (display-text-to fragment) 0)
                         (eq? (display-text-face fragment) 'minibuffer.prompt))
              (error 'fundamental-editing-tests
                     "minibuffer prompt was not projected as virtual View content")))))
      (command-runtime-start! runtime 'fundamental.end-of-buffer
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "é")))
      (let ([snapshot
             (minibuffer-session-snapshot
               minibuffer (minibuffer-service-current minibuffer))])
        (unless (and (string=? (prompt-snapshot-input snapshot) "acceptedé")
                     (= (prompt-snapshot-point snapshot) 9))
          (error 'fundamental-editing-tests
                 "prompt snapshots did not convert UTF-8 byte point to character index")))
      (command-runtime-start! runtime 'minibuffer.accept (application-command-context application))
      (host-state-run! state)
      (unless (and (string=? observed "acceptedé")
                   (not (interaction-service-current interaction))
                   (not (minibuffer-service-current minibuffer))
                   (string=? exit-input "acceptedé")
                   (equal? (reverse events) '(opened accepted)))
        (error 'fundamental-editing-tests "interaction submission did not resume through the queue"))
      (let* ([source
              (make-completion-source
                (lambda (snapshot)
                  (list (make-completion-candidate 'allowed "allowed" "allowed" #f #f #f)))
                #f #f #f
                (lambda (input snapshot) (string=? input "allowed")))]
             [match-reader
              (make-interactive-reader
                'read-match
                (lambda (context arguments)
                  (make-interactive-suspend
                    (make-interaction-request 'string "Match: " "allowed" source 'must-match)
                    (lambda (value) (make-interactive-ready (list value))))))])
        (command-runtime-register-command!
          runtime
          (make-command-definition
            'interaction.match-test
            (lambda (context value) (set! must-match-value value) (command-handled))
            owner "Must-match interaction test" 'test
            (make-interactive-plan (list match-reader))))
        (command-runtime-start-interactive!
          runtime 'interaction.match-test (application-command-context application))
        (let ([controller (minibuffer-service-refresh-completion! minibuffer)])
          (unless (and controller (not (completion-controller-selected-index controller)))
            (error 'fundamental-editing-tests "completion refresh preselected a candidate")))
        (minibuffer-service-submit! minibuffer)
        (host-state-run! state)
        (unless (and (string=? must-match-value "allowed")
                     (not (minibuffer-service-current minibuffer)))
          (error 'fundamental-editing-tests "must-match source validator did not accept raw input")))
      (let ([cancelled
             (command-runtime-start-interactive!
               runtime 'interaction.package-test (application-command-context application))])
        (interaction-service-cancel! interaction)
        (host-state-run! state)
        (unless (and (not (command-runtime-invocation
                            runtime (command-invocation-id cancelled) #f))
                     (not (interaction-service-current interaction)))
          (error 'fundamental-editing-tests "interaction cancellation did not retire its invocation")))
      (owner-close! owner)
      (soda-application-close! application))

    ;; VFS publishes a complete replacement or leaves the target intact.  It
    ;; preserves an existing regular file's mode and removes a temporary when
    ;; replacement fails against a directory target.
    (let* ([root (string-append "/tmp/soda-atomic-write-"
                                (number->string (get-process-id)))]
           [path (string-append root "/document.txt")]
           [directory-target (string-append root "/directory")]
           [temporary-prefix "directory.soda-write-"])
      (dynamic-wind
        (lambda ()
          (when (file-exists? root) (delete-directory root))
          (mkdir root)
          (mkdir directory-target))
        (lambda ()
          (vfs-write-file path (string->utf8 "first"))
          (chmod path #o640)
          (vfs-write-file path (string->utf8 "second"))
          (unless (and (string=? (utf8->string (vfs-read-file path)) "second")
                       (= (bitwise-and (get-mode path) #o777) #o640))
            (error 'fundamental-editing-tests
                   "atomic VFS write did not replace content or preserve mode"))
          (let ([failed?
                 (guard (condition [else #t])
                   (vfs-write-file directory-target (string->utf8 "invalid"))
                   #f)])
            (unless (and failed?
                         (not
                           (exists
                             (lambda (entry)
                               (string-prefix? temporary-prefix
                                               (vfs-entry-name entry)))
                             (vfs-list-directory root))))
              (error 'fundamental-editing-tests
                     "failed atomic VFS write left a temporary file behind"))))
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? directory-target) (delete-directory directory-target))
          (when (file-exists? root) (delete-directory root)))))

    (let* ([path (string-append "/tmp/soda-file-package-"
                                (number->string (get-process-id)) ".txt")]
           [second-path (string-append path ".second")]
           [new-path (string-append path ".new")]
           [saved-as (string-append path ".copy")]
           [scratch-save (string-append path ".scratch")])
      (dynamic-wind
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? second-path) (delete-file second-path))
          (when (file-exists? new-path) (delete-file new-path))
          (when (file-exists? saved-as) (delete-file saved-as))
          (when (file-exists? scratch-save) (delete-file scratch-save))
          (vfs-write-file path (string->utf8 "first"))
          (vfs-write-file second-path (string->utf8 "second")))
        (lambda ()
          (let* ([application (make-soda-application)]
                 [state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [scratch (soda-application-buffer application)]
                 [history (soda-application-history application)]
                 [files (soda-application-files application)]
                 [interaction (soda-application-interaction application)])
            (command-runtime-start-interactive!
              runtime 'file.save (application-command-context application))
            (let ([request (interaction-session-request
                             (interaction-service-current interaction))])
              (unless (and (eq? (interaction-request-kind request) 'file-name)
                           (string=? (interaction-request-prompt request) "Write file: "))
                (error 'fundamental-editing-tests
                       "file.save did not ask an unvisited Buffer for its destination")))
            (interaction-service-submit! interaction scratch-save)
            (host-state-run! state)
            (unless (and (file-exists? scratch-save)
                         (string=? (resource-locator
                                    (file-service-resource files (buffer-id scratch)))
                                   scratch-save))
              (error 'fundamental-editing-tests
                     "file.save did not bind an unvisited Buffer to its selected destination"))
            (command-runtime-start! runtime 'file.insert
                                    (application-command-context application) (list path))
            (host-state-run! state)
            (unless (string=? (buffer-string scratch) "first")
              (error 'fundamental-editing-tests
                     "file.insert did not enqueue a normal Buffer transaction"))
            (command-runtime-start! runtime 'file.save
                                    (application-command-context application))
            (unless (string=? (utf8->string (vfs-read-file scratch-save)) "first")
              (error 'fundamental-editing-tests
                     "file.insert did not preserve normal save semantics"))
            (command-runtime-start-interactive!
              runtime 'file.visit (application-command-context application))
            (let ([request (interaction-session-request
                             (interaction-service-current interaction))])
              (unless (and (eq? (interaction-request-kind request) 'file-name)
                           (completion-source?
                             (interaction-request-completion-source request))
                           (string=? (interaction-request-prompt request) "Visit file: "))
                (error 'fundamental-editing-tests
                       "file.visit did not declare a reusable file interaction")))
            (command-runtime-start!
              runtime 'fundamental.insert-text (application-command-context application)
              (list (string->utf8 (substring path 0 (- (string-length path) 4)))))
            (let ([controller (minibuffer-service-refresh-completion!
                                (soda-application-minibuffer application))])
              (unless (and controller
                           (exists
                             (lambda (candidate)
                               (string=? (completion-candidate-insert-text candidate) path))
                             (completion-controller-candidates controller)))
                (error 'fundamental-editing-tests
                       "file-name completion did not offer the visited file")))
            (command-runtime-start! runtime 'minibuffer.complete
                                    (application-command-context application))
            (let* ([session (minibuffer-service-current
                              (soda-application-minibuffer application))]
                   [prompt-buffer
                    (buffer-service-ref
                      (host-state-buffers state)
                      (minibuffer-session-buffer-id session))])
              (unless (string=? (buffer-string prompt-buffer) path)
                (error 'fundamental-editing-tests
                       "minibuffer.complete did not apply the path common prefix")))
            (interaction-service-cancel! interaction)
            (host-state-run! state)
            (command-runtime-start! runtime 'file.visit
                                    (application-command-context application) (list path))
            (let ([buffer (buffer-service-ref
                            (host-state-buffers state)
                            (command-context-buffer-id
                              (application-command-context application)))])
              (unless (and (not (= (buffer-id buffer) (buffer-id scratch)))
                           (string=? (buffer-string buffer) "first")
                           (not (history-modified? history (buffer-id buffer)))
                         (string=? (resource-locator
                           (file-service-resource files (buffer-id buffer))) path))
                (error 'fundamental-editing-tests
                       "file.visit did not create and select a file Buffer"))
              (command-runtime-start! runtime 'fundamental.end-of-buffer
                                      (application-command-context application))
              (command-runtime-start! runtime 'fundamental.insert-text
                                      (application-command-context application)
                                      (list (string->utf8 " value")))
              (command-runtime-start! runtime 'file.save
                                      (application-command-context application))
              (unless (and (string=? (utf8->string (vfs-read-file path)) "first value")
                           (not (history-modified? history (buffer-id buffer))))
                (error 'fundamental-editing-tests
                       "file.save did not synchronize the resource save point"))
              (command-runtime-start! runtime 'fundamental.insert-text
                                      (application-command-context application)
                                      (list (string->utf8 " local")))
              (vfs-write-file path (string->utf8 "external"))
              (command-runtime-start! runtime 'file.save
                                      (application-command-context application))
              (unless (string=? (utf8->string (vfs-read-file path)) "external")
                (error 'fundamental-editing-tests
                       "file.save overwrote an externally modified resource"))
              (command-runtime-start! runtime 'file.save-as
                                      (application-command-context application) (list saved-as))
              (unless (and (string=? (utf8->string (vfs-read-file saved-as)) "first value local")
                           (string=? (resource-locator
                                      (file-service-resource files (buffer-id buffer))) saved-as))
                (error 'fundamental-editing-tests
                       "file.save-as did not rebind the file resource"))
              (command-runtime-start! runtime 'file.visit
                                      (application-command-context application) (list second-path))
              (let ([second (buffer-service-ref
                              (host-state-buffers state)
                              (command-context-buffer-id
                                (application-command-context application)))])
                (unless (and (not (= (buffer-id second) (buffer-id buffer)))
                             (string=? (buffer-string second) "second"))
                  (error 'fundamental-editing-tests
                         "file.visit did not preserve the existing file Buffer")))
              (command-runtime-start! runtime 'file.visit
                                      (application-command-context application) (list new-path))
              (let ([new-file (buffer-service-ref
                                (host-state-buffers state)
                                (command-context-buffer-id
                                  (application-command-context application)))])
                (unless (and (string=? (buffer-string new-file) "")
                             (string=? (resource-locator
                                        (file-service-resource files (buffer-id new-file))) new-path))
                  (error 'fundamental-editing-tests
                         "file.visit did not create a Buffer for a new file"))
                (command-runtime-start! runtime 'fundamental.insert-text
                                        (application-command-context application)
                                        (list (string->utf8 "new")))
                (command-runtime-start! runtime 'file.save
                                        (application-command-context application))
                (unless (string=? (utf8->string (vfs-read-file new-path)) "new")
                  (error 'fundamental-editing-tests
                         "file.save did not create the visited new file")))
              (command-runtime-start! runtime 'file.visit
                                      (application-command-context application) (list saved-as))
              (let ([revisited (buffer-service-ref
                                 (host-state-buffers state)
                                 (command-context-buffer-id
                                   (application-command-context application)))])
                (unless (= (buffer-id revisited) (buffer-id buffer))
                  (error 'fundamental-editing-tests
                         "file.visit did not reuse its canonical file Buffer"))
                (command-runtime-start! runtime 'fundamental.end-of-buffer
                                        (application-command-context application))
                (command-runtime-start! runtime 'fundamental.insert-text
                                        (application-command-context application)
                                        (list (string->utf8 " discard")))
                (command-runtime-start-interactive!
                  runtime 'file.close (application-command-context application))
                (let ([request (interaction-session-request
                                 (interaction-service-current interaction))])
                  (unless (and (eq? (interaction-request-kind request) 'save-decision)
                               (string=? (interaction-request-prompt request)
                                         (string-append "Save changes to " (buffer-name revisited)
                                                        "? (save/discard/cancel) ")))
                    (error 'fundamental-editing-tests
                           "file.close did not request a modified-file decision")))
                (interaction-service-submit! interaction "discard")
                (host-state-run! state)
                (unless (and (not (buffer-service-ref
                                    (host-state-buffers state) (buffer-id revisited) #f))
                             (not (file-service-resource files (buffer-id revisited) #f))
                             (not (= (command-context-buffer-id
                                       (application-command-context application))
                                     (buffer-id revisited))))
                  (error 'fundamental-editing-tests
                         "file.close did not replace every active View before releasing its Buffer"))))
            (command-runtime-start! runtime 'file.visit
                                    (application-command-context application) (list second-path))
            (let ([closable (buffer-service-ref
                              (host-state-buffers state)
                              (command-context-buffer-id
                                (application-command-context application)))])
              (command-runtime-start! runtime 'fundamental.end-of-buffer
                                      (application-command-context application))
              (command-runtime-start! runtime 'fundamental.insert-text
                                      (application-command-context application)
                                      (list (string->utf8 " saved")))
              (command-runtime-start-interactive!
                runtime 'file.close (application-command-context application))
              (interaction-service-submit! interaction "save")
              (host-state-run! state)
              (unless (and (string=? (utf8->string (vfs-read-file second-path)) "second saved")
                           (not (buffer-service-ref
                                  (host-state-buffers state) (buffer-id closable) #f)))
                (error 'fundamental-editing-tests
                       "file.close save did not write and release the file Buffer")))
            (command-runtime-start! runtime 'file.visit
                                    (application-command-context application) (list new-path))
            (command-runtime-start! runtime 'fundamental.end-of-buffer
                                    (application-command-context application))
            (command-runtime-start! runtime 'fundamental.insert-text
                                    (application-command-context application)
                                    (list (string->utf8 " quit")))
            (command-runtime-start-interactive!
              runtime 'application.quit (application-command-context application))
            (let ([request (interaction-session-request
                             (interaction-service-current interaction))])
              (unless (and (eq? (interaction-request-kind request) 'save-decision)
                           (string=? (interaction-request-prompt request)
                                     "Save 1 modified file buffer? (save/discard/cancel) "))
                (error 'fundamental-editing-tests
                       "application.quit did not request a modified-file decision")))
            (interaction-service-submit! interaction "save")
            (host-state-run! state)
            (unless (and (not (interaction-service-current interaction))
                         (string=? (utf8->string (vfs-read-file new-path)) "new quit"))
              (error 'fundamental-editing-tests
                     "application.quit did not save and retire its modified-file interaction"))
            (let* ([secondary-owner (make-owner 'file-close-test)]
                   [secondary-document (make-document "")]
                   [secondary
                    (buffer-service-create!
                      (host-state-buffers state) secondary-owner "*file-close*"
                      secondary-document (make-configuration '()))]
                   [secondary-context
                    (make-command-context
                      #f #f #f #f (buffer-id secondary)
                      (buffer-state secondary) #f #f '() #f #f 'file-close-test)])
              (unless (not (history-modified? history (buffer-id secondary)))
                (error 'fundamental-editing-tests
                       "a newly created Buffer should begin at the implicit History save point"))
              (command-runtime-start! runtime 'file.visit secondary-context (list path))
              (buffer-service-close-buffer! (host-state-buffers state) (buffer-id secondary))
              (unless (not (file-service-resource files (buffer-id secondary) #f))
                (error 'fundamental-editing-tests
                       "closing a Buffer did not release its file resource binding"))
              (owner-close! secondary-owner))
            (soda-application-close! application)))
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? second-path) (delete-file second-path))
          (when (file-exists? new-path) (delete-file new-path))
          (when (file-exists? saved-as) (delete-file saved-as))
          (when (file-exists? scratch-save) (delete-file scratch-save)))))

    ;; File backup is Buffer-local and captures the immediately preceding
    ;; on-disk contents before every ordinary save.  It uses the same atomic
    ;; VFS write path as the target file.
    (let* ([path (string-append "/tmp/soda-file-backup-"
                                (number->string (get-process-id)) ".txt")]
           [backup (string-append path "~")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? backup) (delete-file backup))
          (vfs-write-file path (string->utf8 "original")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [files (soda-application-files application)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application) (list path))
            (command-runtime-start!
              runtime 'file.toggle-backup (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.end-of-buffer (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application) (list (string->utf8 " first")))
            (command-runtime-start!
              runtime 'file.save (application-command-context application))
            (unless (and (string=? (utf8->string (vfs-read-file path)) "original first")
                         (string=? (utf8->string (vfs-read-file backup)) "original")
                         (eq? (keymap-lookup
                                (file-keymap files)
                                (list (make-key-stroke 'character (char->integer #\B) 2)))
                              'file.toggle-backup))
              (error 'fundamental-editing-tests
                     "file backup did not retain the pre-save resource contents"))
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application) (list (string->utf8 " second")))
            (command-runtime-start!
              runtime 'file.save (application-command-context application))
            (unless (and (string=? (utf8->string (vfs-read-file path)) "original first second")
                         (string=? (utf8->string (vfs-read-file backup)) "original first"))
              (error 'fundamental-editing-tests
                     "file backup did not advance with the saved resource"))
            (soda-application-close! application)))
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? backup) (delete-file backup)))))

    ;; Write Out and Save As preserve an explicit overwrite boundary.  A
    ;; declined confirmation changes neither the resource nor the Buffer's
    ;; file association.
    (let* ([path (string-append "/tmp/soda-overwrite-"
                                (number->string (get-process-id)) ".txt")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda () (vfs-write-file path (string->utf8 "original")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [buffer (soda-application-buffer application)]
                 [files (soda-application-files application)]
                 [interaction (soda-application-interaction application)])
            (command-runtime-start! runtime 'fundamental.insert-text
                                    (application-command-context application)
                                    (list (string->utf8 "replacement")))
            (command-runtime-start-interactive!
              runtime 'file.save-as (application-command-context application))
            (interaction-service-submit! interaction path)
            (host-state-run! state)
            (let ([request (interaction-session-request
                             (interaction-service-current interaction))])
              (unless (and (eq? (interaction-request-kind request) 'overwrite-decision)
                           (string=? (interaction-request-prompt request)
                                     (string-append "File exists: " path
                                                    ". Overwrite? (yes/no) ")))
                (error 'fundamental-editing-tests
                       "file.save-as did not request overwrite confirmation")))
            (interaction-service-submit! interaction "no")
            (host-state-run! state)
            (unless (and (string=? (utf8->string (vfs-read-file path)) "original")
                         (not (file-service-resource files (buffer-id buffer) #f)))
              (error 'fundamental-editing-tests
                     "declined file overwrite changed the resource or Buffer binding"))
            (command-runtime-start-interactive!
              runtime 'file.save-as (application-command-context application))
            (interaction-service-submit! interaction path)
            (host-state-run! state)
            (interaction-service-submit! interaction "yes")
            (host-state-run! state)
            (unless (and (string=? (utf8->string (vfs-read-file path)) "replacement")
                         (let ([resource
                                (file-service-resource files (buffer-id buffer) #f)])
                           (and resource
                                (string=? (resource-locator resource) path))))
              (error 'fundamental-editing-tests
                     "confirmed file overwrite did not write or bind the resource"))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file path)))))

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

    ;; Kernel changes allow textual inserts as well as bytevectors.  History
    ;; must invert either representation without owning its own coordinate
    ;; protocol.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [owner (make-owner 'history-string-test)]
           [_command
            (command-runtime-register-command!
              runtime
              (make-command-definition
                'history.string-change
                (lambda (context)
                  (let ([buffer-state (command-context-buffer-state context)])
                    (make-transaction-spec
                      (command-context-buffer-id context)
                      (command-context-view-id context)
                      (buffer-state-generation buffer-state)
                      (make-change-set 0 (list (make-text-change 0 0 "text")))
                      #f '() '())))
                owner "Insert a textual change for History." 'test #f))])
      (command-runtime-start! runtime 'history.string-change
                              (application-command-context application))
      (command-runtime-start! runtime 'history.undo
                              (application-command-context application))
      (unless (string=? (buffer-string buffer) "")
        (error 'fundamental-editing-tests
               "history.undo did not support a string TextChange"))
      (owner-close! owner)
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

    ;; Editing options are immutable state contributions: auto-indent follows
    ;; the Buffer across commands, while layout choices remain View-local.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [options (soda-application-options application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "\talpha")))
      (command-runtime-start!
        runtime 'fundamental.newline (application-command-context application))
      (unless (string=? (buffer-string buffer) "\talpha\n\t")
        (error 'fundamental-editing-tests
               "auto-indent did not preserve leading whitespace on newline"))
      (command-runtime-start!
        runtime 'editor.toggle-auto-indent (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.newline (application-command-context application))
      (command-runtime-start!
        runtime 'editor.toggle-soft-wrap (application-command-context application))
      (command-runtime-start!
        runtime 'editor.set-tab-width (application-command-context application) (list 4))
      (command-runtime-start!
        runtime 'editor.set-indent-width (application-command-context application) (list 2))
      (command-runtime-start!
        runtime 'editor.set-fill-column (application-command-context application) (list 12))
      (command-runtime-start!
        runtime 'editor.toggle-auto-fill (application-command-context application))
      (command-runtime-start!
        runtime 'editor.toggle-tab-to-spaces (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.insert-tab (application-command-context application))
      (let ([layout
             (configuration-facet (view-state-configuration (view-state view))
                                  text-layout-options-facet 'view)]
            [indent-options
             (configuration-indent-options
               (buffer-state-configuration (buffer-state buffer)))]
            [fill-options
             (configuration-fill-options
               (buffer-state-configuration (buffer-state buffer)))])
        (unless (and (string=? (buffer-string buffer) "\talpha\n\t\n  ")
                     (not (auto-indent-enabled?
                            (buffer-state-configuration (buffer-state buffer))))
                     (= (indent-options-width indent-options) 2)
                     (not (indent-options-insert-tabs? indent-options))
                     (= (fill-options-column fill-options) 12)
                     (fill-options-auto-fill? fill-options)
                     (not (text-layout-options-wrap? layout))
                     (= (text-layout-options-tab-width layout) 4)
                     (eq? (keymap-lookup
                            (editor-options-keymap options)
                            (list (make-key-stroke 'character (char->integer #\i) 2)))
                          'editor.toggle-auto-indent)
                     (eq? (keymap-lookup
                            (editor-options-keymap options)
                            (list (make-key-stroke 'character (char->integer #\E) 2)))
                          'editor.toggle-tab-to-spaces)
                     (eq? (keymap-lookup
                            (editor-options-keymap options)
                            (list (make-key-stroke 'character (char->integer #\R) 2)))
                          'editor.toggle-read-only)
                     (eq? (keymap-lookup
                            (editor-options-keymap options)
                            (list (make-key-stroke 'character (char->integer #\F) 2)))
                          'editor.toggle-auto-fill))
          (error 'fundamental-editing-tests
                 "editing option scope or reconfiguration is incorrect")))
      (command-runtime-start!
        runtime 'editor.toggle-read-only (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "blocked")))
      (unless (and (buffer-read-only? (buffer-state-configuration (buffer-state buffer)))
                   (string=? (buffer-string buffer) "\talpha\n\t\n  "))
        (error 'fundamental-editing-tests
               "read-only option did not reject a normal editing command"))
      (command-runtime-start!
        runtime 'editor.toggle-read-only (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "editable")))
      (unless (and (not (buffer-read-only?
                          (buffer-state-configuration (buffer-state buffer))))
                   (string=? (buffer-string buffer) "\talpha\n\t\n  editable"))
        (error 'fundamental-editing-tests
               "read-only option did not restore normal editing"))
      (soda-application-close! application))

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

    ;; Auto-fill turns one existing whitespace into a hard newline in the
    ;; same transaction as committed text insertion.  It preserves long words
    ;; and history observes the complete wrapped edit as one undo step.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)])
      (command-runtime-start!
        runtime 'editor.set-fill-column (application-command-context application) (list 10))
      (command-runtime-start!
        runtime 'editor.toggle-auto-fill (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "one two three")))
      (unless (string=? (buffer-string buffer) "one two\nthree")
        (error 'fundamental-editing-tests
               "auto-fill did not hard-wrap at the previous whitespace"))
      (command-runtime-start!
        runtime 'history.undo (application-command-context application))
      (unless (string=? (buffer-string buffer) "")
        (error 'fundamental-editing-tests
               "auto-fill insertion did not remain one undoable transaction"))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "averylongword")))
      (unless (string=? (buffer-string buffer) "averylongword")
        (error 'fundamental-editing-tests
               "auto-fill split a word without an available whitespace"))
      (soda-application-close! application))

    ;; A presented TextLayout is optional command input.  It supplies visual
    ;; rows for wrapped text without giving fundamental editing terminal or
    ;; renderer ownership; the same immutable layout remains valid while only
    ;; selection state changes.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "abcdefghijk")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (let* ([snapshot (buffer-state-document (buffer-state buffer))]
             [layout
              (layout-text-snapshot
                snapshot (view-state-selection (view-state view)) 0 4 4
                (make-decoration-set '()) (make-text-layout-options 4 #t))])
        (command-runtime-start!
          runtime 'fundamental.next-line
          (application-command-context application layout))
        (command-runtime-start!
          runtime 'fundamental.next-line
          (application-command-context application layout))
        (command-runtime-start!
          runtime 'fundamental.previous-line
          (application-command-context application layout))
        (unless (= (selection-range-head
                     (selection-primary-range (view-state-selection (view-state view))))
                   4)
          (error 'fundamental-editing-tests
                 "vertical movement did not follow presented soft-wrap rows")))
      (soda-application-close! application))

    ;; Consecutive vertical commands preserve a desired display column across
    ;; short rows; a horizontal command establishes a fresh desired column.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [options (make-text-layout-options 4 #t)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "abcdefghi\nx\nabcdefghi")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.forward-char (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.forward-char (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.forward-char (application-command-context application))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 8
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.next-line (application-command-context application layout))
        (command-runtime-start!
          runtime 'fundamental.next-line (application-command-context application layout))
        (command-runtime-start!
          runtime 'fundamental.next-line (application-command-context application layout)))
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 11)
        (error 'fundamental-editing-tests
               "vertical movement did not retain the desired column through a short row"))
      (command-runtime-start!
        runtime 'fundamental.backward-char (application-command-context application))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 8
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.next-line (application-command-context application layout)))
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 12)
        (error 'fundamental-editing-tests
               "horizontal movement did not reset the vertical desired column"))
      (soda-application-close! application))

    ;; Raw visual measurement remains available after a caret reaches the
    ;; edge of the last rendered frame.  It shares tab and wide-grapheme
    ;; geometry with TextLayout rather than falling back to logical lines.
    (let* ([text (string->text "abcdEF\nxy")]
           [options (make-text-layout-options 4 #t)]
           [position (text-layout-document-visual-position text options 4 4)]
           [next (text-layout-visual-step text options 4 position 1)]
           [previous (text-layout-visual-step text options 4 next -1)]
           [tab-text (string->text "a\tbc")]
           [tab-position (text-layout-document-visual-position tab-text options 4 2)]
           [wide-text (string->text "a界b")]
           [wide-position (text-layout-document-visual-position wide-text options 3 4)])
      (unless (and (= (visual-position-line position) 0)
                   (= (visual-position-row position) 1)
                   (= (visual-position-offset next) 7)
                   (= (visual-position-line next) 1)
                   (= (visual-position-row next) 0)
                   (= (visual-position-offset previous) 4)
                   (= (visual-position-row tab-position) 1)
                   (= (visual-position-row wide-position) 1))
        (error 'fundamental-editing-tests
               "unbounded visual row measurement is incorrect"))
      (text-close! text)
      (text-close! tab-text)
      (text-close! wide-text))

    ;; Vertical motion and paging cross a rendered boundary in one command.
    ;; The Viewport advances by visual rows, so a subsequent presentation keeps
    ;; the caret in the same screen row without changing Buffer state.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [options (make-text-layout-options 4 #t)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "abcdefghijk")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.next-line (application-command-context application layout)))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.next-line (application-command-context application layout)))
      (unless (and (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      8)
                   (= (viewport-first-line (view-state-viewport (view-state view))) 0)
                   (= (viewport-visual-row (view-state-viewport (view-state view))) 1))
        (error 'fundamental-editing-tests
               "visual next-line did not cross the rendered boundary"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 1 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.previous-line (application-command-context application layout)))
      (unless (and (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      4)
                   (= (viewport-visual-row (view-state-viewport (view-state view))) 1))
        (error 'fundamental-editing-tests
               "visual previous-line did not retain a visible target row"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 1 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.previous-line (application-command-context application layout)))
      (unless (and (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      0)
                   (= (viewport-visual-row (view-state-viewport (view-state view))) 0))
        (error 'fundamental-editing-tests
               "visual previous-line did not restore the preceding viewport row"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.scroll-down (application-command-context application layout)))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 2)
        (error 'fundamental-editing-tests "page down did not use visual frame height"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 2 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.scroll-down (application-command-context application layout)))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 2)
        (error 'fundamental-editing-tests "page down did not clamp at the final visual row"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 2 4 2
               (make-decoration-set '()) #f options)])
        (command-runtime-start!
          runtime 'fundamental.scroll-up (application-command-context application layout)))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 0)
        (error 'fundamental-editing-tests "page up did not restore visual viewport origin"))
      (soda-application-close! application))

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
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-message-operation (surface-id surface) "previous feedback"))
      (send! (make-text-input-event 'text (string->utf8 "a")))
      (send! (make-key-event 'enter 13 #f #f 0 'press (make-bytevector 0)))
      (send! (make-text-input-event 'text (string->utf8 "b")))
      (send! (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0)))
      (send! (make-key-event 'tab 9 #f #f 0 'press (make-bytevector 0)))
      (unless (and (string=? (buffer-string buffer) "a\n\t")
                   (not (surface-status-message surface))
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      3))
        (error 'fundamental-editing-tests
               "fundamental frontend input did not insert a tab or advance its caret"))
      (frontend-close! frontend)
      (soda-application-close! application))

    ;; The frontend attaches its current compatible layout to each command
    ;; context.  Wrapped C-n/C-p therefore use visual rows rather than
    ;; treating the one physical line as immobile.
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
      (frontend-resize! frontend '(4 . 4))
      (frontend-step! frontend)
      (send! (make-text-input-event 'text (string->utf8 "abcdefghijk")))
      (send! (make-key-event 'character (char->integer #\a) #f #f 4 'press
                             (make-bytevector 0)))
      (send! (make-key-event 'character (char->integer #\n) #f #f 4 'press
                             (make-bytevector 0)))
      (send! (make-key-event 'character (char->integer #\n) #f #f 4 'press
                             (make-bytevector 0)))
      (send! (make-key-event 'character (char->integer #\p) #f #f 4 'press
                             (make-bytevector 0)))
      (unless (and (string=? (buffer-string buffer) "abcdefghijk")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      4))
        (error 'fundamental-editing-tests
               "frontend did not pass its visual layout to vertical motion"))
      (frontend-close! frontend)
      (soda-application-close! application))))
