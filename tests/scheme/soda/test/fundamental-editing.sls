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
          (soda host input)
          (soda host input-event)
          (soda host analysis)
          (soda host location)
          (soda host package)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal mode)
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
          (soda kernel location)
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
          (soda packages file)
          (soda packages file-format)
          (soda packages file-watch)
          (soda packages directory)
          (soda packages editor-options)
          (soda packages buffer-ui)
          (soda packages buffer-list)
          (soda packages search)
          (soda packages scheme-mode)
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
                   (eq? (input-disposition-value uncut) 'fundamental.yank)
                   (eq? (input-disposition-value cut-text) 'fundamental.cut-text)
                   (eq? (input-disposition-value justify) 'fundamental.fill-paragraph)
                   (eq? (input-disposition-value set-mark) 'fundamental.set-mark)
                   (eq? (command-invocation-phase redraw) 'completed)
                   (= (surface-generation surface) (+ before-surface-generation 1))
                   (eq? (keymap-lookup
                          (fundamental-editing-keymap editing)
                          (list (make-key-stroke 'character (char->integer #\l) 4)))
                        'fundamental.recenter)
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
                       'fundamental.end-of-buffer)
                   (eq? (keymap-lookup keymap (list (control #\l)))
                       'fundamental.recenter)
                   (eq? (keymap-lookup keymap (list (meta #\r)))
                       'fundamental.move-to-window-center)
                   (eq? (keymap-lookup keymap (list (make-key-stroke 'up #f 0)))
                       'fundamental.previous-line)
                   (eq? (keymap-lookup keymap (list (make-key-stroke 'down #f 0)))
                       'fundamental.next-line))
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

    ;; Nano's regexp mode is View-local.  It keeps the ordinary search,
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
                   "help mode exposed an ordinary editing command"))))
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
                     (eq? (input-disposition-value disposition) 'interaction.submit-key))
          (error 'fundamental-editing-tests
                 "query replace prompt did not install its discrete answer keymap"))
        (command-runtime-start! runtime 'interaction.submit-key context))
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
        (send! (make-key-event 'end #f #f #f 0 'press (make-bytevector 0)))
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
      (command-runtime-start-interactive!
        runtime 'command.execute-extended (application-command-context application))
      (let* ([request
              (interaction-session-request (interaction-service-current interaction))]
             [controller (minibuffer-service-refresh-completion! minibuffer)])
        (unless (and (eq? (interaction-request-kind request) 'command)
                     (eq? (interaction-request-selection-policy request) 'must-match)
                     controller
                     (exists
                       (lambda (candidate)
                         (string=? (completion-candidate-insert-text candidate)
                                   "fundamental.insert-text"))
                       (completion-controller-candidates controller)))
          (error 'fundamental-editing-tests
                 "M-x did not expose mode-aware command completion")))
      (interaction-service-submit! interaction "message.show-position")
      (host-state-run! state)
      (host-state-run! state)
      (let ([message (surface-status-message (soda-application-surface application))])
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
      (command-runtime-start-interactive!
        runtime 'command.describe (application-command-context application))
      (interaction-service-submit! interaction "message.show-position")
      (host-state-run! state)
      (let ([message (surface-status-message (soda-application-surface application))])
        (unless (and message (string-contains? message "Show the active selection"))
          (error 'fundamental-editing-tests
                 "describe-command did not use command metadata" message)))
      (command-runtime-start-interactive!
        runtime 'command.where-is (application-command-context application))
      (interaction-service-submit! interaction "message.show-position")
      (host-state-run! state)
      (unless (string-contains?
                (surface-status-message (soda-application-surface application)) "C-c")
        (error 'fundamental-editing-tests "where-is did not reverse-query active keymaps"))
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
                      configuration buffer-syntax-profile-facet 'buffer)]
                   [layers
                    (configuration-facet
                      configuration buffer-input-layers-facet 'buffer)])
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
                             runtime 'scheme.comment-lines context)
                           (eq? (cadr
                                  (resolve-key-sequence
                                    layers
                                    (list (make-key-stroke
                                            'character (char->integer #\;) 2))))
                                'scheme.comment-lines))
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
                runtime 'scheme.comment-lines
                (application-command-context application))
              (unless (string-prefix?
                        "; "
                        (buffer-string
                          (buffer-service-ref
                            (host-state-buffers state)
                            (command-context-buffer-id context))))
                (error 'fundamental-editing-tests
                       "Scheme mode command did not publish a normal transaction")))))
        (lambda ()
          (soda-application-close! application)
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
                             (= (file-watch-service-binding-count
                                  (file-service-watch-service files))
                                (- watch-count-before-close 1))
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
              (interaction-service-submit! interaction "r")
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
              (interaction-service-submit! interaction "r")
              (host-state-run! state)
              (unless (and (string=? (buffer-string buffer) "race local")
                           (file-service-conflict files (buffer-id buffer) #f))
                (error 'fundamental-editing-tests
                       "stale reload decision crossed the disk-version boundary"))
              (publish-external! files buffer 'replaced)
              (interaction-service-submit! interaction "r")
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
              (interaction-service-submit! interaction "i")
              (host-state-run! state)
              (unless (and (string=? (buffer-string buffer) "external-two keep")
                           (eq? (file-conflict-status
                                  (file-service-conflict files (buffer-id buffer)))
                                'ignored))
                (error 'fundamental-editing-tests
                       "ignore did not preserve Buffer contents and conflict state"))

              (vfs-write-file path (string->utf8 "external-overwrite"))
              (publish-external! files buffer 'replaced)
              (interaction-service-submit! interaction "o")
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
              (interaction-service-submit! interaction "s")
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
              (interaction-service-submit! interaction "yes")
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
              (interaction-service-submit! interaction "s")
              (host-state-run! state)
              (interaction-service-submit! interaction saved-as)
              (host-state-run! state)
              (interaction-service-submit! interaction "yes")
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
        (make-set-surface-message-operation (surface-id surface) #f))
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
        (make-set-surface-message-operation (surface-id surface) #f))
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
        (make-set-surface-message-operation (surface-id surface) "temporary feedback"))
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
      (frontend-resize! frontend '(4 . 2))
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
                     (equal? rows '(3 2 1 0)))
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
                 5)
        (error 'fundamental-editing-tests
               "queued key repeats were not compacted to current input state"))
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
