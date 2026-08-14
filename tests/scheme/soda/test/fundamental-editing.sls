(library (soda test fundamental-editing)
  (export run-fundamental-editing-tests!)
  (import (rnrs)
          (only (chezscheme) chmod delete-directory get-mode get-process-id mkdir)
          (soda bootstrap)
          (soda host command)
          (soda host command-runtime)
          (soda host condition)
          (soda host dispatch)
          (soda host frontend)
          (soda host feedback)
          (soda host input)
          (soda host input-event)
          (soda host analysis)
          (soda host location)
          (soda host package)
          (soda host prefix-guidance)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal mode)
          (soda host internal presentation)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal operation)
          (soda host render)
          (soda host internal view)
          (soda host internal window)
          (soda host render-service)
          (soda host value)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel location)
          (soda kernel mode)
          (soda kernel range-set)
          (soda kernel regex)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base fundamental-editing)
          (soda packages base editing-options)
          (soda packages base history)
          (soda packages base text-motion)
          (soda packages completion)
          (soda packages command-presentation)
          (soda packages file-path)
          (soda packages file-service)
          (soda packages file-format)
          (soda packages file-watch)
          (soda packages directory)
          (soda packages editor-options)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda packages generated-buffer)
          (soda packages buffer-item)
          (soda packages buffer-list)
          (soda packages window)
          (soda packages search)
          (soda packages scheme-mode)
          (soda packages message)
          (soda packages interaction)
          (soda packages input-history)
          (soda packages keyboard-macro)
          (soda packages minibuffer)
          (soda packages resource)
          (soda support vfs)
          (soda tui frontend)
          (soda tui terminal-input)
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

  (define (surface-feedback-text surface)
    (let ([feedback (surface-feedback surface)])
      (and feedback (user-feedback-text feedback))))

  (define (command-context-with-input-layers context layers)
    (make-command-context
      (command-context-invocation-id context)
      (command-context-surface-id context)
      (command-context-window-id context)
      (command-context-view-id context)
      (command-context-buffer-id context)
      (command-context-buffer-state context)
      (command-context-view-state context)
      (command-context-event context)
      (command-context-key-sequence context)
      (command-context-prefix-argument context)
      (command-context-target context)
      (command-context-source context)
      (command-context-layout context)
      layers))

  (define (invoke-viewport-command! application name layout)
    (let* ([state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [active (surface-active-context surface (host-state-views state))]
           [request #f]
           [registration
            (dispatcher-add-listener!
              (host-state-dispatch state) (host-state-owner state)
              (lambda (update)
                (when (editor-update-scroll-request update)
                  (set! request (editor-update-scroll-request update)))))])
      (command-runtime-start!
        (host-state-command-runtime state) name
        (application-command-context application layout))
      (registration-close! registration)
      (unless (and request
                   (host-frontend-resolve-scroll-request! state active layout request))
        (error 'fundamental-editing-tests
               "viewport command did not publish a resolvable display intent" name))))

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

  (define (frame-row-string frame row)
    (let loop ([column 0] [pieces '()])
      (if (= column (frame-width frame))
          (apply string-append (reverse pieces))
          (let ([cell (frame-cell-at frame row column)])
            (loop (+ column 1)
                  (if (frame-cell-continuation? cell)
                      pieces
                      (cons (frame-cell-grapheme cell) pieces)))))))

  (define (frame-cell-has-face? cell face)
    (let ([value (frame-cell-face cell)])
      (if (list? value)
          (memq face value)
          (eq? face value))))

  (define (run-fundamental-editing-tests!)
    (let ([history (make-input-history 2)])
      (input-history-add! history "first")
      (input-history-add! history "second")
      (input-history-add! history "first")
      (input-history-add! history "third")
      (unless (equal? (input-history-entries history) '("third" "first"))
        (error 'fundamental-editing-tests
               "InputHistory did not bound and promote accepted values")))
    ;; A frontend CommandContext retains the exact composed InputLayers.  Help
    ;; and M-x must describe that snapshot rather than recomposing fallback
    ;; layers and accidentally omitting a transient interaction binding.
    (let* ([application (make-soda-application)]
           [runtime (host-state-command-runtime (soda-application-state application))]
           [origin (application-command-context application)]
           [transient (make-keymap 'matrix-transient)]
           [_transient
            (keymap-bind!
              transient (list (make-key-stroke 'character (char->integer #\q) 0))
              'message.show-position)]
           [layers (list (make-input-layer 'transient transient #f 'ignore))]
           [snapshot-layers (input-layers-snapshot layers)]
           [_reconfigured
            (keymap-bind!
              transient (list (make-key-stroke 'character (char->integer #\r) 0))
              'message.show-position)]
           [context (command-context-with-input-layers origin snapshot-layers)]
           [access
            (command-context-command-access
              runtime context '()
              'message.show-position)]
           [resolved (resolve-key-sequence snapshot-layers
                                           (list (make-key-stroke 'character
                                                                  (char->integer #\q) 0)))]
           [late-binding (resolve-key-sequence snapshot-layers
                                               (list (make-key-stroke 'character
                                                                      (char->integer #\r) 0)))])
      (unless (and access
                   (equal? (map key-sequence-name
                                (command-access-key-sequences access))
                           '("q"))
                   (eq? (car resolved) 'command)
                   (eq? (cadr resolved) 'message.show-position)
                   (eq? (car late-binding) 'unbound))
        (error 'fundamental-editing-tests
               "command presentation diverged from the frontend InputLayer snapshot"))
      (soda-application-close! application))
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
            (buffer-input-context
              (surface-active-context (soda-application-surface application)
                                      (host-state-views state))
              view (list (fundamental-fallback-input-layer editing)))]
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
           [yank
            (input-dispatch
              context (make-key-event 'character (char->integer #\y) #f #f 4 'press
                                      (make-bytevector 0)))]
           [kill-line
            (input-dispatch
              context (make-key-event 'character (char->integer #\k) #f #f 4 'press
                                      (make-bytevector 0)))]
           [control-j
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
           [file-map (file-keymap (soda-application-files application))]
           [buffer-list-map
            (buffer-list-keymap (soda-application-buffer-lists application))]
           [directory-map
            (directory-keymap (soda-application-directories application))])
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
                   (eq? (input-disposition-value yank) 'fundamental.yank)
                   (eq? (input-disposition-value kill-line) 'fundamental.kill-line)
                   (eq? (input-disposition-value control-j) 'fundamental.newline)
                   (eq? (input-disposition-value set-mark) 'fundamental.set-mark)
                   (eq? (command-invocation-phase redraw) 'completed)
                   (= (surface-generation surface) (+ before-surface-generation 1))
                   (eq? (keymap-lookup
                          (fundamental-editing-keymap editing)
                          (list (make-key-stroke 'character (char->integer #\l) 4)))
                        'fundamental.recenter)
                   (eq? (keymap-lookup
                          file-map
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\i) 0)))
                         'file.insert)
                   (eq? (keymap-lookup
                          file-map
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\k) 0)))
                        'buffer.kill)
                   (not (keymap-lookup
                          file-map
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\k) 4))))
                   (eq? (keymap-lookup
                          buffer-list-map
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\b) 0)))
                        'buffer.list)
                   (eq? (keymap-lookup
                          buffer-list-map
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\b) 4)))
                        'buffer.switch)
                   (eq? (keymap-lookup
                          directory-map
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\d) 0)))
                        'directory.browse)
                   (eq? (keymap-lookup
                          (fundamental-editing-keymap editing)
                          (list (make-key-stroke 'character (char->integer #\x) 4)
                                (make-key-stroke 'character (char->integer #\h) 0)))
                        'fundamental.mark-whole-buffer)
                   (eq? (keymap-lookup
                          file-map
                          (list (make-key-stroke 'character (char->integer #\r) 2)))
                         'file.revert))
        (error 'fundamental-editing-tests
               "fundamental editing did not produce stable editor state"))
      (let* ([active (surface-active-context surface (host-state-views state))]
             [active-view
              (view-service-ref
                (host-state-views state) (active-context-view-id active))]
             [input-context
              (soda-application-resolve-input-context application active active-view)]
             [prefix
              (input-dispatch
                input-context
                (make-key-event 'character (char->integer #\x) #f #f 4 'press
                                (make-bytevector 0)))]
             [continued
              (input-context-with-translation
                (make-input-context
                  (input-context-view-id input-context)
                  (input-context-buffer-id input-context)
                  (input-context-layers input-context)
                  (input-disposition-input-state prefix))
                (input-context-translation input-context))]
             [former-universal
              (input-dispatch
                continued
                (make-key-event 'character (char->integer #\u) #f #f 4 'press
                                (make-bytevector 0)))])
        (unless (and (eq? (input-disposition-kind prefix) 'consume)
                     (eq? (input-disposition-kind former-universal) 'undefined))
          (error 'fundamental-editing-tests
                 "C-x C-u retained a non-Emacs universal-argument binding")))
      (command-runtime-start-interactive!
        runtime 'buffer.kill (application-command-context application))
      (let ([request
             (interaction-session-request
               (interaction-service-current (soda-application-interaction application)))])
        (unless (and (eq? (interaction-request-kind request) 'discard-decision)
                     (string=? (interaction-request-prompt request)
                               "Discard changes to *scratch*?")
                     (= (length (interaction-request-actions request)) 2)
                     (eq? (choice-action-id
                            (interaction-request-default-action request))
                          'cancel))
          (error 'fundamental-editing-tests
                 "buffer.kill did not protect a modified unvisited Buffer")))
      (interaction-service-submit!
        (soda-application-interaction application) 'cancel)
      (host-state-run! state)
      (unless (buffer-service-ref (host-state-buffers state) (buffer-id buffer) #f)
        (error 'fundamental-editing-tests
               "cancelling buffer.kill discarded the modified scratch Buffer"))
      (soda-application-close! application))

    ;; Window commands use one Host-owned placement path: splitting creates a
    ;; distinct View of the same Buffer, `other-window` moves focus without
    ;; changing either View, and deletion retires only the removed View.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [surface (soda-application-surface application)]
           [primary-view (soda-application-view application)]
           [primary-context (application-command-context application)]
           [window-map (window-keymap (soda-application-windows application))])
      (let* ([active (surface-active-context surface (host-state-views state))]
             [input-context
              (soda-application-resolve-input-context application active primary-view)]
             [prefix
              (input-dispatch
                input-context
                (make-key-event 'character (char->integer #\x) #f #f 4 'press
                                (make-bytevector 0)))]
             [continued
              (input-context-with-translation
                (make-input-context
                  (input-context-view-id input-context)
                  (input-context-buffer-id input-context)
                  (input-context-layers input-context)
                  (input-disposition-input-state prefix))
                (input-context-translation input-context))]
             [split
              (input-dispatch
                continued
                (make-key-event 'character (char->integer #\2) #f #f 0 'press
                                (make-bytevector 0)))])
        (unless (and (eq? (input-disposition-kind split) 'command)
                     (eq? (input-disposition-value split) 'window.split-below))
          (error 'fundamental-editing-tests
                 "application input composition did not dispatch C-x 2")))
      (command-runtime-start!
        runtime 'fundamental.end-of-buffer (application-command-context application))
      (let* ([before-state (view-state primary-view)]
             [_split
              (command-runtime-start!
                runtime 'window.split-below (application-command-context application))]
             [leaves (window-leaves (surface-root-window surface))]
             [active (surface-active-context surface (host-state-views state))]
             [secondary-leaf
              (find (lambda (leaf) (not (= (window-view-id leaf) (view-id primary-view))))
                    leaves)]
             [secondary
              (and secondary-leaf
                   (view-service-ref (host-state-views state)
                                     (window-view-id secondary-leaf) #f))])
        (unless (and (= (length leaves) 2)
                     (= (active-context-view-id active) (view-id primary-view))
                     secondary
                     (= (buffer-id (view-buffer secondary))
                        (buffer-id (view-buffer primary-view)))
                     (equal? (view-state-selection (view-state secondary))
                             (view-state-selection before-state))
                     (equal? (view-state-viewport (view-state secondary))
                             (view-state-viewport before-state))
                     (eq? (keymap-lookup
                            window-map
                            (list (make-key-stroke 'character (char->integer #\x) 4)
                                  (make-key-stroke 'character (char->integer #\2) 0)))
                          'window.split-below)
                     (eq? (keymap-lookup
                            window-map
                            (list (make-key-stroke 'character (char->integer #\x) 4)
                                  (make-key-stroke 'character (char->integer #\3) 0)))
                          'window.split-right)
                     (eq? (keymap-lookup
                            window-map
                            (list (make-key-stroke 'character (char->integer #\x) 4)
                                  (make-key-stroke 'character (char->integer #\o) 0)))
                          'window.other)
                     (eq? (keymap-lookup
                            window-map
                            (list (make-key-stroke 'character (char->integer #\x) 4)
                                  (make-key-stroke 'character (char->integer #\0) 0)))
                          'window.delete)
                     (eq? (keymap-lookup
                            window-map
                            (list (make-key-stroke 'character (char->integer #\x) 4)
                                  (make-key-stroke 'character (char->integer #\1) 0)))
                          'window.delete-others))
          (error 'fundamental-editing-tests
                 "window.split-below did not create a cloned independent View"))
        (command-runtime-start!
          runtime 'window.other (application-command-context application))
        (unless (= (command-context-view-id (application-command-context application))
                   (view-id secondary))
          (error 'fundamental-editing-tests "window.other did not select the sibling View"))
        ;; A delayed command cannot redirect a split into the newly selected
        ;; sibling: Window placement remains bound to its original context.
        (command-runtime-start! runtime 'window.split-right primary-context)
        (unless (= (length (window-leaves (surface-root-window surface))) 2)
          (error 'fundamental-editing-tests
                 "a stale window command split the newly selected Window"))
        (command-runtime-start!
          runtime 'window.delete (application-command-context application))
        (unless (and (= (length (window-leaves (surface-root-window surface))) 1)
                     (= (command-context-view-id (application-command-context application))
                        (view-id primary-view))
                     (not (view-service-ref (host-state-views state) (view-id secondary) #f)))
          (error 'fundamental-editing-tests
                 "window.delete did not retire only the selected View"))
        (command-runtime-start!
          runtime 'window.split-right (application-command-context application))
        (command-runtime-start!
          runtime 'window.delete-others (application-command-context application))
        (unless (= (length (window-leaves (surface-root-window surface))) 1)
          (error 'fundamental-editing-tests
                 "window.delete-others did not preserve exactly one Window")))
      (soda-application-close! application))

    ;; Override commands remain reachable while an ordinary key prefix is
    ;; pending.  This is the input contract used by keyboard.quit; the host
    ;; does not special-case C-g or any other physical key.
    (let* ([prefix-map (make-keymap 'prefix-test)]
           [override-map (make-keymap 'override-test)]
           [control (lambda (character)
                      (make-key-stroke 'character (char->integer character) 4))]
           [_prefix-binding
            (keymap-bind! prefix-map
                          (list (control #\x) (control #\f)) 'file.visit)]
           [_quit-binding
            (keymap-bind! override-map (list (control #\g)) 'keyboard.quit)]
           [layers
            (input-layer-compose
              (list (make-input-layer 'global prefix-map #f 'pass)
                    (make-input-layer 'override override-map #f 'ignore)))]
           [context (make-input-context 0 0 layers)]
           [prefix
            (input-dispatch
              context
              (make-key-event 'character (char->integer #\x) #f #f 4 'press
                              (make-bytevector 0)))]
           [pending-context
            (make-input-context
              0 0 layers (input-disposition-input-state prefix))]
           [quit
            (input-dispatch
              pending-context
              (make-key-event 'character (char->integer #\g) #f #f 4 'press
                              (make-bytevector 0)))])
      (unless (and (eq? (input-disposition-kind prefix) 'consume)
                   (eq? (input-disposition-kind quit) 'command)
                   (eq? (input-disposition-value quit) 'keyboard.quit)
                   (not (input-stack-pending-sequence
                          (input-disposition-input-state quit))))
        (error 'fundamental-editing-tests
               "override command did not interrupt a pending prefix")))

    ;; A directory is a generated Buffer: item activation queues the next
    ;; ordinary file/directory command instead of giving the browser a custom
    ;; event loop.  Refresh republishes the same Buffer projection.
    (let* ([root (string-append "/tmp/soda-directory-browser-"
                                (number->string (get-process-id)))]
           [nested (string-append root "/nested")]
           [note (string-append root "/note.txt")]
           [new-note (string-append root "/new.txt")]
           [renamed-note (string-append root "/renamed.txt")]
           [created (string-append root "/created")]
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
            (command-runtime-start! runtime 'file.visit
                                    (application-command-context application)
                                    (list new-note))
            (command-runtime-start! runtime 'directory.browse
                                    (application-command-context application) (list root))
            (command-runtime-start! runtime 'directory.refresh
                                    (application-command-context application))
            (let* ([refreshed-active
                    (surface-active-context surface (host-state-views state))]
                   [refreshed-buffer
                    (buffer-service-ref (host-state-buffers state)
                                        (active-context-buffer-id refreshed-active))])
              (unless (string-contains? (buffer-string refreshed-buffer) "new.txt")
                (error 'fundamental-editing-tests "directory refresh did not republish entries"))
              (command-runtime-start!
                runtime 'directory.create-directory
                (application-command-context application) (list "created"))
              (command-runtime-start!
                runtime 'directory.rename
                (application-command-context application)
                (list new-note "renamed.txt"))
              (unless (and (vfs-directory-exists? created)
                           (vfs-file-exists? renamed-note)
                           (not (vfs-file-exists? new-note))
                           (let ([visited
                                  (buffer-service-find-key
                                    (host-state-buffers state)
                                    (make-buffer-key 'file renamed-note) #f)])
                             (and visited
                                  (string=?
                                    (resource-locator
                                      (file-service-resource
                                        (soda-application-files application)
                                        (buffer-id visited)))
                                    renamed-note)))
                           (string-contains? (buffer-string refreshed-buffer)
                                             "renamed.txt"))
                (error 'fundamental-editing-tests
                       "directory mutations did not refresh the browser"))
              (let* ([current
                      (surface-active-context surface (host-state-views state))]
                     [current-view
                      (view-service-ref
                        (host-state-views state) (active-context-view-id current))])
                (dispatcher-dispatch-view!
                  (host-state-dispatch state)
                  (make-view-transaction-spec
                    (view-id current-view)
                    (view-state-generation (view-state current-view))
                    (make-selection (list (make-selection-range 0 0)))
                    #f #f '() '() #f)))
              ;; parent, created/, nested/, note.txt, renamed.txt
              (do ([index 0 (+ index 1)])
                  ((= index 5))
                (command-runtime-start!
                  runtime 'buffer.next-item
                  (application-command-context application)))
              (command-runtime-start-interactive!
                runtime 'directory.delete
                (application-command-context application))
              (let ([interaction (soda-application-interaction application)])
                (unless (interaction-service-current interaction)
                  (error 'fundamental-editing-tests
                         "directory deletion did not request confirmation"))
                ;; The confirmation retains the selected filesystem identity.
                ;; Replacing that name must not delete the replacement.
                (delete-file renamed-note)
                (vfs-write-file renamed-note (string->utf8 "replacement"))
                (interaction-service-submit! interaction 'delete)
                (host-state-run! state))
              (unless (and (vfs-file-exists? renamed-note)
                           (bytevector=? (vfs-read-file renamed-note)
                                         (string->utf8 "replacement")))
                (error 'fundamental-editing-tests
                       "stale directory deletion removed a replacement"))
              (command-runtime-start!
                runtime 'directory.delete
                (application-command-context application)
                (list renamed-note 'delete))
              (unless (and (not (vfs-file-exists? renamed-note))
                           (not (string-contains? (buffer-string refreshed-buffer)
                                                  "renamed.txt")))
                (error 'fundamental-editing-tests
                       "fresh directory deletion was not published")))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file renamed-note))
          (guard (condition [else #f]) (delete-file new-note))
          (guard (condition [else #f]) (delete-file note))
          (guard (condition [else #f]) (delete-directory created #f))
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
                   [file-id (command-context-buffer-id file-context)]
                   [file-view-id (command-context-view-id file-context)])
              (command-runtime-start-interactive! runtime 'buffer.switch file-context)
              (let* ([request
                      (interaction-session-request (interaction-service-current interaction))]
                     [controller
                      (minibuffer-service-refresh-completion!
                        (soda-application-minibuffer application))])
                (unless (and (eq? (interaction-request-kind request) 'buffer)
                             (eq? (interaction-request-history-key request) 'buffer)
                             (eq? (interaction-request-selection-policy request) 'must-match)
                             (exists
                               (lambda (candidate)
                                 (string=? (completion-candidate-insert-text candidate)
                                           (buffer-name scratch)))
                               (completion-controller-candidates controller))
                             (exists
                               (lambda (candidate)
                                 (string=? (completion-candidate-insert-text candidate) path))
                               (completion-controller-candidates controller))
                             (not
                               (exists
                                 (lambda (candidate)
                                   (string=? (completion-candidate-insert-text candidate)
                                             " *minibuffer*"))
                                 (completion-controller-candidates controller))))
                  (error 'fundamental-editing-tests
                         "buffer.switch did not expose the live Surface Buffer catalog")))
              (interaction-service-submit! interaction (buffer-name scratch))
              (host-state-run! state)
              (unless (and (= (command-context-buffer-id
                                (application-command-context application))
                               (buffer-id scratch))
                           (= (command-context-view-id
                                (application-command-context application))
                               (view-id (soda-application-view application))))
                (error 'fundamental-editing-tests
                       "buffer.switch did not restore the scratch View"))
              (command-runtime-start-interactive!
                runtime 'buffer.switch (application-command-context application))
              (interaction-service-submit! interaction path)
              (host-state-run! state)
              (unless (and (= (command-context-buffer-id
                                (application-command-context application))
                               file-id)
                           (= (command-context-view-id
                                (application-command-context application))
                               file-view-id))
                (error 'fundamental-editing-tests
                       "buffer.switch did not restore the selected Buffer View"))
              (command-runtime-start!
                runtime 'buffer.bury (application-command-context application))
              (unless (and (= (command-context-buffer-id
                                (application-command-context application))
                               (buffer-id scratch))
                           (buffer-service-ref (host-state-buffers state) file-id #f))
                (error 'fundamental-editing-tests
                       "buffer.bury did not leave the selected Buffer alive"))
              (command-runtime-start-interactive!
                runtime 'buffer.switch (application-command-context application))
              (interaction-service-submit! interaction path)
              (host-state-run! state)
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
                               content (string-append ">*  " path))
                             (string-contains? content " bytes  Fundamental"))
                  (error 'fundamental-editing-tests
                         "buffer.list did not project live Buffer metadata" content))
                ;; The current file is first in Surface-relative MRU order.
                ;; Item activation replaces the list View with that Buffer's
                ;; previously used View.
                (command-runtime-start! runtime 'buffer.next-item
                                        (application-command-context application))
                (command-runtime-start! runtime 'buffer.activate-item
                                        (application-command-context application))
                (unless (= (command-context-buffer-id
                             (application-command-context application))
                           file-id)
                  (error 'fundamental-editing-tests
                         "buffer.list activation did not select its BufferItem target"))
                (unless (= (command-context-view-id
                             (application-command-context application))
                           file-view-id)
                  (error 'fundamental-editing-tests
                         "buffer.list activation did not restore the recent View"))
                (command-runtime-start! runtime 'buffer.list
                                        (application-command-context application))
                (unless (= (command-context-buffer-id
                             (application-command-context application))
                           list-id)
                  (error 'fundamental-editing-tests
                         "buffer.list did not reuse its canonical generated Buffer"))
                ;; `d` retains the Buffer List as the active context and
                ;; passes the selected row as an explicit close target. Select
                ;; the file row explicitly; the normal File package still
                ;; owns its save/discard prompt.
                (let* ([context (application-command-context application)]
                       [view (view-service-ref
                               (host-state-views state)
                               (command-context-view-id context))])
                  (dispatcher-dispatch-view!
                    (host-state-dispatch state)
                    (make-view-transaction-spec
                      (view-id view) (view-state-generation (view-state view))
                      (make-selection (list (make-selection-range 0 0)))
                      #f #f '() '() #f)))
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
                                                        "?"))
                               (= (length (interaction-request-actions request)) 3)
                               (eq? (choice-action-id
                                      (interaction-request-default-action request))
                                    'cancel)
                               (eq? (choice-action-role
                                      (cadr (interaction-request-actions request)))
                                    'destructive))
                    (error 'fundamental-editing-tests
                           "buffer.list close did not preserve the file save decision")))
                (unless
                  (guard (condition [else #t])
                    (interaction-service-submit! interaction 'unknown-action)
                    #f)
                  (error 'fundamental-editing-tests
                         "choice interaction accepted an undeclared action"))
                (minibuffer-service-submit!
                  (soda-application-minibuffer application))
                (host-state-run! state)
                (unless (and (buffer-service-ref
                               (host-state-buffers state) file-id #f)
                             (not (interaction-service-current interaction)))
                  (error 'fundamental-editing-tests
                         "default close action did not cancel safely"))
                (command-runtime-start! runtime 'buffer-list.close-item
                                        (application-command-context application))
                (host-state-run! state)
                (interaction-service-submit! interaction 'discard)
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

    ;; Replacing the initial scratch View with a file leaves scratch reusable
    ;; in the Buffer catalog.  Closing that file must return to the same
    ;; canonical scratch rather than manufacture another same-named Buffer.
    (let* ([path (string-append "/tmp/soda-scratch-fallback-"
                                (number->string (get-process-id)) ".txt")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda () (vfs-write-file path (string->utf8 "fallback")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [buffers (host-state-buffers state)]
                 [scratch (soda-application-buffer application)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application) (list path))
            (let ([file-id
                   (command-context-buffer-id
                     (application-command-context application))])
              (command-runtime-start!
                runtime 'buffer.kill (application-command-context application)
                (list file-id 'discard))
              (host-state-run! state)
              (let ([live-scratches
                     (filter
                       (lambda (buffer)
                         (string=? (buffer-name buffer) "*scratch*"))
                       (buffer-service-buffers buffers))])
                (unless (and (= (length live-scratches) 1)
                             (eq? (car live-scratches) scratch)
                             (eq? (buffer-service-find-key
                                    buffers (scratch-buffer-key) #f)
                                  scratch)
                             (= (command-context-buffer-id
                                  (application-command-context application))
                                (buffer-id scratch)))
                  (error 'fundamental-editing-tests
                         "file close did not reuse the canonical scratch Buffer"
                         (map buffer-id live-scratches)))))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file path)))))

    ;; Closing the current Buffer restores the previous presentation, including
    ;; its point, before falling back to the canonical scratch Buffer.
    (let* ([base (string-append "/tmp/soda-close-mru-"
                                (number->string (get-process-id)))]
           [first-path (string-append base "-first.txt")]
           [second-path (string-append base "-second.txt")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda ()
          (vfs-write-file first-path (string->utf8 "first"))
          (vfs-write-file second-path (string->utf8 "second")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application)
              (list first-path))
            (let* ([first-context (application-command-context application)]
                   [first-id (command-context-buffer-id first-context)]
                   [first-view-id (command-context-view-id first-context)])
              (command-runtime-start!
                runtime 'fundamental.end-of-buffer first-context)
              (command-runtime-start!
                runtime 'file.visit (application-command-context application)
                (list second-path))
              (let ([second-id
                     (command-context-buffer-id
                       (application-command-context application))])
                (command-runtime-start!
                  runtime 'buffer.kill (application-command-context application)
                  (list second-id 'discard))
                (host-state-run! state)
                (let ([active (application-command-context application)])
                  (unless (and (= (command-context-buffer-id active) first-id)
                               (= (command-context-view-id active) first-view-id)
                               (= (selection-range-head
                                    (selection-primary-range
                                      (view-state-selection
                                        (command-context-view-state active))))
                                  5))
                    (error 'fundamental-editing-tests
                           "closing a Buffer did not restore its MRU View")))))))
        (lambda ()
          (soda-application-close! application)
          (guard (condition [else #f]) (delete-file first-path))
          (guard (condition [else #f]) (delete-file second-path)))))

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

    ;; The default editing keymap follows the Emacs interaction contract.
    (let* ([application (make-soda-application)]
           [keymap (fundamental-editing-keymap (soda-application-editing application))]
           [meta (lambda (character)
                   (make-key-stroke 'character (char->integer character) 2))]
           [control (lambda (character)
                      (make-key-stroke 'character (char->integer character) 4))])
      (unless (and (eq? (keymap-lookup keymap (list (control #\y)))
                       'fundamental.yank)
                   (eq? (keymap-lookup keymap (list (meta #\<)))
                       'fundamental.beginning-of-buffer)
                   (eq? (keymap-lookup keymap (list (meta #\>)))
                       'fundamental.end-of-buffer)
                   (not (keymap-lookup keymap (list (control #\u)) #f))
                   (eq? (keymap-lookup keymap (list (control #\l)))
                       'fundamental.recenter)
                   (eq? (keymap-lookup keymap (list (meta #\r)))
                       'fundamental.move-to-window-center)
                   (eq? (keymap-lookup keymap (list (make-key-stroke 'up #f 0)))
                       'fundamental.previous-line)
                   (eq? (keymap-lookup keymap (list (make-key-stroke 'down #f 0)))
                       'fundamental.next-line))
        (error 'fundamental-editing-tests "Emacs editing bindings are inconsistent"))
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

    ;; Regexp mode is View-local.  It keeps the ordinary search,
    ;; repeat and replacement command lifecycle while changing only the
    ;; matcher to POSIX ERE.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)]
           [search (soda-application-search application)])
      (let ([text (string->text "foo12 bar123 foo9\nFOO42")]
            [regex (compile-regex "foo[0-9]+" #t)])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (unless (and (equal? (regex-find regex text 0 (text-size text) 'forward)
                                  (cons 0 5))
                         (equal? (regex-find regex text 0 (text-size text) 'backward)
                                  (cons 13 17))
                         (equal? (regex-collect regex text 0 (text-size text))
                                 (list (cons 0 5) (cons 13 17))))
              (error 'fundamental-editing-tests "native ERE matcher did not return expected ranges")))
          (lambda ()
            (regex-close! regex)
            (text-close! text))))
      (command-runtime-start! runtime 'fundamental.insert-text
                              (application-command-context application)
                              (list (string->utf8 "foo12 bar123 foo9\nFOO42")))
      (command-runtime-start! runtime 'fundamental.beginning-of-buffer
                              (application-command-context application))
      (command-runtime-start! runtime 'search.toggle-regular-expression
                              (application-command-context application))
      (command-runtime-start! runtime 'search.forward
                              (application-command-context application) (list "foo[0-9]+"))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 0)
                     (= (selection-range-to range) 5))
          (error 'fundamental-editing-tests "regexp search did not select its first ERE match")))
      (command-runtime-start! runtime 'search.next (application-command-context application))
      (let ([range (selection-primary-range (view-state-selection (view-state view)))])
        (unless (and (= (selection-range-from range) 13)
                     (= (selection-range-to range) 17))
          (error 'fundamental-editing-tests "regexp repeat did not retain ERE policy")))
      (command-runtime-start! runtime 'search.toggle-case-sensitive
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.beginning-of-buffer
                              (application-command-context application))
      (command-runtime-start! runtime 'search.replace-all
                              (application-command-context application) (list "foo[0-9]+" "item"))
      (unless (and (string=? (buffer-string buffer) "item bar123 item\nitem")
                   (eq? (keymap-lookup
                          (search-keymap search)
                          (list (make-key-stroke 'character (char->integer #\r) 2)))
                        'search.toggle-regular-expression))
        (error 'fundamental-editing-tests "regexp replacement or key binding is incorrect"))
      (soda-application-close! application))

    ;; A delayed feedback outcome is attached to the command's active input
    ;; target.  Replacing that target with Help makes the outcome stale rather
    ;; than letting it overwrite the echo area in the new interaction.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [host (make-package-host state)]
           [surface (soda-application-surface application)]
           [origin (application-command-context application)])
      (command-runtime-start! runtime 'help.show origin)
      (unless (and (not (package-host-publish-feedback-if-current!
                          host origin (make-user-feedback "stale feedback" 'info)))
                   (not (surface-feedback surface)))
        (error 'fundamental-editing-tests
               "stale contextual feedback interrupted the replacement View"))
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
      (command-runtime-start! runtime 'fundamental.kill-whole-line
                              (application-command-context application))
      (unless (and (string=? (buffer-string buffer) "first\nthird")
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      6))
        (error 'fundamental-editing-tests
               "kill-whole-line did not kill the complete current logical line"))
      (command-runtime-start! runtime 'fundamental.set-mark
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.forward-char
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.kill-whole-line
                              (application-command-context application))
      (unless (string=? (buffer-string buffer) "first\nhird")
        (error 'fundamental-editing-tests
               "kill-whole-line did not preserve active-region semantics"))
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
                     (string-contains? (buffer-string help-buffer) "C-x C-f")
                     (string-contains? (buffer-string help-buffer) "M-x buffer.bury")
                     (not (string-contains?
                            (buffer-string help-buffer) "buffer.quit")))
          (error 'fundamental-editing-tests "help.show did not display contextual command help"))
        (let ([rejected?
               (guard (condition [else #t])
                 (command-runtime-start!
                   runtime 'fundamental.insert-text
                   (application-command-context application)
                   (list (string->utf8 "mutate")))
                 #f)])
          (unless (and rejected?
                       (not (string-contains? (buffer-string help-buffer) "mutate")))
            (error 'fundamental-editing-tests
                   "help mode exposed an ordinary editing command")))
        (command-runtime-start!
          runtime 'help.show (application-command-context application))
        (unless (and (= (buffer-id help-buffer)
                        (command-context-buffer-id
                          (application-command-context application)))
                     (string-contains?
                       (buffer-string help-buffer) "buffer.quit")
                     (not (string-contains?
                            (buffer-string help-buffer) "buffer.next-item")))
          (error 'fundamental-editing-tests
                 "help Buffer exposed item commands without item capability")))
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
        (unless (and (string=? (surface-feedback-text surface) "Line 1, column 1")
                     (eq? (keymap-lookup
                            (message-keymap messages)
                            (list (make-key-stroke 'character (char->integer #\c) 4)))
                          'message.show-position)
                     (string=? (frame-cell-grapheme (frame-cell-at frame row 0)) "L")
                     (eq? (frame-cell-face (frame-cell-at frame row 0)) 'message))
          (error 'fundamental-editing-tests
                 "position command did not publish echo-area feedback")))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "alpha β\ngamma")))
      (let* ([frame
              (surface-render-frame
                (render-surface
                  surface (host-state-views state)
                  (host-state-presentations state)))]
             [row (- (frame-height frame) 2)])
        (unless (and (string-prefix? "**--  *scratch*   Fund"
                                     (frame-row-string frame row))
                     (eq? (frame-cell-face (frame-cell-at frame row 0))
                          'mode-line))
          (error 'fundamental-editing-tests
                 "mode line did not project modified Buffer state")))
      (command-runtime-start! runtime 'history.undo
                              (application-command-context application))
      (let* ([frame
              (surface-render-frame
                (render-surface
                  surface (host-state-views state)
                  (host-state-presentations state)))]
             [row (- (frame-height frame) 2)])
        (unless (string-prefix? "----  *scratch*"
                                (frame-row-string frame row))
          (error 'fundamental-editing-tests
                 "mode line did not clear modified state at the save point")))
      (command-runtime-start! runtime 'history.redo
                              (application-command-context application))
      (command-runtime-start! runtime 'editor.toggle-read-only
                              (application-command-context application))
      (let* ([frame
              (surface-render-frame
                (render-surface
                  surface (host-state-views state)
                  (host-state-presentations state)))]
             [row (- (frame-height frame) 2)])
        (unless (string-prefix? "**%%  *scratch*"
                                (frame-row-string frame row))
          (error 'fundamental-editing-tests
                 "mode line did not project read-only policy")))
      (command-runtime-start! runtime 'editor.toggle-read-only
                              (application-command-context application))
      (command-runtime-start! runtime 'fundamental.beginning-of-buffer
                              (application-command-context application))
      (let* ([service (make-render-service)]
             [first
              (render-service-render!
                service surface (host-state-views state)
                (host-state-presentations state))])
        (command-runtime-start! runtime 'fundamental.forward-char
                                (application-command-context application))
        (let* ([second
                (render-service-render!
                  service surface (host-state-views state)
                  (host-state-presentations state))]
               [row (- (frame-height (surface-render-frame second)) 2)])
          (unless (and
                    (eq? (rendered-view-layout
                           (car (surface-render-rendered-views first)))
                         (rendered-view-layout
                           (car (surface-render-rendered-views second))))
                    (string-contains?
                      (frame-row-string (surface-render-frame second) row)
                      "L1 C2"))
            (error 'fundamental-editing-tests
                   "caret fast path did not retarget mode-line position"))))
      (command-runtime-start! runtime 'message.count-words
                              (application-command-context application))
      (unless (and (string=? (surface-feedback-text surface)
                           "2 lines, 3 words, 13 characters")
                   (eq? (keymap-lookup
                          (message-keymap messages)
                          (list (make-key-stroke 'character (char->integer #\d) 3)))
                        'message.count-words))
        (error 'fundamental-editing-tests
               "word count did not use the active Buffer's Unicode text"))
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-feedback-operation
          (surface-id surface) (make-user-feedback "界")))
      (let* ([frame (surface-render-frame (render-surface surface (host-state-views state)))]
             [row (- (frame-height frame) 1)])
        (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame row 0)) "界")
                     (= (frame-cell-width (frame-cell-at frame row 0)) 2)
                     (frame-cell-continuation? (frame-cell-at frame row 1)))
          (error 'fundamental-editing-tests
                 "echo-area feedback did not preserve wide grapheme cells")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [buffer (soda-application-buffer application)]
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
               (list (make-key-stroke 'character (char->integer #\s) 3)))
             'search.previous)
        (error 'fundamental-editing-tests "Meta-Shift-s did not bind reverse search repetition"))
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
                   (= (length
                        (interaction-request-actions
                          (interaction-session-request
                            (interaction-service-current interaction))))
                      4)
                   (string-contains?
                     (interaction-request-display-prompt
                       (interaction-session-request
                         (interaction-service-current interaction)))
                     "[y] Replace")
                   (not
                     (interaction-request-default-action
                       (interaction-session-request
                         (interaction-service-current interaction))))
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
                     (eq? (input-disposition-value disposition) 'interaction.submit-key))
          (error 'fundamental-editing-tests
                 "query replace prompt did not install its discrete answer keymap"))
        (command-runtime-start-interactive!
          runtime 'interaction.submit-key context))
      (host-state-run! state)
      (unless (and (string=? (buffer-string buffer) "1 one one")
                   (interaction-service-current interaction)
                   (let ([range (selection-primary-range
                                  (view-state-selection (view-state view)))])
                     (and (= (selection-range-from range) 2)
                          (= (selection-range-to range) 5))))
        (error 'fundamental-editing-tests "query replace did not advance after replace"))
      (interaction-service-submit! interaction 'skip)
      (host-state-run! state)
      (unless (and (string=? (buffer-string buffer) "1 one one")
                   (interaction-service-current interaction)
                   (let ([range (selection-primary-range
                                  (view-state-selection (view-state view)))])
                     (and (= (selection-range-from range) 6)
                          (= (selection-range-to range) 9))))
        (error 'fundamental-editing-tests "query replace did not advance after skip"))
      (interaction-service-submit! interaction 'replace-all)
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
           [completion-events '()]
           [preview-snapshot #f]
           [restored-snapshot #f]
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
                   (string=? setup-input "accepted")
                   (= (prompt-snapshot-point
                        (minibuffer-session-snapshot
                          minibuffer (minibuffer-service-current minibuffer)))
                      8))
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
                      (view-projection-transform-display-stream
                        (view-projection prompt-view) (make-display-stream '()))])
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
      ;; Temporary prompt Views inherit the package-owned basic editing map
      ;; through the ordinary Buffer input composition.  Exercise the frontend
      ;; path so named keys are not masked by working text input.
      (let* ([editing (soda-application-editing application)]
             [surface (soda-application-surface application)]
             [frontend
              (make-frontend
                state surface
                (lambda (active prompt-view)
                  (minibuffer-input-context
                    minibuffer active prompt-view
                    (list (fundamental-fallback-input-layer editing))))
                (lambda (context disposition)
                  (fundamental-input-disposition context disposition))
                (lambda (render theme) #f)
                (make-render-service) default-theme)])
        (define (send! event)
          (frontend-enqueue!
            frontend (make-surface-input-message (surface-id surface) event))
          (frontend-step! frontend))
        (send! (make-text-input-event 'text (string->utf8 "x")))
        (send! (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0)))
        (unless (string=?
                  (prompt-snapshot-input
                    (minibuffer-session-snapshot
                      minibuffer (minibuffer-service-current minibuffer)))
                  "accepted")
          (error 'fundamental-editing-tests
                 "minibuffer did not inherit basic named-key editing"))
        (frontend-close! frontend))
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
                   (eq? (interaction-session-status session) 'accepted)
                   (string=? exit-input "acceptedé")
                   (equal? (reverse events) '(opened accepted)))
        (error 'fundamental-editing-tests "interaction submission did not resume through the queue"))
      ;; A required prompt adapter must not leave an invocation suspended when
      ;; its presentation target is unavailable.
      (let* ([root-view (soda-application-view application)]
             [root-buffer (soda-application-buffer application)]
             [surface (soda-application-surface application)]
             [active (surface-active-context surface (host-state-views state))]
             [invalid-context
              (make-command-context
                #f (surface-id surface)
                (active-context-window-id active)
                (+ 1000 (view-id root-view)) (buffer-id root-buffer)
                (buffer-state root-buffer) (view-state root-view)
                #f '() #f active 'missing-prompt-surface)]
             [failed-invocation
              (command-runtime-start-interactive!
                runtime 'interaction.package-test invalid-context)])
        (host-state-run! state)
        (unless (and (not (interaction-service-current interaction))
                     (not (minibuffer-service-current minibuffer))
                     (string=? (surface-feedback-text surface)
                               "Unable to open minibuffer")
                     (not (command-runtime-invocation
                            runtime
                            (command-invocation-id failed-invocation)
                            #f)))
          (error 'fundamental-editing-tests
                 "failed prompt presentation left an invocation suspended")))
      (let* ([unicode-reader
              (make-interactive-reader
                'file-name
                (lambda (context arguments)
                  (make-interactive-suspend
                    (make-interaction-request
                      'file-name "Path: " "目录/" #f 'free)
                    (lambda (value) (make-interactive-ready (list value))))))]
             [_unicode-command
              (command-runtime-register-command!
                runtime
                (make-command-definition
                  'interaction.unicode-initial-test
                  (lambda (context value) (command-handled))
                  owner "Unicode initial prompt test" 'test
                  (make-interactive-plan (list unicode-reader))))])
        (command-runtime-start-interactive!
          runtime 'interaction.unicode-initial-test
          (application-command-context application))
        (let* ([prompt-session (minibuffer-service-current minibuffer)]
               [snapshot (minibuffer-session-snapshot minibuffer prompt-session)]
               [range (selection-primary-range
                        (prompt-snapshot-selection snapshot))])
          (unless (and (string=? (prompt-snapshot-input snapshot) "目录/")
                       (= (prompt-snapshot-point snapshot) 3)
                       (= (selection-range-head range) 7))
            (error 'fundamental-editing-tests
                   "Unicode initial prompt did not place point at its logical end")))
        (minibuffer-service-cancel! minibuffer)
        (host-state-run! state))
      (let* ([long-value (make-string 48 #\x)]
             [long-reader
              (make-interactive-reader
                'read-long-initial
                (lambda (context arguments)
                  (make-interactive-suspend
                    (make-interaction-request
                      'string "Long: " long-value #f 'free)
                    (lambda (value) (make-interactive-ready (list value))))))]
             [_long-command
              (command-runtime-register-command!
                runtime
                (make-command-definition
                  'interaction.long-initial-test
                  (lambda (context value) (command-handled))
                  owner "Long initial prompt test" 'test
                  (make-interactive-plan (list long-reader))))]
             [surface (soda-application-surface application)]
             [editing (soda-application-editing application)]
             [presented '()]
             [frontend
              (make-frontend
                state surface
                (lambda (active prompt-view)
                  (soda-application-resolve-input-context
                    application active prompt-view))
                (lambda (context disposition)
                  (fundamental-input-disposition context disposition))
                (lambda (render theme)
                  (set! presented (cons render presented)))
                (make-render-service) default-theme)])
        (define (send-escape!)
          (frontend-enqueue!
            frontend
            (make-surface-input-message
              (surface-id surface)
              (make-key-event
                'escape 27 #f #f 0 'press (make-bytevector 0))))
          (frontend-step! frontend))
        (define (prompt-pending-length)
          (let* ([session (minibuffer-service-current minibuffer)]
                 [view
                  (and session
                       (view-service-ref
                         (host-state-views state)
                         (minibuffer-session-view-id session)))])
            (and view
                 (length
                   (or (input-stack-pending-sequence
                         (view-state-input-state (view-state view)))
                       '())))))
        (frontend-resize! frontend '(80 . 5))
        (frontend-step! frontend)
        (set! presented '())
        (command-runtime-start-interactive!
          runtime 'interaction.long-initial-test
          (application-command-context application))
        (frontend-step! frontend)
        (set! presented '())
        (frontend-resize! frontend '(12 . 5))
        (frontend-step! frontend)
        (let* ([prompt-session (minibuffer-service-current minibuffer)]
               [prompt-view
                (view-service-ref
                  (host-state-views state)
                  (minibuffer-session-view-id prompt-session))]
               [render (and (pair? presented) (car presented))]
               [rendered
                (and render
                     (find
                       (lambda (item)
                         (= (rendered-view-view-id item)
                            (view-id prompt-view)))
                       (surface-render-rendered-views render)))]
               [cursor-row (and render (surface-render-cursor-row render))])
          (unless (and (= (length presented) 1)
                       rendered cursor-row
                       (<= (car (rendered-view-rectangle rendered))
                           cursor-row
                           (- (+ (car (rendered-view-rectangle rendered))
                                 (cadddr (rendered-view-rectangle rendered)))
                              1))
                       (positive?
                         (viewport-visual-row
                           (view-state-viewport (view-state prompt-view)))))
            (error 'fundamental-editing-tests
                   "long initial prompt exposed an off-screen provisional frame"
                   (length presented) cursor-row)))
        (send-escape!)
        (unless (and (minibuffer-service-current minibuffer)
                     (= (prompt-pending-length) 1))
          (error 'fundamental-editing-tests
                 "single ESC cancelled the minibuffer instead of entering a prefix"))
        (send-escape!)
        (unless (and (minibuffer-service-current minibuffer)
                     (= (prompt-pending-length) 2))
          (error 'fundamental-editing-tests
                 "second ESC did not continue the application quit prefix"))
        (send-escape!)
        (unless (and (not (minibuffer-service-current minibuffer))
                     (not (interaction-service-current interaction))
                     (string=? (surface-feedback-text surface) "Quit"))
          (error 'fundamental-editing-tests
                 "ESC ESC ESC did not run the application-wide quit command"))
        (frontend-resize! frontend '(80 . 5))
        (frontend-step! frontend)
        (command-runtime-start!
          runtime 'fundamental.insert-text
          (application-command-context application)
          (list (string->utf8 long-value)))
        (frontend-step! frontend)
        (set! presented '())
        (frontend-resize! frontend '(12 . 5))
        (frontend-step! frontend)
        (let* ([root-view (soda-application-view application)]
               [render (and (pair? presented) (car presented))]
               [rendered
                (and render
                     (find
                       (lambda (item)
                         (= (rendered-view-view-id item) (view-id root-view)))
                       (surface-render-rendered-views render)))]
               [cursor-row (and render (surface-render-cursor-row render))])
          (unless (and (= (length presented) 1)
                       rendered cursor-row
                       (<= (car (rendered-view-rectangle rendered))
                           cursor-row
                           (- (+ (car (rendered-view-rectangle rendered))
                                 (cadddr (rendered-view-rectangle rendered)))
                              1))
                       (positive?
                         (viewport-visual-row
                           (view-state-viewport (view-state root-view)))))
            (error 'fundamental-editing-tests
                   "root View resize did not reveal its active point"
                   (length presented) cursor-row)))
        (command-runtime-start!
          runtime 'fundamental.mark-whole-buffer
          (application-command-context application))
        (command-runtime-start!
          runtime 'fundamental.delete-backward
          (application-command-context application))
        (frontend-step! frontend)
        (frontend-resize! frontend '(80 . 24))
        (frontend-close! frontend))
      (let* ([source
              (make-completion-source
                (lambda (snapshot)
                  (if (string=? (prompt-snapshot-input snapshot) "allowed")
                      (list
                        (make-completion-candidate
                          'allowed "allowed" "allowed" #f #f #f))
                      '()))
                (lambda (candidate snapshot)
                  (set! preview-snapshot snapshot)
                  (set! completion-events (cons 'preview completion-events)))
                (lambda (snapshot)
                  (set! restored-snapshot snapshot)
                  (set! completion-events (cons 'restore completion-events)))
                (lambda (candidate snapshot)
                  (set! completion-events (cons 'accept completion-events))
                  (assertion-violation
                    'completion-finalizer-test "accept callback failure"))
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
            (error 'fundamental-editing-tests "completion refresh preselected a candidate"))
          (let* ([surface (soda-application-surface application)]
                 [windows (surface-interaction-windows surface)]
                 [prompt (find
                           (lambda (window) (eq? (window-purpose window) 'prompt))
                           windows)]
                 [companion
                  (find
                    (lambda (window)
                      (let ([purpose (window-purpose window)])
                        (and (pair? purpose)
                             (eq? (car purpose) 'companion))))
                    windows)]
                 [render (render-surface surface (host-state-views state))]
                 [root-rendered
                  (find
                    (lambda (item)
                      (= (rendered-view-view-id item)
                         (view-id (soda-application-view application))))
                    (surface-render-rendered-views render))]
                 [companion-rendered
                  (and companion
                       (find
                         (lambda (item)
                           (= (rendered-view-view-id item)
                              (window-view-id companion)))
                         (surface-render-rendered-views render)))])
            (unless (and (= (length windows) 2)
                         prompt companion companion-rendered root-rendered
                         (eq? (surface-active-window surface) prompt)
                         (= (cadddr (rendered-view-rectangle companion-rendered)) 6)
                         (positive? (cadddr (rendered-view-rectangle root-rendered))))
              (error 'fundamental-editing-tests
                     "completion presentation did not preserve prompt focus and root content"))
            (surface-resize! surface '(40 . 4))
            (let* ([small (render-surface surface (host-state-views state))]
                   [small-root
                    (find
                      (lambda (item)
                        (= (rendered-view-view-id item)
                           (view-id (soda-application-view application))))
                      (surface-render-rendered-views small))]
                   [small-companion
                    (find
                      (lambda (item)
                        (= (rendered-view-view-id item)
                           (window-view-id companion)))
                      (surface-render-rendered-views small))])
              (unless (and (= (cadddr (rendered-view-rectangle small-root)) 1)
                           (= (cadddr
                                (rendered-view-rectangle small-companion))
                              1))
                (error 'fundamental-editing-tests
                       "small Surface did not reserve one root row before completion")))
            (surface-resize! surface '(80 . 24))))
        (let* ([prompt (minibuffer-service-current minibuffer)]
               [prompt-buffer
                (buffer-service-ref
                  (host-state-buffers state) (minibuffer-session-buffer-id prompt))]
               [prompt-view
                (view-service-ref
                  (host-state-views state) (minibuffer-session-view-id prompt))]
               [buffer-state (buffer-state prompt-buffer)])
          (dispatcher-dispatch!
            (host-state-dispatch state)
            (make-transaction-spec
              (buffer-id prompt-buffer) (view-id prompt-view)
              (buffer-state-generation buffer-state)
              (make-change-set 7
                (list (make-text-change 0 7 (string->utf8 "invalid"))))
              (make-selection (list (make-selection-range 7 7)))
              '() '()))
          (command-runtime-start!
            runtime 'minibuffer.accept (application-command-context application))
          (unless (and (= (length
                            (surface-interaction-windows
                              (soda-application-surface application)))
                          1)
                       (minibuffer-service-current minibuffer)
                       (string=?
                         (input-stack-feedback
                           (view-state-input-state (view-state prompt-view)))
                         "Input does not match an available choice"))
            (error 'fundamental-editing-tests
                   "prompt edits did not refresh completion chrome or validation feedback")))
        (minibuffer-service-cancel! minibuffer)
        (host-state-run! state)
        (command-runtime-start-interactive!
          runtime 'interaction.match-test (application-command-context application))
        (minibuffer-service-refresh-completion! minibuffer)
        (minibuffer-service-select-completion! minibuffer 0)
        (minibuffer-service-refresh-completion! minibuffer)
        (minibuffer-service-submit! minibuffer)
        (unless (equal? (reverse completion-events) '(preview restore preview))
          (error 'fundamental-editing-tests
                 "same-revision refresh did not restore and re-establish preview"
                 completion-events))
        (host-state-run! state)
        (unless (and (string=? must-match-value "allowed")
                     (not (minibuffer-service-current minibuffer))
                     (equal? (reverse completion-events)
                             '(preview restore preview accept restore))
                     (eq? restored-snapshot preview-snapshot))
          (error 'fundamental-editing-tests
                 "failed completion acceptance did not restore its active preview"
                 completion-events))
        (set! completion-events '())
        (command-runtime-start-interactive!
          runtime 'interaction.match-test (application-command-context application))
        (minibuffer-service-refresh-completion! minibuffer)
        (minibuffer-service-select-completion! minibuffer 0)
        (minibuffer-service-cancel! minibuffer)
        (host-state-run! state)
        (unless (and (not (minibuffer-service-current minibuffer))
                     (eq? restored-snapshot preview-snapshot)
                     (equal? (reverse completion-events) '(preview restore)))
          (error 'fundamental-editing-tests
                 "completion cancellation did not restore its originating preview snapshot"
                 completion-events preview-snapshot restored-snapshot)))
      (let* ([raw-value #f]
             [source
              (make-completion-source
                (lambda (snapshot)
                  (list
                    (make-completion-candidate
                      'candidate "candidate" "candidate" #f #f #f)))
                #f #f #f)]
             [reader
              (make-interactive-reader
                'read-free-value
                (lambda (context arguments)
                  (make-interactive-suspend
                    (make-interaction-request
                      'string "Free value: " "raw" source 'free)
                    (lambda (value) (make-interactive-ready (list value))))))]
             [_command
              (command-runtime-register-command!
                runtime
                (make-command-definition
                  'interaction.free-test
                  (lambda (context value)
                    (set! raw-value value)
                    (command-handled))
                  owner "Free completion interaction test" 'test
                  (make-interactive-plan (list reader))))])
        (command-runtime-start-interactive!
          runtime 'interaction.free-test (application-command-context application))
        (let ([controller (minibuffer-service-refresh-completion! minibuffer)])
          (minibuffer-service-select-completion! minibuffer 0)
          (command-runtime-start!
            runtime 'minibuffer.accept-input
            (application-command-context application))
          (host-state-run! state)
          (unless (and (string=? raw-value "raw")
                       (not (minibuffer-service-current minibuffer)))
            (error 'fundamental-editing-tests
                   "explicit raw-input acceptance submitted the selected candidate")))
        (command-runtime-start-interactive!
          runtime 'interaction.free-test (application-command-context application))
        (let ([controller (minibuffer-service-refresh-completion! minibuffer)])
          (minibuffer-service-select-completion! minibuffer 0)
          (command-runtime-start!
            runtime 'minibuffer.previous-completion
            (application-command-context application))
          (unless (not (completion-controller-selected-index controller))
            (error 'fundamental-editing-tests
                   "free completion could not navigate back to raw input"))
          (command-runtime-start!
            runtime 'minibuffer.next-completion
            (application-command-context application))
          (unless (equal? (completion-controller-selected-index controller) 0)
            (error 'fundamental-editing-tests
                   "free completion did not navigate from raw input to its first candidate")))
        (minibuffer-service-cancel! minibuffer)
        (host-state-run! state))
      ;; Candidate identity includes the prompt point. Moving between fields
      ;; without editing the Document must refresh ranges and clear a selection
      ;; that belonged to the old field.
      (let* ([source
              (make-completion-source
                (lambda (snapshot)
                  (let* ([input (prompt-snapshot-input snapshot)]
                         [point (prompt-snapshot-point snapshot)]
                         [separator
                          (let loop ([index 0])
                            (cond
                              [(= index (string-length input)) #f]
                              [(char=? (string-ref input index) #\/) index]
                              [else (loop (+ index 1))]))]
                         [left? (and separator (<= point separator))]
                         [start (if left? 0 (+ separator 1))]
                         [end (if left? separator (string-length input))]
                         [text (if left? "LEFT" "RIGHT")])
                    (list
                      (make-replacement-completion-candidate
                        text start end text text #f #f #f 'final))))
                #f #f #f)]
             [reader
              (make-interactive-reader
                'read-field-context
                (lambda (context arguments)
                  (make-interactive-suspend
                    (make-interaction-request
                      'string "Fields: " "left/right" source 'free)
                    (lambda (value) (make-interactive-ready (list value))))))]
             [_command
              (command-runtime-register-command!
                runtime
                (make-command-definition
                  'interaction.field-context-test
                  (lambda (context value) (command-handled))
                  owner "Field context completion test" 'test
                  (make-interactive-plan (list reader))))])
        (command-runtime-start-interactive!
          runtime 'interaction.field-context-test
          (application-command-context application))
        (command-runtime-start!
          runtime 'fundamental.end-of-buffer
          (application-command-context application))
        (let ([controller (minibuffer-service-refresh-completion! minibuffer)])
          (minibuffer-service-select-completion! minibuffer 0)
          (unless (= (completion-candidate-replacement-start
                       (completion-controller-selected controller))
                     5)
            (error 'fundamental-editing-tests
                   "completion did not start in the point-selected field"))
          (command-runtime-start!
            runtime 'fundamental.beginning-of-buffer
            (application-command-context application))
          (let* ([current (minibuffer-session-completion
                            (minibuffer-service-current minibuffer))]
                 [candidate (car (completion-controller-candidates current))])
            (unless (and (not (completion-controller-selected-index current))
                         (= (completion-candidate-replacement-start candidate) 0)
                         (= (completion-candidate-replacement-end candidate) 4))
              (error 'fundamental-editing-tests
                     "point motion retained completion state from another field")))
          (command-runtime-start!
            runtime 'minibuffer.complete
            (application-command-context application))
          (let* ([session (minibuffer-service-current minibuffer)]
                 [prompt-buffer
                  (buffer-service-ref
                    (host-state-buffers state)
                    (minibuffer-session-buffer-id session))])
            (unless (string=? (buffer-string prompt-buffer) "LEFT/right")
              (error 'fundamental-editing-tests
                     "completion applied a stale field replacement"
                     (buffer-string prompt-buffer))))
          (minibuffer-service-cancel! minibuffer)
          (host-state-run! state)))
      (let ([cancelled
             (command-runtime-start-interactive!
               runtime 'interaction.package-test (application-command-context application))])
        (interaction-service-cancel! interaction)
        (host-state-run! state)
        (unless (and (not (command-runtime-invocation
                            runtime (command-invocation-id cancelled) #f))
                     (not (interaction-service-current interaction)))
          (error 'fundamental-editing-tests "interaction cancellation did not retire its invocation")))
      (let* ([outer
              (command-runtime-start-interactive!
                runtime 'interaction.package-test
                (application-command-context application))]
             [outer-prompt (minibuffer-service-current minibuffer)]
             [inner
              (command-runtime-start-interactive!
                runtime 'interaction.package-test
                (application-command-context application))]
             [inner-prompt (minibuffer-service-current minibuffer)])
        (unless (and (= (length (interaction-service-sessions interaction)) 2)
                     (= (length (minibuffer-service-sessions minibuffer)) 2)
                     (= (length
                          (surface-interaction-windows
                            (soda-application-surface application)))
                        2)
                     (= (minibuffer-session-origin-view-id inner-prompt)
                        (minibuffer-session-view-id outer-prompt))
                     (= (interaction-session-invocation-id
                          (minibuffer-session-interaction inner-prompt))
                        (command-invocation-id inner)))
          (error 'fundamental-editing-tests
                 "nested interaction did not form one coherent prompt stack"))
        (minibuffer-service-cancel! minibuffer)
        (host-state-run! state)
        (unless (and (= (length (interaction-service-sessions interaction)) 1)
                     (= (length (minibuffer-service-sessions minibuffer)) 1)
                     (= (interaction-session-invocation-id
                          (minibuffer-session-interaction
                            (minibuffer-service-current minibuffer)))
                        (command-invocation-id outer))
                     (= (active-context-view-id
                          (surface-active-context
                            (soda-application-surface application)
                            (host-state-views state)))
                        (minibuffer-session-view-id outer-prompt)))
          (error 'fundamental-editing-tests
                 "closing an inner prompt did not restore its outer prompt"))
        (minibuffer-service-cancel! minibuffer)
        (host-state-run! state)
        (unless (and (not (interaction-service-current interaction))
                     (not (minibuffer-service-current minibuffer))
                     (null? (surface-interaction-windows
                              (soda-application-surface application))))
          (error 'fundamental-editing-tests
                 "closing the outer prompt did not restore the editor")))
      (let* ([outer
              (command-runtime-start-interactive!
                runtime 'interaction.package-test
                (application-command-context application))]
             [outer-session (interaction-service-current interaction)]
             [inner
              (command-runtime-start-interactive!
                runtime 'interaction.package-test
                (application-command-context application))]
             [inner-session (interaction-service-current interaction)]
             [cancelled-order '()]
             [_listener
              (interaction-service-add-listener!
                interaction owner
                (lambda (event session)
                  (when (eq? event 'cancelled)
                    (set! cancelled-order
                      (cons (interaction-session-invocation-id session)
                            cancelled-order)))))])
        (interaction-service-cancel-all! interaction)
        (unless (and (eq? (interaction-session-status inner-session) 'cancelling)
                     (eq? (interaction-session-status outer-session) 'cancelling))
          (error 'fundamental-editing-tests
                 "cancel-all did not atomically mark every open interaction"))
        (host-state-run! state)
        (unless (and (equal? (reverse cancelled-order)
                             (list (command-invocation-id inner)
                                   (command-invocation-id outer)))
                     (eq? (interaction-session-status inner-session) 'cancelled)
                     (eq? (interaction-session-status outer-session) 'cancelled)
                     (not (interaction-service-current interaction))
                     (not (minibuffer-service-current minibuffer))
                     (null? (surface-interaction-windows
                              (soda-application-surface application))))
          (error 'fundamental-editing-tests
                 "cancel-all did not retire nested interactions inside-out"
                 cancelled-order)))
      (command-runtime-start-interactive!
        runtime 'command.execute-extended (application-command-context application))
      (let* ([request
              (interaction-session-request (interaction-service-current interaction))]
             [controller (minibuffer-service-refresh-completion! minibuffer)])
        (unless (and (eq? (interaction-request-kind request) 'command)
                     (eq? (interaction-request-history-key request)
                          'extended-command)
                     (eq? (interaction-request-selection-policy request) 'must-match)
                     controller
                     (exists
                       (lambda (candidate)
                         (string=? (completion-candidate-insert-text candidate)
                                   "fundamental.newline"))
                       (completion-controller-candidates controller))
                     (exists
                       (lambda (candidate)
                         (string=? (completion-candidate-insert-text candidate)
                                  "buffer.bury"))
                       (completion-controller-candidates controller))
                     (not
                       (exists
                         (lambda (candidate)
                           (member
                             (completion-candidate-insert-text candidate)
                             '("fundamental.insert-text"
                               "fundamental.pointer-select"
                               "fundamental.pointer-scroll"
                               "recovery.flush"
                               "macro.step"
                               "buffer.next-item"
                               "buffer-list.refresh"
                               "directory.refresh"
                               "spell.correct-item"
                               "spell.correct"
                               "minibuffer.accept"
                               "minibuffer.complete")))
                         (completion-controller-candidates controller))))
          (error 'fundamental-editing-tests
                 "M-x command completion did not hide runtime-only commands"))
        (unless (> (length (completion-controller-candidates controller)) 7)
          (error 'fundamental-editing-tests
                 "M-x did not provide enough commands to test candidate scrolling"))
        (let* ([candidate
                (list-ref (completion-controller-candidates controller) 7)]
               [_ (minibuffer-service-select-completion! minibuffer 7)]
               [companion
                (find
                  (lambda (window)
                    (let ([purpose (window-purpose window)])
                      (and (pair? purpose) (eq? (car purpose) 'companion))))
                  (surface-interaction-windows
                    (soda-application-surface application)))]
               [completion-view
                (and companion
                     (view-service-ref
                       (host-state-views state) (window-view-id companion)))]
               [text (and completion-view
                          (buffer-string (view-buffer completion-view)))])
          (unless (and text
                       (string-contains?
                         text
                         (string-append "> "
                                        (completion-candidate-label candidate))))
            (error 'fundamental-editing-tests
                   "completion viewport did not reveal a selected off-screen candidate"
                   text))
          (let find-message ([candidates
                              (completion-controller-candidates controller)]
                             [index 0])
            (cond
              [(null? candidates)
               (error 'fundamental-editing-tests
                      "M-x completion omitted message.show-position")]
              [(string=?
                 (completion-candidate-insert-text (car candidates))
                 "message.show-position")
               (minibuffer-service-select-completion! minibuffer index)]
              [else (find-message (cdr candidates) (+ index 1))])))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "message.show-position")))
      (unless (not (completion-controller-selected-index controller))
        (error 'fundamental-editing-tests
               "editing minibuffer input retained a stale completion selection")))
      (minibuffer-service-submit! minibuffer)
      (host-state-run! state)
      (host-state-run! state)
      (let ([message (surface-feedback-text (soda-application-surface application))])
        (unless (and message (string=? message "Line 1, column 1"))
          (error 'fundamental-editing-tests "M-x did not enqueue the selected command"
                 message
                 (map (lambda (entry)
                        (let ([value (editor-condition-value entry)])
                          (if (and (list? value) (= (length value) 3)
                                   (condition? (caddr value))
                                   (message-condition? (caddr value)))
                              (condition-message (caddr value))
                              value)))
                      (condition-service-entries (host-state-conditions state))))))
      (unless (equal?
                (minibuffer-service-history-entries minibuffer 'extended-command)
                '("message.show-position"))
        (error 'fundamental-editing-tests
               "accepted M-x input was not recorded in its history"))
      (command-runtime-start-interactive!
        runtime 'command.execute-extended (application-command-context application))
      (command-runtime-start!
        runtime 'minibuffer.previous-history
        (application-command-context application))
      (host-state-run! state)
      (let* ([session (minibuffer-service-current minibuffer)]
             [prompt-buffer
              (buffer-service-ref
                (host-state-buffers state)
                (minibuffer-session-buffer-id session))])
        (unless (string=? (buffer-string prompt-buffer) "message.show-position")
          (error 'fundamental-editing-tests
                 "M-p did not recall the newest M-x history entry"))
        (command-runtime-start!
          runtime 'minibuffer.next-history
          (application-command-context application))
        (host-state-run! state)
        (unless (string=? (buffer-string prompt-buffer) "")
          (error 'fundamental-editing-tests
                 "M-n did not restore the minibuffer draft")))
      (minibuffer-service-cancel! minibuffer)
      (host-state-run! state)
      (unless (equal?
                (minibuffer-service-history-entries minibuffer 'extended-command)
                '("message.show-position"))
        (error 'fundamental-editing-tests
               "cancelled minibuffer input entered command history"))
      (command-runtime-start-interactive!
        runtime 'command.describe (application-command-context application))
      (interaction-service-submit! interaction "message.show-position")
      (host-state-run! state)
      (let ([message (surface-feedback-text (soda-application-surface application))])
        (unless (and message (string-contains? message "Show the active selection"))
          (error 'fundamental-editing-tests
                 "describe-command did not use command metadata" message)))
      (command-runtime-start-interactive!
        runtime 'command.where-is (application-command-context application))
      (interaction-service-submit! interaction "message.show-position")
      (host-state-run! state)
      (unless (string-contains?
                (surface-feedback-text (soda-application-surface application)) "C-c")
        (error 'fundamental-editing-tests "where-is did not reverse-query active keymaps"))
      (command-runtime-start-interactive!
        runtime 'command.where-is (application-command-context application))
      (interaction-service-submit! interaction "buffer.bury")
      (host-state-run! state)
      (unless (string-contains?
                (surface-feedback-text (soda-application-surface application))
                "available through M-x")
        (error 'fundamental-editing-tests
               "where-is did not explain M-x-only command access"))
      ;; The completion list and manual minibuffer submission share the same
      ;; user-command projection.  A hidden runtime command must not become
      ;; executable merely because its name was typed instead of selected.
      (command-runtime-start-interactive!
        runtime 'command.execute-extended (application-command-context application))
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "recovery.flush")))
      (unless (and (not (minibuffer-service-submit! minibuffer))
                   (minibuffer-service-current minibuffer))
        (error 'fundamental-editing-tests
               "M-x accepted a runtime-only command typed into the minibuffer"))
      (minibuffer-service-cancel! minibuffer)
      (host-state-run! state)
      (owner-close! owner)
      (soda-application-close! application))

    ;; File-mode association selects an ordinary derived ModeSpec.  Scheme
    ;; behavior then comes from the active configuration, not from FileService
    ;; branches or terminal input special cases.
    (let* ([path (string-append "/tmp/soda-scheme-mode-"
                                (number->string (get-process-id)) ".sls")]
           [application (make-soda-application)])
      (dynamic-wind
        (lambda ()
          (vfs-write-file
            path
            (string->utf8
              "(define foo-bar? \"value\")\n(display foo-bar?)\n; note\n42\n")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application)
              (list path))
            (let* ([context (application-command-context application)]
                   [buffer-state (command-context-buffer-state context)]
                   [configuration (buffer-state-configuration buffer-state)]
                   [service (soda-application-scheme-mode application)]
                   [profile
                    (configuration-facet
                      configuration buffer-syntax-profile-facet 'buffer)])
              (unless (and (eq? (configuration-facet
                                  configuration buffer-mode-facet 'buffer)
                                (scheme-mode-spec service))
                           (eq? profile (scheme-mode-syntax-profile service))
                           (exists
                             (lambda (instance)
                               (eq? (mode-instance-spec instance)
                                    (scheme-mode-spec service)))
                             (mode-service-instances
                               (host-state-modes state)
                               (command-context-buffer-id context)))
                           (syntax-profile-word-constituent? profile #\-)
                           (syntax-profile-word-constituent? profile #\?)
                           (command-runtime-command-available?
                             runtime 'comment.add context)
                           (let ([syntax
                                  (mode-spec-effective-comment-syntax
                                    (scheme-mode-spec service))])
                             (and (string=?
                                    (comment-syntax-line-prefix syntax) "; ")
                                  (string=?
                                    (comment-syntax-block-start syntax) "#|")
                                  (string=?
                                    (comment-syntax-block-end syntax) "|#"))))
                (error 'fundamental-editing-tests
                       "Scheme file did not activate its derived mode contracts"))
              (host-state-run! state)
              (let* ([host (make-package-host state)]
                     [buffer-id (command-context-buffer-id context)]
                     [initial
                      (package-host-analysis-result
                        host buffer-id scheme-highlight-provider-key #f)]
                     [initial-ranges
                      (and initial (range-set-ranges
                                     (analysis-result-ranges initial)))]
                     [initial-prefix (and (pair? initial-ranges)
                                          (car initial-ranges))]
                     [kinds (and initial-ranges (map range-value-value initial-ranges))])
                (unless (and initial
                             (for-all (lambda (kind) (memq kind kinds))
                                      '(comment string number keyword definition symbol)))
                  (error 'fundamental-editing-tests
                         "Scheme provider did not classify its core lexical forms"
                         kinds))
                (let* ([render
                        (render-surface
                          (soda-application-surface application)
                          (host-state-views state))]
                       [rendered (car (surface-render-rendered-views render))]
                       [view
                        (package-host-view-ref
                          host (rendered-view-view-id rendered))])
                  (view-service-publish-occurrences!
                    (host-state-views state) (view-id view)
                    (list (rendered-view-occurrence rendered)))
                  (unless (pair?
                            (range-set-ranges
                              (view-projection-decorations
                                (view-projection view))))
                    (error 'fundamental-editing-tests
                           "Scheme analysis did not enter ViewProjection")))
                (command-runtime-start!
                  runtime 'fundamental.end-of-buffer
                  (application-command-context application))
                (command-runtime-start!
                  runtime 'fundamental.insert-text
                  (application-command-context application)
                  (list (string->utf8 "; tail")))
                (host-state-run! state)
                (let* ([updated
                        (package-host-analysis-result
                          host buffer-id scheme-highlight-provider-key #f)]
                       [updated-ranges (analysis-result-ranges updated)]
                       [replaced-from
                        (cdr (assq 'replaced-from
                                   (analysis-result-metadata updated)))])
                  (unless (and (> replaced-from 0)
                               (exists (lambda (range) (eq? range initial-prefix))
                                       (range-set-ranges updated-ranges))
                               (exists
                                 (lambda (range)
                                   (eq? (range-value-value range) 'comment))
                                 (analysis-result-query
                                   updated replaced-from
                                   (snapshot-byte-size
                                     (buffer-state-document
                                       (command-context-buffer-state
                                         (application-command-context application)))))))
                    (error 'fundamental-editing-tests
                           "Scheme incremental analysis replaced its stable prefix"))))
              (command-runtime-start!
                runtime 'fundamental.beginning-of-buffer
                (application-command-context application))
              (command-runtime-start!
                runtime 'comment.add
                (application-command-context application))
              (unless (string-prefix?
                        "; "
                        (buffer-string
                          (buffer-service-ref
                            (host-state-buffers state)
                            (command-context-buffer-id context))))
                (error 'fundamental-editing-tests
                       "generic comment command did not publish a normal transaction"))
              (command-runtime-start!
                runtime 'comment.remove
                (application-command-context application))
              (when (string-prefix?
                      "; "
                      (buffer-string
                        (buffer-service-ref
                          (host-state-buffers state)
                          (command-context-buffer-id context))))
                (error 'fundamental-editing-tests
                       "generic uncomment command did not remove the mode prefix")))))
        (lambda ()
          (soda-application-close! application)
          (when (file-exists? path) (delete-file path)))))

    (let* ([path (string-append "/tmp/soda-comment-selection-"
                                (number->string (get-process-id)) ".ss")])
      (dynamic-wind
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (vfs-write-file path (string->utf8 "one\n  two\nthree")))
        (lambda ()
          (let* ([application (make-soda-application)]
                 [state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (command-runtime-start!
                  runtime 'file.visit (application-command-context application)
                  (list path))
                (let* ([context (application-command-context application)]
                       [view
                        (view-service-ref
                          (host-state-views state)
                          (command-context-view-id context))]
                       [selection
                        (make-selection
                          (list (make-selection-range 0 0)
                                (make-selection-range 6 6)) 0)])
                  (dispatcher-dispatch-view!
                    (host-state-dispatch state)
                    (make-view-transaction-spec
                      (view-id view) (view-state-generation (view-state view))
                      selection #f #f '() '() #f))
                  (let ([invocation
                         (command-runtime-start!
                           runtime 'comment.add
                           (application-command-context application))])
                  (let ([buffer (view-buffer view)])
                    (unless (and (eq? (command-invocation-phase invocation) 'completed)
                                 (string=? (buffer-string buffer)
                                           "; one\n  ; two\nthree"))
                      (error 'fundamental-editing-tests
                             "comment command did not cover multiple selections"))
                    (command-runtime-start!
                      runtime 'comment.remove (application-command-context application))
                    (unless (string=? (buffer-string buffer) "one\n  two\nthree")
                      (error 'fundamental-editing-tests
                             "uncomment command did not cover multiple selections"))))))
              (lambda () (soda-application-close! application)))))
        (lambda ()
          (when (file-exists? path) (delete-file path)))))

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

    (let* ([root (string-append "/tmp/soda-file-completion-"
                                (number->string (get-process-id)))]
           [directory (string-append root "/sub")]
           [path (string-append directory "/target.txt")]
           [application #f])
      (dynamic-wind
        (lambda ()
          (when (file-exists? root) (delete-directory root))
          (mkdir root)
          (mkdir directory)
          (vfs-write-file path (string->utf8 "nested"))
          (set! application (make-soda-application)))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [minibuffer (soda-application-minibuffer application)])
            (let* ([input (string-append root "/su/target.txt")]
                   [point (string-length (string-append root "/su"))]
                   [snapshot
                    (make-prompt-snapshot
                      1 #f input 0 point #f #f 0 '())]
                   [candidates
                    ((completion-source-refresh file-name-completion-source)
                     snapshot)]
                   [directory-candidate
                    (find
                      (lambda (candidate)
                        (eq? (completion-candidate-accept-behavior candidate)
                             'continue))
                      candidates)])
              (unless directory-candidate
                (error 'fundamental-editing-tests
                       "file completion did not offer the directory under point"))
              (call-with-values
                (lambda ()
                  (completion-candidate-apply directory-candidate input))
                (lambda (value next-point)
                  (unless (and (string=? value
                                         (string-append
                                           (vfs-directory-path directory)
                                           "target.txt"))
                               (= next-point
                                  (string-length
                                    (vfs-directory-path directory))))
                    (error 'fundamental-editing-tests
                           "ranged file completion did not preserve the path suffix"
                           value next-point)))))
            (call-with-values
              (lambda ()
                (completion-candidate-apply
                  (make-replacement-completion-candidate
                    'unicode 1 2 "é" "é" #f #f #f 'final)
                  "a😀z"))
              (lambda (value point)
                (unless (and (string=? value "aéz") (= point 2))
                  (error 'fundamental-editing-tests
                         "completion replacement did not use character coordinates"))))
            (command-runtime-start-interactive!
              runtime 'file.visit (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.mark-whole-buffer
              (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application)
              (list (string->utf8 (string-append root "/s"))))
            (let* ([controller (minibuffer-service-refresh-completion! minibuffer)]
                   [candidates (completion-controller-candidates controller)]
                   [index
                    (let find ([items candidates] [position 0])
                      (cond
                        [(null? items) #f]
                        [(call-with-values
                           (lambda ()
                             (completion-candidate-apply
                               (car items) (string-append root "/s")))
                           (lambda (value point)
                             (string=? value (vfs-directory-path directory))))
                         position]
                        [else (find (cdr items) (+ position 1))]))])
              (unless (and index
                           (eq? (completion-candidate-accept-behavior
                                  (list-ref candidates index))
                                'continue))
                (error 'fundamental-editing-tests
                       "file completion did not mark a directory as continuing"))
              (minibuffer-service-select-completion! minibuffer index)
              (command-runtime-start!
                runtime 'minibuffer.accept
                (application-command-context application)))
            (let* ([session (minibuffer-service-current minibuffer)]
                   [prompt-buffer
                    (and session
                         (buffer-service-ref
                           (host-state-buffers state)
                           (minibuffer-session-buffer-id session)))])
              (unless (and session prompt-buffer
                           (string=? (buffer-string prompt-buffer)
                                     (vfs-directory-path directory)))
                (error 'fundamental-editing-tests
                       "accepting a directory ended the file-name interaction"))
              (command-runtime-start!
                runtime 'fundamental.insert-text
                (application-command-context application)
                (list (string->utf8 "target.txt")))
              (command-runtime-start!
                runtime 'minibuffer.accept
                (application-command-context application))
              (host-state-run! state)
              (unless (and (not (minibuffer-service-current minibuffer))
                           (string=?
                             (buffer-string
                               (view-buffer
                                 (view-service-ref
                                   (host-state-views state)
                                   (command-context-view-id
                                     (application-command-context application)))))
                             "nested"))
                (error 'fundamental-editing-tests
                       "file-name continuation did not visit the nested file")))))
        (lambda ()
          (when application (soda-application-close! application))
          (when (file-exists? path) (delete-file path))
          (when (file-exists? directory) (delete-directory directory))
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
            (let* ([host (make-package-host state)]
                   [location
                    (make-location
                      (make-resource 'file second-path)
                      (make-byte-position 1) (make-byte-position 4)
                      #f 'after '())]
                   [pending (package-host-resolve-location host location)]
                   [active-before
                    (command-context-buffer-id
                      (application-command-context application))])
              (unless (and (eq? (location-resolution-status pending) 'needs-open)
                           (command-effect?
                             (location-resolution-request pending)))
                (error 'fundamental-editing-tests
                       "unopened file Location did not produce a load effect"))
              (command-runtime-register-command!
                runtime
                (make-command-definition
                  'test.open-file-location
                  (lambda (context) (location-resolution-request pending))
                  (host-state-owner state)))
              (command-runtime-start!
                runtime 'test.open-file-location
                (application-command-context application))
              (let ([resolved (package-host-resolve-location host location)])
                (unless (and (eq? (location-resolution-status resolved) 'resolved)
                             (= (location-resolution-from resolved) 1)
                             (= (location-resolution-to resolved) 4)
                             (= (command-context-buffer-id
                                  (application-command-context application))
                                active-before)
                             (string=?
                               (buffer-string
                                 (package-host-buffer-ref
                                   host (location-resolution-buffer-id resolved)))
                               "second"))
                  (error 'fundamental-editing-tests
                         "file Location loading changed placement or failed to resolve"))))
            (command-runtime-start-interactive!
              runtime 'file.save (application-command-context application))
            (let ([request (interaction-session-request
                             (interaction-service-current interaction))])
              (unless (and (eq? (interaction-request-kind request) 'file-name)
                           (eq? (interaction-request-history-key request) 'file-name)
                           (string=? (interaction-request-initial-value request)
                                     (current-file-directory))
                           (string=? (interaction-request-prompt request) "Write file: "))
                (error 'fundamental-editing-tests
                       "file.save did not ask an unvisited Buffer for its destination")))
            (interaction-service-submit! interaction scratch-save)
            (host-state-run! state)
            (unless (and (file-exists? scratch-save)
                         (string=? (resource-locator
                                    (file-service-resource files (buffer-id scratch)))
                                   scratch-save)
                         (positive?
                           (file-watch-service-binding-count
                             (file-service-watch-service files))))
              (error 'fundamental-editing-tests
                     "file.save did not bind and watch its selected destination"))
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
                           (eq? (interaction-request-history-key request) 'file-name)
                           (completion-source?
                             (interaction-request-completion-source request))
                           (string=?
                             (interaction-request-initial-value request)
                             (vfs-parent-directory scratch-save))
                           (string=? (interaction-request-prompt request) "Visit file: "))
                (error 'fundamental-editing-tests
                       "file.visit did not declare a reusable file interaction")))
            (command-runtime-start!
              runtime 'fundamental.mark-whole-buffer
              (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.insert-text (application-command-context application)
              (list (string->utf8 (substring path 0 (- (string-length path) 4)))))
            (let ([controller (minibuffer-service-refresh-completion!
                                (soda-application-minibuffer application))])
              (unless (and controller
                           (exists
                             (lambda (candidate)
                               (call-with-values
                                 (lambda ()
                                   (completion-candidate-apply
                                     candidate
                                     (substring path 0 (- (string-length path) 4))))
                                 (lambda (value point) (string=? value path))))
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
            (command-runtime-start-interactive!
              runtime 'file.visit (application-command-context application))
            (interaction-service-submit!
              interaction
              (substring path
                         (string-length (vfs-parent-directory path))
                         (string-length path)))
            (host-state-run! state)
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
                                   (application-command-context application)))]
                    [watch-count-before-close
                     (file-watch-service-binding-count
                       (file-service-watch-service files))])
                (unless (= (buffer-id revisited) (buffer-id buffer))
                  (error 'fundamental-editing-tests
                         "file.visit did not reuse its canonical file Buffer"))
                (command-runtime-start! runtime 'fundamental.end-of-buffer
                                        (application-command-context application))
                (command-runtime-start! runtime 'fundamental.insert-text
                                        (application-command-context application)
                                        (list (string->utf8 " discard")))
                (command-runtime-start-interactive!
                  runtime 'buffer.kill (application-command-context application))
                (let ([request (interaction-session-request
                                 (interaction-service-current interaction))])
                  (unless (and (eq? (interaction-request-kind request) 'save-decision)
                               (string=? (interaction-request-prompt request)
                                         (string-append "Save changes to " (buffer-name revisited)
                                                        "?"))
                               (= (length (interaction-request-actions request)) 3))
                    (error 'fundamental-editing-tests
                           "buffer.kill did not request a modified-file decision")))
                (interaction-service-submit! interaction 'discard)
                (host-state-run! state)
                (unless (and (not (buffer-service-ref
                                    (host-state-buffers state) (buffer-id revisited) #f))
                             (not (file-service-resource files (buffer-id revisited) #f))
                             (= (file-watch-service-binding-count
                                  (file-service-watch-service files))
                                (- watch-count-before-close 1))
                             (not (= (command-context-buffer-id
                                       (application-command-context application))
                                     (buffer-id revisited))))
                  (error 'fundamental-editing-tests
                         "buffer.kill did not replace every active View before releasing its Buffer"))))
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
                runtime 'buffer.kill (application-command-context application))
              (interaction-service-submit! interaction 'save)
              (host-state-run! state)
              (unless (and (string=? (utf8->string (vfs-read-file second-path)) "second saved")
                           (not (buffer-service-ref
                                  (host-state-buffers state) (buffer-id closable) #f)))
                (error 'fundamental-editing-tests
                       "buffer.kill save did not write and release the file Buffer")))
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
                                     "Save 1 modified file buffer?")
                           (= (length (interaction-request-actions request)) 3))
                (error 'fundamental-editing-tests
                       "application.quit did not request a modified-file decision")))
            (interaction-service-submit! interaction 'save)
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

    ;; External changes enter through immutable FileStateEvents.  Clean
    ;; Buffers reload automatically; dirty Buffers retain their contents until
    ;; an InteractionService decision is revalidated against the disk version.
    (let* ([path (string-append "/tmp/soda-external-policy-"
                                (number->string (get-process-id)) ".txt")]
           [saved-as (string-append path ".local")]
           [application (make-soda-application)])
      (define (external-event files buffer kind)
        (make-file-state-event
          (buffer-id buffer) path kind 'external
          (and (vfs-file-exists? path) (vfs-stat-path path))
          (if (eq? kind 'replaced) '(rename) '(change)) 0))
      (define (publish-external! files buffer kind)
        (file-service-handle-state-event!
          files (external-event files buffer kind)
          (application-command-context application))
        (host-state-run! (soda-application-state application)))
      (dynamic-wind
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? saved-as) (delete-file saved-as))
          (vfs-write-file path (string->utf8 "initial"))
          (vfs-write-file saved-as (string->utf8 "destination-old")))
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [files (soda-application-files application)]
                 [history (soda-application-history application)]
                 [interaction (soda-application-interaction application)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application) (list path))
            (let ([buffer
                   (buffer-service-ref
                     (host-state-buffers state)
                     (command-context-buffer-id
                       (application-command-context application)))])
              (vfs-write-file path (string->utf8 "automatic"))
              (publish-external! files buffer 'replaced)
              (unless (and (string=? (buffer-string buffer) "automatic")
                           (not (history-modified? history (buffer-id buffer)))
                           (not (file-service-conflict files (buffer-id buffer) #f)))
                (error 'fundamental-editing-tests
                       "clean Buffer did not automatically reload a stable external version"))

              ;; The clean/dirty decision is checked again when the queued
              ;; reload effect runs, so an intervening edit cannot be lost.
              (vfs-write-file path (string->utf8 "race"))
              (file-service-handle-state-event!
                files (external-event files buffer 'replaced)
                (application-command-context application))
              (command-runtime-start!
                runtime 'fundamental.end-of-buffer
                (application-command-context application))
              (command-runtime-start!
                runtime 'fundamental.insert-text
                (application-command-context application)
                (list (string->utf8 " local-race")))
              (host-state-run! state)
              (unless (and (string=? (buffer-string buffer) "automatic local-race")
                           (eq? (file-conflict-status
                                  (file-service-conflict files (buffer-id buffer)))
                                'pending)
                           (interaction-service-current interaction))
                (error 'fundamental-editing-tests
                       "queued automatic reload overwrote an intervening edit"))
              (interaction-service-submit! interaction 'reload)
              (host-state-run! state)
              (unless (string=? (buffer-string buffer) "race")
                (error 'fundamental-editing-tests
                       "explicit reload after an intervening edit failed"))

              (command-runtime-start!
                runtime 'fundamental.end-of-buffer
                (application-command-context application))
              (command-runtime-start!
                runtime 'fundamental.insert-text
                (application-command-context application) (list (string->utf8 " local")))
              (vfs-write-file path (string->utf8 "external-one"))
              (publish-external! files buffer 'replaced)
              (let ([session (interaction-service-current interaction)]
                    [conflict (file-service-conflict files (buffer-id buffer))])
                (unless (and session
                             (eq? (interaction-request-kind
                                    (interaction-session-request session))
                                  'external-file-change)
                             (eq? (file-conflict-status conflict) 'pending)
                             (string=? (buffer-string buffer) "race local"))
                  (error 'fundamental-editing-tests
                         "dirty Buffer did not enter an explicit external conflict")))

              ;; A decision for external-one must not load external-two.
              (vfs-write-file path (string->utf8 "external-two"))
              (interaction-service-submit! interaction 'reload)
              (host-state-run! state)
              (unless (and (string=? (buffer-string buffer) "race local")
                           (file-service-conflict files (buffer-id buffer) #f))
                (error 'fundamental-editing-tests
                       "stale reload decision crossed the disk-version boundary"))
              (publish-external! files buffer 'replaced)
              (interaction-service-submit! interaction 'reload)
              (host-state-run! state)
              (unless (and (string=? (buffer-string buffer) "external-two")
                           (not (history-modified? history (buffer-id buffer)))
                           (not (file-service-conflict files (buffer-id buffer) #f)))
                (error 'fundamental-editing-tests
                       "revalidated reload did not replace the dirty Buffer"))

              (command-runtime-start!
                runtime 'fundamental.end-of-buffer
                (application-command-context application))
              (command-runtime-start!
                runtime 'fundamental.insert-text
                (application-command-context application) (list (string->utf8 " keep")))
              (vfs-write-file path (string->utf8 "external-ignore"))
              (publish-external! files buffer 'replaced)
              (interaction-service-submit! interaction 'ignore)
              (host-state-run! state)
              (unless (and (string=? (buffer-string buffer) "external-two keep")
                           (eq? (file-conflict-status
                                  (file-service-conflict files (buffer-id buffer)))
                                'ignored))
                (error 'fundamental-editing-tests
                       "ignore did not preserve Buffer contents and conflict state"))

              (vfs-write-file path (string->utf8 "external-overwrite"))
              (publish-external! files buffer 'replaced)
              (interaction-service-submit! interaction 'overwrite)
              (host-state-run! state)
              (unless (and (string=? (utf8->string (vfs-read-file path))
                                     "external-two keep")
                           (not (file-service-conflict files (buffer-id buffer) #f))
                           (not (history-modified? history (buffer-id buffer))))
                (error 'fundamental-editing-tests
                       "overwrite did not publish the current Buffer after revalidation"))

              (command-runtime-start!
                runtime 'fundamental.end-of-buffer
                (application-command-context application))
              (command-runtime-start!
                runtime 'fundamental.insert-text
                (application-command-context application) (list (string->utf8 " save-as")))
              (vfs-write-file path (string->utf8 "external-save-as"))
              (publish-external! files buffer 'replaced)
              (interaction-service-submit! interaction 'save-as)
              (host-state-run! state)
              (unless (eq? (interaction-request-kind
                             (interaction-session-request
                               (interaction-service-current interaction)))
                           'file-name)
                (error 'fundamental-editing-tests
                       "save-as conflict decision did not request a destination"))
              (interaction-service-submit! interaction saved-as)
              (host-state-run! state)
              (unless (eq? (interaction-request-kind
                             (interaction-session-request
                               (interaction-service-current interaction)))
                           'overwrite-decision)
                (error 'fundamental-editing-tests
                       "conflict save-as did not confirm an existing destination"))
              (vfs-write-file saved-as (string->utf8 "destination-new"))
              (interaction-service-submit! interaction 'overwrite)
              (host-state-run! state)
              (unless (and (string=? (utf8->string (vfs-read-file saved-as))
                                     "destination-new")
                           (string=?
                             (resource-locator
                               (file-service-resource files (buffer-id buffer)))
                             path)
                           (eq? (interaction-request-kind
                                  (interaction-session-request
                                    (interaction-service-current interaction)))
                                'external-file-change))
                (error 'fundamental-editing-tests
                       "stale save-as confirmation overwrote a newer destination"))
              (interaction-service-submit! interaction 'save-as)
              (host-state-run! state)
              (interaction-service-submit! interaction saved-as)
              (host-state-run! state)
              (interaction-service-submit! interaction 'overwrite)
              (host-state-run! state)
              (unless (and (string=? (utf8->string (vfs-read-file path))
                                     "external-save-as")
                           (string=? (utf8->string (vfs-read-file saved-as))
                                     "external-two keep save-as")
                           (string=?
                             (resource-locator
                               (file-service-resource files (buffer-id buffer)))
                             saved-as)
                           (not (file-service-conflict files (buffer-id buffer) #f)))
                (error 'fundamental-editing-tests
                       "save-as did not preserve the externally changed source")))))
        (lambda ()
          (soda-application-close! application)
          (when (file-exists? path) (delete-file path))
          (when (file-exists? saved-as) (delete-file saved-as)))))

    ;; Buffer word completion presents the existing CompletionController in
    ;; the minibuffer and commits the accepted candidate as an ordinary edit.
    (let ([application (make-soda-application)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [interaction (soda-application-interaction application)])
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application)
              (list (string->utf8 "alpha alphabet al")))
            (command-runtime-start-interactive!
              runtime 'word.complete (application-command-context application))
            (let ([request
                   (interaction-session-request
                     (interaction-service-current interaction))])
              (unless (and (eq? (interaction-request-kind request)
                                'word-completion)
                           (completion-source?
                             (interaction-request-completion-source request)))
                (error 'fundamental-editing-tests
                       "word completion did not use prompt completion presentation")))
            (interaction-service-submit! interaction "alphabet")
            (host-state-run! state)
            (unless (string=?
                      (buffer-string (soda-application-buffer application))
                      "alpha alphabet alphabet")
              (error 'fundamental-editing-tests
                     "word completion did not replace the active prefix"))))
        (lambda () (soda-application-close! application))))

    ;; Keyboard macros retain resolved command invocations.  Playback refreshes
    ;; the live editor context between steps, repeats deterministically, and
    ;; does not reopen interactive readers whose answers were already accepted.
    (let ([application (make-soda-application)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)]
                 [interaction (soda-application-interaction application)])
            (command-runtime-start!
              runtime 'macro.start (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application)
              (list (string->utf8 "x")))
            (command-runtime-start!
              runtime 'macro.end (application-command-context application))
            (command-runtime-start!
              runtime 'macro.play (application-command-context application)
              (list 3))
            (host-state-run! state)
            (unless (string=? (buffer-string (soda-application-buffer application))
                              "xxxx")
              (error 'fundamental-editing-tests
                     "keyboard macro playback did not refresh context per step"))

            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application)
              (list (string->utf8 " alpha alphabet al")))
            (command-runtime-start!
              runtime 'macro.start (application-command-context application))
            (command-runtime-start-interactive!
              runtime 'word.complete (application-command-context application))
            (interaction-service-submit! interaction "alphabet")
            (host-state-run! state)
            (command-runtime-start!
              runtime 'macro.end (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application)
              (list (string->utf8 " al")))
            (command-runtime-start!
              runtime 'macro.play (application-command-context application))
            (host-state-run! state)
            (unless (and
                      (string=?
                        (buffer-string (soda-application-buffer application))
                        "xxxx alpha alphabet alphabet alphabet")
                      (not (interaction-service-current interaction)))
              (error 'fundamental-editing-tests
                     "keyboard macro did not retain the resolved interactive answer"))))
        (lambda () (soda-application-close! application))))

    ;; Cancellation invalidates a queued macro step before it can invoke the
    ;; recorded command.
    (let ([application (make-soda-application)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (command-runtime-start!
              runtime 'macro.start (application-command-context application))
            (command-runtime-start!
              runtime 'fundamental.insert-text
              (application-command-context application)
              (list (string->utf8 "z")))
            (command-runtime-start!
              runtime 'macro.end (application-command-context application))
            (command-runtime-start!
              runtime 'macro.play (application-command-context application))
            (command-runtime-start!
              runtime 'macro.cancel (application-command-context application))
            (host-state-run! state)
            (unless (string=? (buffer-string (soda-application-buffer application))
                              "z")
              (error 'fundamental-editing-tests
                     "cancelled keyboard macro executed queued command debt"))))
        (lambda () (soda-application-close! application))))

    ;; Package retirement can remove a command retained by a macro.  Playback
    ;; stops at that boundary instead of retaining motion debt indefinitely.
    (let ([application (make-soda-application)]
          [temporary-owner (make-owner 'retired-macro-command-test)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (command-runtime-register-command!
              runtime
              (make-command-definition
                'test.retired-macro-command
                (lambda (context) (command-handled))
                temporary-owner "Temporary macro command." 'test #f))
            (command-runtime-start!
              runtime 'macro.start (application-command-context application))
            (command-runtime-start!
              runtime 'test.retired-macro-command
              (application-command-context application))
            (command-runtime-start!
              runtime 'macro.end (application-command-context application))
            (owner-close! temporary-owner)
            (command-runtime-start!
              runtime 'macro.play (application-command-context application))
            (host-state-run! state)
            (when (keyboard-macro-playing?
                    (soda-application-keyboard-macros application))
              (error 'fundamental-editing-tests
                     "keyboard macro retained an unregistered command"))))
        (lambda ()
          (when (owner-active? temporary-owner) (owner-close! temporary-owner))
          (soda-application-close! application))))

    ;; A visited file is normalized for editing and encoded from its binding
    ;; metadata on save, preserving CRLF, BOM, and final newline by default.
    (let* ([path (string-append "/tmp/soda-file-format-"
                                (number->string (get-process-id)) ".txt")]
           [source
            (u8-list->bytevector
              '(#xef #xbb #xbf #x6f #x6e #x65 #x0d #x0a
                #x74 #x77 #x6f #x0d #x0a))])
      (dynamic-wind
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (vfs-write-file path source))
        (lambda ()
          (let* ([application (make-soda-application)]
                 [state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (command-runtime-start!
                  runtime 'file.visit (application-command-context application)
                  (list path))
                (let* ([context (application-command-context application)]
                       [buffer
                        (buffer-service-ref
                          (host-state-buffers state)
                          (command-context-buffer-id context))]
                       [format
                        (file-service-format
                          (soda-application-files application) (buffer-id buffer))])
                  (unless (and (string=? (buffer-string buffer) "one\ntwo\n")
                               (eq? (file-format-newline format) 'crlf)
                               (file-format-final-newline? format)
                               (file-format-bom? format))
                    (error 'fundamental-editing-tests
                           "file visit did not normalize and retain format metadata"))
                  (command-runtime-start!
                    runtime 'file.save (application-command-context application))
                  (unless (bytevector=? (vfs-read-file path) source)
                    (error 'fundamental-editing-tests
                           "file save did not preserve external format"))))
              (lambda () (soda-application-close! application)))))
        (lambda ()
          (when (file-exists? path) (delete-file path)))))

    ;; Visiting claims a sibling lock file for the Buffer lifetime.  A foreign
    ;; claim leaves the Buffer read-only and survives Soda's close path.
    (let* ([path (string-append "/tmp/soda-file-lock-"
                                (number->string (get-process-id)) ".txt")]
           [lock (string-append path ".soda-lock")]
           [foreign-token (string->utf8 "foreign-lock")])
      (dynamic-wind
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? lock) (delete-file lock))
          (vfs-write-file path (string->utf8 "contents")))
        (lambda ()
          (let* ([application (make-soda-application)]
                 [state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application) (list path))
            (unless (vfs-file-exists? lock)
              (error 'fundamental-editing-tests "visiting a file did not acquire its lock"))
            (soda-application-close! application)
            (unless (not (vfs-file-exists? lock))
              (error 'fundamental-editing-tests "closing a file Buffer did not release its lock")))
          (unless (vfs-create-exclusive-file! lock foreign-token)
            (error 'fundamental-editing-tests "unable to create a foreign file lock"))
          (let* ([application (make-soda-application)]
                 [state (soda-application-state application)]
                 [runtime (host-state-command-runtime state)])
            (command-runtime-start!
              runtime 'file.visit (application-command-context application) (list path))
            (let ([buffer
                   (buffer-service-ref
                     (host-state-buffers state)
                     (command-context-buffer-id (application-command-context application)))])
              (unless (buffer-read-only? (buffer-state-configuration (buffer-state buffer)))
                (error 'fundamental-editing-tests
                       "a foreign lock did not make the visited Buffer read-only"))
              (command-runtime-start!
                runtime 'fundamental.insert-text
                (application-command-context application) (list (string->utf8 "blocked")))
              (unless (string=? (buffer-string buffer) "contents")
                (error 'fundamental-editing-tests
                       "a foreign lock did not reject normal editing")))
            (soda-application-close! application))
          (unless (and (vfs-file-exists? lock)
                       (bytevector=? (vfs-read-file lock) foreign-token))
            (error 'fundamental-editing-tests
                   "closing a conflicted Buffer changed the foreign lock")))
        (lambda ()
          (when (file-exists? path) (delete-file path))
          (when (file-exists? lock) (delete-file lock)))))

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

    ;; Saving an unvisited Buffer and Save As preserve an explicit overwrite boundary. A
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
                                                    ". Overwrite?"))
                           (= (length (interaction-request-actions request)) 2))
                (error 'fundamental-editing-tests
                       "file.save-as did not request overwrite confirmation")))
            (interaction-service-submit! interaction 'cancel)
            (host-state-run! state)
            (unless (and (string=? (utf8->string (vfs-read-file path)) "original")
                         (not (file-service-resource files (buffer-id buffer) #f)))
              (error 'fundamental-editing-tests
                     "declined file overwrite changed the resource or Buffer binding"))
            (command-runtime-start-interactive!
              runtime 'file.save-as (application-command-context application))
            (interaction-service-submit! interaction path)
            (host-state-run! state)
            (interaction-service-submit! interaction 'overwrite)
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
           [buffer (soda-application-buffer application)]
           [view (soda-application-view application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11")))
      (let ([layout
             (layout-text-snapshot
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 20 10)])
        (invoke-viewport-command! application 'fundamental.scroll-down layout))
      (unless (and (= (viewport-first-line (view-state-viewport (view-state view))) 0)
                   (= (viewport-visual-row (view-state-viewport (view-state view))) 2))
        (error 'fundamental-editing-tests "scroll-down did not advance the Viewport"))
      (let ([layout
             (layout-text-snapshot
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 2 20 10)])
        (invoke-viewport-command! application 'fundamental.scroll-up layout))
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
        runtime 'editor.toggle-line-numbers (application-command-context application))
      (command-runtime-start!
        runtime 'editor.toggle-guide-column (application-command-context application))
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
            [line-numbers?
             (line-numbers-enabled? (view-state-configuration (view-state view)))]
            [guide (guide-column (view-state-configuration (view-state view)))]
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
                     line-numbers?
                     (= guide 80)
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
      (let ([frame (surface-render-frame
                     (render-surface (soda-application-surface application)
                                     (host-state-views state)))])
        (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "1")
                     (eq? (frame-cell-face (frame-cell-at frame 0 0)) 'line-number)
                     (string=? (frame-cell-grapheme (frame-cell-at frame 1 0)) "2"))
          (error 'fundamental-editing-tests "line-number gutter did not render logical rows")))
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

    ;; View-scoped configuration must not leak through the shared Buffer to a
    ;; sibling View.  A split can therefore choose independent chrome and
    ;; layout without duplicating document state.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [views (host-state-views state)]
           [dispatcher (host-state-dispatch state)]
           [buffer (soda-application-buffer application)]
           [primary (soda-application-view application)]
           [owner (make-owner 'fundamental-view-scope-test)]
           [sibling
            (view-service-create!
              views owner buffer (view-state-configuration (view-state primary)))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (dispatcher-dispatch-view!
            dispatcher
            (make-view-transaction-spec
              (view-id primary) (view-state-generation (view-state primary))
              #f #f #f
              (list
                (make-compartment-reconfigure-effect
                  line-number-compartment (make-line-number-extension #t)))
              '() #f))
          (unless (and (line-numbers-enabled?
                         (view-state-configuration (view-state primary)))
                       (not (line-numbers-enabled?
                              (view-state-configuration (view-state sibling))))
                       (not (line-numbers-enabled?
                              (buffer-state-configuration (buffer-state buffer)))))
            (error 'fundamental-editing-tests
                   "View-local option escaped the target View configuration")))
        (lambda ()
          (view-service-close-view! views (view-id sibling))
          (owner-close! owner)
          (soda-application-close! application))))

    ;; Display options are rendered overlays rather than only configuration
    ;; values: the guide composes with text faces, and the persistent location
    ;; uses status chrome only when transient package feedback is absent.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [surface (soda-application-surface application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 (make-string 80 #\x))))
      (command-runtime-start!
        runtime 'editor.toggle-guide-column (application-command-context application))
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-feedback-operation (surface-id surface) #f))
      (let ([frame (surface-render-frame
                     (render-surface surface (host-state-views state)))])
        (unless (frame-cell-has-face? (frame-cell-at frame 0 79) 'guide-column)
          (error 'fundamental-editing-tests
                 "guide column did not compose into the rendered text cell")))
      (command-runtime-start!
        runtime 'editor.toggle-constant-position
        (application-command-context application))
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-feedback-operation (surface-id surface) #f))
      (command-runtime-start!
        runtime 'fundamental.goto-line
        (application-command-context application) (list 1 41))
      (let* ([frame (surface-render-frame
                      (render-surface surface (host-state-views state)))]
             [row (- (frame-height frame) 1)])
        (unless (string-prefix? "Line 1, column 41" (frame-row-string frame row))
          (error 'fundamental-editing-tests
                 "constant position did not reflect the active View selection")))
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-feedback-operation
          (surface-id surface) (make-user-feedback "temporary feedback")))
      (let* ([frame (surface-render-frame
                      (render-surface surface (host-state-views state)))]
             [row (- (frame-height frame) 1)])
        (unless (string-prefix? "temporary feedback" (frame-row-string frame row))
          (error 'fundamental-editing-tests
                 "transient Surface feedback did not take precedence over position chrome")))
      (soda-application-close! application))

    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [surface (soda-application-surface application)])
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "\tfoo  \nbar baz")))
      (command-runtime-start!
        runtime 'whitespace.toggle (application-command-context application))
      (let* ([render (render-surface surface (host-state-views state))]
             [frame (surface-render-frame render)]
             [hit (surface-render-hit-test render 0 0)])
        (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "→")
                     (eq? (surface-hit-kind hit) 'text)
                     (= (surface-hit-document-offset hit) 0))
          (error 'fundamental-editing-tests
                 "tab marker changed document hit-test semantics")))
      (command-runtime-start!
        runtime 'whitespace.toggle (application-command-context application))
      (let ([frame
             (surface-render-frame
               (render-surface surface (host-state-views state)))])
        (unless (frame-cell-has-face? (frame-cell-at frame 0 11)
                                      'whitespace.trailing)
          (error 'fundamental-editing-tests
                 "trailing whitespace decoration was not projected")))
      (command-runtime-start!
        runtime 'whitespace.toggle (application-command-context application))
      (let ([frame
             (surface-render-frame
               (render-surface surface (host-state-views state)))])
        (unless (string=? (frame-cell-grapheme (frame-cell-at frame 1 3)) "·")
          (error 'fundamental-editing-tests
                 "optional space markers were not projected")))
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

    ;; An off-screen point is absent from the terminal projection.  It must
    ;; not be represented by a synthetic cursor in the frame's final cell.
    (let* ([document (make-document "zero\none\ntwo\nthree")]
           [snapshot (document-snapshot document)]
           [selection (make-selection (list (make-selection-range 14 14)))]
           [layout (layout-text-snapshot snapshot selection 0 8 2)])
      (unless (and (not (text-layout-cursor-row layout))
                   (not (text-layout-cursor-column layout)))
        (error 'fundamental-editing-tests
               "off-screen point was clamped to the frame boundary"))
      (snapshot-close! snapshot)
      (document-close! document))

    ;; Horizontal point motion crosses visual viewport boundaries through the
    ;; shared reveal projection instead of leaving point off screen.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [runtime (host-state-command-runtime state)]
           [view (soda-application-view application)]
           [surface (soda-application-surface application)]
           [editing (soda-application-editing application)]
           [frontend
            (make-frontend
              state surface
              (lambda (active current-view)
                (buffer-input-context
                  active current-view
                  (list (fundamental-fallback-input-layer editing))))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme) #f)
              (make-render-service) default-theme)])
      ;; Stable mode-line and echo-area rows leave the same two document rows
      ;; that this wrapped-motion scenario exercises.
      (frontend-resize! frontend '(4 . 4))
      (frontend-step! frontend)
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "abcdefghijkl")))
      (command-runtime-start!
        runtime 'fundamental.beginning-of-buffer (application-command-context application))
      (frontend-step! frontend)
      (let move ([remaining 8])
        (when (> remaining 0)
          (frontend-enqueue!
            frontend
            (make-surface-input-message
              (surface-id surface)
              (make-key-event 'right #f #f #f 0 'press (make-bytevector 0))))
          (frontend-step! frontend)
          (move (- remaining 1))))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 1)
        (error 'fundamental-editing-tests
               "horizontal motion did not reveal point across a wrapped viewport"))
      (let move ([keys '(up up down down)])
        (when (pair? keys)
          (frontend-enqueue!
            frontend
            (make-surface-input-message
              (surface-id surface)
              (make-key-event (car keys) #f #f #f 0 'press (make-bytevector 0))))
          (frontend-step! frontend)
          (move (cdr keys))))
      (unless (and (= (selection-range-head
                        (selection-primary-range
                          (view-state-selection (view-state view))))
                      8)
                   (= (viewport-visual-row
                        (view-state-viewport (view-state view)))
                      1))
        (error 'fundamental-editing-tests
               "vertical arrow motion did not resolve point reveal requests"))
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface)
          (make-key-event 'character (char->integer #\v) #f #f 4 'press
                          (make-bytevector 0))))
      (frontend-step! frontend)
      (let ([render
             (render-surface
               surface (host-state-views state))])
        (unless (and (= (viewport-visual-row
                          (view-state-viewport (view-state view)))
                        1)
                     (string=?
                       (frame-cell-grapheme
                         (frame-cell-at (surface-render-frame render) 0 0))
                       "e")
                     (string=?
                       (frame-cell-grapheme
                         (frame-cell-at (surface-render-frame render) 1 0))
                       "i"))
          (error 'fundamental-editing-tests
                 "C-v left blank rows at the document end")))
      (frontend-close! frontend)
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
           [wide-position (text-layout-document-visual-position wide-text options 3 4)]
           [last-page
            (text-layout-page-start
              text options 4 2 (make-viewport 0 0) 1)])
      (unless (and (= (visual-position-line position) 0)
                   (= (visual-position-row position) 1)
                   (= (visual-position-offset next) 7)
                   (= (visual-position-line next) 1)
                   (= (visual-position-row next) 0)
                   (= (visual-position-offset previous) 4)
                   (= (visual-position-row tab-position) 1)
                   (= (visual-position-row wide-position) 1)
                   (= (visual-position-line last-page) 0)
                   (= (visual-position-row last-page) 1))
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
                   (= (viewport-visual-row (view-state-viewport (view-state view))) 0))
        (error 'fundamental-editing-tests
               "visual next-line did not cross the rendered boundary in document space"))
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
                   (= (viewport-visual-row (view-state-viewport (view-state view))) 0))
        (error 'fundamental-editing-tests
               "visual previous-line did not retain its target row"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
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
        (invoke-viewport-command! application 'fundamental.scroll-down layout))
      (unless (and (= (viewport-visual-row (view-state-viewport (view-state view))) 1)
                   (= (selection-range-head
                        (selection-primary-range
                          (view-state-selection (view-state view))))
                      4))
        (error 'fundamental-editing-tests
               "page down did not move an off-screen point into the new viewport"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 1 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command! application 'fundamental.scroll-down layout))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 1)
        (error 'fundamental-editing-tests
               "page down did not retain content on the final page"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 1 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command! application 'fundamental.scroll-up layout))
      (unless (and (= (viewport-visual-row (view-state-viewport (view-state view))) 0)
                   (= (selection-range-head
                        (selection-primary-range
                          (view-state-selection (view-state view))))
                      4))
        (error 'fundamental-editing-tests
               "page up did not restore viewport and keep point visible"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command!
          application 'fundamental.scroll-forward-line layout))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 1)
        (error 'fundamental-editing-tests
               "visual-line scroll did not advance the viewport"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 1 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command!
          application 'fundamental.scroll-backward-line layout))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 0)
        (error 'fundamental-editing-tests
               "visual-line scroll did not restore the viewport"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command! application 'fundamental.recenter layout))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 1)
        (error 'fundamental-editing-tests "recenter did not place point at window center"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 1 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command!
          application 'fundamental.recenter-bottom layout))
      (unless (= (viewport-visual-row (view-state-viewport (view-state view))) 0)
        (error 'fundamental-editing-tests
               "recenter-bottom did not place point at window bottom"))
      (let ([layout
             (layout-snapshot-display-stream
               (buffer-state-document (buffer-state buffer))
               (view-state-selection (view-state view)) 0 0 4 2
               (make-decoration-set '()) #f options)])
        (invoke-viewport-command!
          application 'fundamental.move-to-window-bottom layout))
      (unless (= (selection-range-head
                   (selection-primary-range
                     (view-state-selection (view-state view))))
                 4)
        (error 'fundamental-editing-tests
               "move-to-window-bottom did not target the final screen row"))
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
                (buffer-input-context
                  active current-view
                  (list (fundamental-fallback-input-layer editing))))
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
        (make-set-surface-feedback-operation
          (surface-id surface)
          (make-user-feedback "temporary feedback" 'info)))
      (send! (make-pointer-event 0 0 'none 0 0 'move))
      (unless (and (string=? (surface-feedback-text surface) "temporary feedback")
                   (eq? (user-feedback-severity (surface-feedback surface)) 'info))
        (error 'fundamental-editing-tests
               "passive pointer motion cleared echo-area feedback"))
      (send! (make-key-event 'left #f #f #f 0 'press (make-bytevector 0)))
      (unless (not (surface-feedback surface))
        (error 'fundamental-editing-tests
               "actionable input retained stale echo-area feedback"))
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-feedback-operation
          (surface-id surface) (make-user-feedback "previous feedback")))
      (send! (make-text-input-event 'text (string->utf8 "a")))
      (send! (make-key-event 'enter 13 #f #f 0 'press (make-bytevector 0)))
      (send! (make-text-input-event 'text (string->utf8 "b")))
      (send! (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0)))
      (send! (make-key-event 'tab 9 #f #f 0 'press (make-bytevector 0)))
      (unless (and (string=? (buffer-string buffer) "a\n\t")
                   (not (surface-feedback surface))
                   (= (selection-range-head
                        (selection-primary-range (view-state-selection (view-state view))))
                      3))
        (error 'fundamental-editing-tests
               "fundamental frontend input did not insert a tab or advance its caret"))
      (send! (make-text-input-event 'text (string->utf8 "x\ny\nz")))
      (command-runtime-start!
        (host-state-command-runtime state) 'fundamental.beginning-of-buffer
        (application-command-context application))
      (send! (make-key-event 'down #f #f #f 0 'press (make-bytevector 0)))
      (send! (make-key-event 'down #f #f #f 0 'release (make-bytevector 0)))
      (unless (= (selection-range-head
                   (selection-primary-range
                     (view-state-selection (view-state view))))
                 2)
        (error 'fundamental-editing-tests
               "one Down input did not produce exactly one line motion"))
      (frontend-close! frontend)
      (soda-application-close! application))

    ;; The application-owned composition is the authoritative input stack for
    ;; both ordinary Views and minibuffers.  A global override keymap retains
    ;; key priority without intercepting committed terminal text.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [decoder (make-terminal-input-decoder)]
           [event (car (terminal-input-decoder-feed!
                         decoder (string->utf8 "a")))]
           [active (surface-active-context surface (host-state-views state))]
           [view (view-service-ref
                   (host-state-views state) (active-context-view-id active))]
           [ordinary
            (input-dispatch
              (soda-application-resolve-input-context application active view)
              event)])
      (command-runtime-start-interactive!
        (host-state-command-runtime state) 'file.visit
        (application-command-context application))
      (host-state-run! state)
      (let* ([prompt-active
              (surface-active-context surface (host-state-views state))]
             [prompt-view
              (view-service-ref
                (host-state-views state)
                (active-context-view-id prompt-active))]
             [prompt
              (input-dispatch
                (soda-application-resolve-input-context
                  application prompt-active prompt-view)
                event)])
        (unless (and (eq? (input-disposition-kind ordinary) 'text)
                     (eq? (input-disposition-kind prompt) 'text))
          (error 'fundamental-editing-tests
                 "application override layer intercepted committed text")))
      (soda-application-close! application))

    ;; A legacy terminal may deliver repeated Escape bytes in one read or
    ;; split them across reads.  In both cases the decoder preserves the
    ;; application-level ESC ESC ESC sequence instead of inventing Alt+ESC.
    (let ([coalesced (make-terminal-input-decoder)]
          [chunked (make-terminal-input-decoder)]
          [escape-bytes (string->utf8 "\x1b;\x1b;\x1b;")])
      (define (escape-event? event)
        (and (key-event? event)
             (eq? (key-event-key event) 'escape)
             (zero? (key-event-modifiers event))))
      (let* ([immediate
              (terminal-input-decoder-feed! coalesced escape-bytes)]
             [flushed (terminal-input-decoder-flush! coalesced)]
             [events (append immediate flushed)])
        (unless (and (= (length immediate) 2)
                     (= (length flushed) 1)
                     (for-all escape-event? events)
                     (not (terminal-input-decoder-pending? coalesced)))
          (error 'fundamental-editing-tests
                 "coalesced legacy ESC sequence was not preserved")))
      (let* ([first
              (terminal-input-decoder-feed!
                chunked (string->utf8 "\x1b;"))]
             [second
              (terminal-input-decoder-feed!
                chunked (string->utf8 "\x1b;"))]
             [third
              (terminal-input-decoder-feed!
                chunked (string->utf8 "\x1b;"))]
             [last (terminal-input-decoder-flush! chunked)]
             [events (append first second third last)])
        (unless (and (null? first)
                     (= (length second) 1)
                     (= (length third) 1)
                     (= (length last) 1)
                     (for-all escape-event? events)
                     (not (terminal-input-decoder-pending? chunked)))
          (error 'fundamental-editing-tests
                 "chunked legacy ESC sequence was not preserved"))))

    ;; Application input translation gives an explicit Escape prefix the same
    ;; command semantics as a reported Meta modifier.  The rule applies to
    ;; ordinary and transient minibuffer keymaps without duplicating bindings.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [frontend
            (make-frontend
              state surface
              (lambda (active view)
                (soda-application-resolve-input-context application active view))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme) #f)
              (make-render-service) default-theme)])
      (define (send-key! key codepoint modifiers)
        (frontend-enqueue!
          frontend
          (make-surface-input-message
            (surface-id surface)
            (make-key-event
              key codepoint #f #f modifiers 'press (make-bytevector 0))))
        (frontend-step! frontend))
      (send-key! 'escape 27 0)
      (unless
        (exists
          (lambda (entry)
            (and (string=? (car entry) "ESC x")
                 (string=? (cdr entry) "command.execute-extended")))
          (surface-prefix-guidance surface))
        (error 'fundamental-editing-tests
               "Escape prefix guidance omitted the M-x alias"
               (surface-prefix-guidance surface)))
      (send-key! 'character (char->integer #\x) 0)
      (unless (minibuffer-service-current (soda-application-minibuffer application))
        (error 'fundamental-editing-tests
               "ESC x did not invoke the canonical M-x command"))
      (send-key! 'escape 27 0)
      (send-key! 'character (char->integer #\p) 0)
      (unless
        (let* ([session
                (minibuffer-service-current
                  (soda-application-minibuffer application))]
               [view
                (and session
                     (view-service-ref
                       (host-state-views state)
                       (minibuffer-session-view-id session)))])
          (and view
               (not
                 (input-stack-pending-sequence
                   (view-state-input-state (view-state view))))))
        (error 'fundamental-editing-tests
               "minibuffer ESC p did not resolve through the M-p binding"))
      (send-key! 'character (char->integer #\g) 4)
      (send-key! 'character (char->integer #\x) 2)
      (unless (minibuffer-service-current (soda-application-minibuffer application))
        (error 'fundamental-editing-tests
               "reported M-x diverged from its Escape-prefix alias"))
      (frontend-close! frontend)
      (soda-application-close! application))

    ;; Terminal protocol reports, scheduling, command execution, and Frame
    ;; presentation form one input contract.  A Kitty Down press followed by
    ;; release produces one motion and exposes no intermediate chrome frame.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [view (soda-application-view application)]
           [buffer (soda-application-buffer application)]
           [editing (soda-application-editing application)]
           [decoder (make-terminal-input-decoder)]
           [presented '()]
           [frontend
            (make-frontend
              state surface
              (lambda (active current-view)
                (buffer-input-context
                  active current-view
                  (list (fundamental-fallback-input-layer editing))))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme) (set! presented (cons render presented)))
              (make-render-service) default-theme)])
      (frontend-resize! frontend '(20 . 5))
      (frontend-step! frontend)
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface)
          (make-text-input-event 'text (string->utf8 "a\nb\nc"))))
      (frontend-step! frontend)
      (dispatcher-dispatch-view!
        (host-state-dispatch state)
        (make-view-transaction-spec
          (view-id view) (view-state-generation (view-state view))
          (make-selection (list (make-selection-range 0 0)))
          #f #f '() '() #f))
      (frontend-step! frontend)
      ;; A command whose dispatch leaves InputState unchanged must still run.
      ;; This is the normal clean-state path for a directly entered C-n.
      (let ([bytes (make-bytevector 1 14)])
        (for-each
          (lambda (event)
            (frontend-enqueue!
              frontend
              (make-surface-input-message (surface-id surface) event)))
          (terminal-input-decoder-feed! decoder bytes)))
      (frontend-step! frontend)
      (unless (= (selection-range-head
                   (selection-primary-range
                     (view-state-selection (view-state view))))
                 2)
        (error 'fundamental-editing-tests
               "clean-state C-n input did not dispatch its command"))
      (command-runtime-start!
        (host-state-command-runtime state) 'fundamental.beginning-of-buffer
        (application-command-context application))
      (command-runtime-start!
        (host-state-command-runtime state) 'editor.toggle-constant-position
        (application-command-context application))
      (let drain ([remaining 8])
        (when (and (> remaining 0) (frontend-pending? frontend))
          (frontend-step! frontend)
          (drain (- remaining 1))))
      (set! presented '())
      (for-each
        (lambda (event)
          (frontend-enqueue!
            frontend (make-surface-input-message (surface-id surface) event)))
        (terminal-input-decoder-feed!
          decoder (string->utf8 "\x1b;[1;1:1B\x1b;[1;1:3B")))
      (frontend-step! frontend)
      (unless (and
                (= (selection-range-head
                     (selection-primary-range
                       (view-state-selection (view-state view))))
                   2)
                (<= 1 (length presented) 2)
                (null? (surface-prefix-guidance surface))
                (let ([sessions
                       (input-stack-sessions
                         (view-state-input-state (view-state view)))])
                  (and (pair? sessions)
                       (input-session-transient? (car sessions))))
                (string-contains?
                  (frame-row-string
                    (surface-render-frame (car presented))
                    (- (frame-height (surface-render-frame (car presented))) 1))
                  "Line 2"))
        (error 'fundamental-editing-tests
               "terminal Down lifecycle exposed scheduling state or lost position feedback"
               (selection-range-head
                 (selection-primary-range
                   (view-state-selection (view-state view))))
               (length presented)
               (and (pair? presented)
                    (frame-row-string
                      (surface-render-frame (car presented))
                      (- (frame-height (surface-render-frame (car presented))) 1)))))
      (frontend-close! frontend)
      (soda-application-close! application))

    ;; A terminal read may enqueue several key events before the frontend gets
    ;; a chance to drain.  Each resulting command must run before the following
    ;; input snapshots its ViewState.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [view (soda-application-view application)]
           [editing (soda-application-editing application)]
           [presented-rows '()]
           [frontend
            (make-frontend
              state surface
              (lambda (active current-view)
                (buffer-input-context
                  active current-view
                  (list (fundamental-fallback-input-layer editing))))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme)
                (let ([row (surface-render-cursor-row render)])
                  (when row (set! presented-rows (cons row presented-rows)))))
              (make-render-service) default-theme)])
      (frontend-resize! frontend '(20 . 6))
      (frontend-step! frontend)
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface) (make-text-input-event 'text (string->utf8 "a\nb\nc\nd"))))
      (frontend-step! frontend)
      (set! presented-rows '())
      (do ([index 0 (+ index 1)])
          ((= index 3))
        (frontend-enqueue!
          frontend
          (make-surface-input-message
            (surface-id surface)
            (make-key-event 'up #f #f #f 0 'press (make-bytevector 0)))))
      (frontend-step! frontend)
      (let ([rows
             (let compress ([remaining (reverse presented-rows)] [last #f] [result '()])
               (cond
                 [(null? remaining) (reverse result)]
                 [(and last (= (car remaining) last))
                  (compress (cdr remaining) last result)]
                 [else
                  (compress (cdr remaining) (car remaining)
                            (cons (car remaining) result))]))])
        (unless (and (= (selection-range-head
                          (selection-primary-range (view-state-selection (view-state view))))
                        1)
                     (or (equal? rows '(2 1 0))
                         (equal? rows '(3 2 1 0))))
          (error 'fundamental-editing-tests
                 "a burst of vertical input did not preserve visible motion feedback" rows)))
      (command-runtime-start!
        (host-state-command-runtime state) 'fundamental.end-of-buffer
        (application-command-context application))
      (frontend-step! frontend)
      (do ([index 0 (+ index 1)])
          ((= index 3))
        (frontend-enqueue!
          frontend
          (make-surface-input-message
            (surface-id surface)
            (make-key-event 'up #f #f #f 0 'repeat (make-bytevector 0)))))
      (frontend-step! frontend)
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 1)
        (error 'fundamental-editing-tests
               "queued key repeats did not each produce one motion"))
      (command-runtime-start!
        (host-state-command-runtime state) 'fundamental.end-of-buffer
        (application-command-context application))
      (frontend-step! frontend)
      (do ([index 0 (+ index 1)])
          ((= index 3))
        (frontend-enqueue!
          frontend
          (make-surface-input-message
            (surface-id surface)
            (make-key-event 'up #f #f #f 0 'repeat (make-bytevector 0)))))
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface)
          (make-key-event 'up #f #f #f 0 'release (make-bytevector 0))))
      (frontend-step! frontend)
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 7)
        (error 'fundamental-editing-tests
               "released vertical input executed queued repeat debt"))
      (dispatcher-dispatch-view!
        (host-state-dispatch state)
        (make-view-transaction-spec
          (view-id view) (view-state-generation (view-state view))
          (make-selection (list (make-selection-range 2 2)))
          #f #f '() '() #f))
      (frontend-step! frontend)
      (do ([index 0 (+ index 1)])
          ((= index 3))
        (frontend-enqueue!
          frontend
          (make-surface-input-message
            (surface-id surface)
            (make-key-event 'down #f #f #f 0 'repeat (make-bytevector 0)))))
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface)
          (make-key-event 'up #f #f #f 0 'press (make-bytevector 0))))
      (frontend-step! frontend)
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 0)
        (error 'fundamental-editing-tests
               "opposite key press did not supersede queued repeat debt"))
      (dispatcher-dispatch-view!
        (host-state-dispatch state)
        (make-view-transaction-spec
          (view-id view) (view-state-generation (view-state view))
          (make-selection (list (make-selection-range 0 0)))
          #f #f '() '() #f))
      (frontend-step! frontend)
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface)
          (make-key-event 'character (char->integer #\n) #f #f 4 'press
                          (make-bytevector 0))))
      (do ([index 0 (+ index 1)])
          ((= index 3))
        (frontend-enqueue!
          frontend
          (make-surface-input-message
            (surface-id surface)
            (make-key-event 'character (char->integer #\n) #f #f 4 'repeat
                            (make-bytevector 0)))))
      (frontend-step-action! frontend)
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 2)
        (error 'fundamental-editing-tests
               "one action turn consumed more than one C-n motion"))
      ;; A terminal loop polls again here.  The new C-p press cancels C-n
      ;; repeat debt before the next action turn begins.
      (frontend-enqueue!
        frontend
        (make-surface-input-message
          (surface-id surface)
          (make-key-event 'character (char->integer #\p) #f #f 4 'press
                          (make-bytevector 0))))
      (frontend-step-action! frontend)
      (unless (= (selection-range-head
                   (selection-primary-range (view-state-selection (view-state view))))
                 0)
        (error 'fundamental-editing-tests
               "C-p did not preempt queued C-n action turns"))
      (frontend-close! frontend)
      (soda-application-close! application))

    ;; Prefix guidance is derived from the active keymaps and appears only
    ;; while a prefix is pending.  Ordinary editing keeps the echo area free
    ;; for messages and position feedback.
    (let* ([application (make-soda-application)]
           [state (soda-application-state application)]
           [surface (soda-application-surface application)]
           [view (soda-application-view application)]
           [editing (soda-application-editing application)]
           [active (surface-active-context surface (host-state-views state))]
           [context
            (buffer-input-context
              active view
              (list
                (make-input-layer
                  'default
                  (file-keymap (soda-application-files application))
                  #f 'accept)
                (fundamental-fallback-input-layer editing)))]
           [presented #f]
           [frontend
            (make-frontend
              state surface
              (lambda (active current-view)
                (buffer-input-context
                  active current-view
                  (list
                    (make-input-layer
                      'default
                      (file-keymap (soda-application-files application))
                      #f 'accept)
                    (fundamental-fallback-input-layer editing))))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme) (set! presented render))
              (make-render-service) default-theme)])
      (define (send! event)
        (frontend-enqueue!
          frontend (make-surface-input-message (surface-id surface) event))
        (frontend-step! frontend))
      (unless
        (null?
          (command-prefix-guidance
            (host-state-command-runtime state)
            (application-command-context application)
            context))
        (error 'fundamental-editing-tests
               "prefix guidance API exposed bindings without a pending prefix"))
      (frontend-resize! frontend '(20 . 6))
      (frontend-step! frontend)
      (unless (null? (surface-prefix-guidance surface))
        (error 'fundamental-editing-tests
               "ordinary editing exposed persistent prefix guidance"))
      (send! (make-key-event 'character (char->integer #\x) #f #f 4 'press
                             (make-bytevector 0)))
      (unless (and
                (exists
                  (lambda (entry)
                    (and (string=? (car entry) "C-x C-f")
                         (string=? (cdr entry) "file.visit")))
                  (surface-prefix-guidance surface))
                (string-contains?
                  (frame-row-string
                    (surface-render-frame presented)
                    (- (frame-height (surface-render-frame presented)) 1))
                  "C-x"))
        (error 'fundamental-editing-tests
               "pending prefix did not expose contextual next-key guidance"))
      (send! (make-key-event 'character (char->integer #\g) #f #f 4 'press
                             (make-bytevector 0)))
      (unless (null? (surface-prefix-guidance surface))
        (error 'fundamental-editing-tests
               "completed prefix retained stale prefix guidance"))
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
           [presented #f]
           [frontend
            (make-frontend
              state surface
              (lambda (active current-view)
                (buffer-input-context
                  active current-view
                  (list
                    (make-input-layer
                      'default
                      (file-keymap (soda-application-files application))
                      #f 'accept)
                    (fundamental-fallback-input-layer editing))))
              (lambda (context disposition)
                (fundamental-input-disposition context disposition))
              (lambda (render theme) (set! presented render))
              (make-render-service) default-theme)])
      (define (send! event)
        (frontend-enqueue!
          frontend (make-surface-input-message (surface-id surface) event))
        (frontend-step! frontend))
      (frontend-resize! frontend '(4 . 4))
      (frontend-step! frontend)
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (make-set-surface-feedback-operation
          (surface-id surface)
          (make-user-feedback "previous alert" 'warning)))
      (send! (make-key-event 'character (char->integer #\x) #f #f 4 'press
                             (make-bytevector 0)))
      (unless (and
                (exists
                  (lambda (entry)
                    (and (string=? (car entry) "C-x C-f")
                         (string=? (cdr entry) "file.visit")))
                  (surface-prefix-guidance surface))
                (string-contains?
                  (frame-row-string
                    (surface-render-frame presented)
                    (- (frame-height (surface-render-frame presented)) 1))
                  "C-x")
                (not
                  (string-contains?
                    (frame-row-string
                      (surface-render-frame presented)
                      (- (frame-height (surface-render-frame presented)) 1))
                    "previous alert"))
                (let ([rendered
                       (find
                         (lambda (candidate)
                           (= (rendered-view-view-id candidate) (view-id view)))
                         (surface-render-rendered-views presented))])
                  (and rendered
                       (= (cadddr (rendered-view-rectangle rendered)) 2))))
        (error 'fundamental-editing-tests
               "prefix guidance did not reserve layout or reflect the pending prefix"))
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
