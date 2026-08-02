(library (soda editor git-results)
  (export install-git-results! start-git-status! git-status-record-fields)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor compilation)
          (soda editor condition)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor keymap)
          (soda editor language)
          (soda editor line-stream)
          (soda editor location)
          (soda editor location-results)
          (soda editor managed-process)
          (soda editor prompt)
          (soda editor project)
          (soda editor result-buffer)
          (soda editor result-producer-session)
          (soda editor state)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (git-status-session %make-git-status-session git-status-session?)
    (parent result-producer-session)
    (fields project root
            (mutable operation-process)
            (mutable rename-record)))

  (define active-git-statuses (make-result-producer-registry))

  (define (git-status-session-active-process session)
    (let ([operation (git-status-session-operation-process session)]
          [status (result-producer-session-process session)])
      (cond
        ;; An operation belongs to the session as soon as its start effect is
        ;; emitted.  It may still be in the created state until the runtime
        ;; consumes that effect, but it is already the task that cancellation
        ;; must target.
        [operation operation]
        [(and status (managed-process-running? status)) status]
        [else #f])))

  (define-record-type git-operation
    (fields status-session label (mutable stderr-output)))

  (define-record-type git-discard-request
    (fields status-session paths))

  (define-record-type git-commit-request
    (fields status-session))

  (define (nonblank-string? value)
    (and
      (string? value)
      (exists
        (lambda (character) (not (char-whitespace? character)))
        (string->list value))))

  (define (rename-status? status)
    (and (= (string-length status) 2)
         (or (memv (string-ref status 0) '(#\R #\C))
             (memv (string-ref status 1) '(#\R #\C)))))

  (define (decode-record bytes)
    (guard (condition [else #f]) (utf8->string bytes)))

  (define (git-status-record-fields value)
    (and value
         (>= (string-length value) 3)
         (char=? (string-ref value 2) #\space)
         (list (substring value 0 2)
               (substring value 3 (string-length value)))))

  (define (status-item root status path)
    (make-location-item
      #f (vfs-resolve-path root path) 0 0 0 path
      (list
        (cons 'file-open-position (make-file-utf16-position 0 0))
        (cons 'git-status status))))

  (define (append-status! editor session status path original)
    (let* ([line
             (string-append
               status "  " path
               (if original (string-append "  <-  " original) "")
               "\n")]
           [item (status-item (git-status-session-root session) status path)])
      (editor-append-result-text!
        editor (result-producer-session-buffer session) line
        (if item
            (list (list 0 (bytevector-length (string->utf8 line)) item))
            '()))))

  (define (consume-records! editor session records)
    (for-each
      (lambda (bytes)
        (let ([pending (git-status-session-rename-record session)]
              [value (decode-record bytes)])
          (cond
            [pending
             (append-status! editor session (car pending) (cadr pending) value)
             (git-status-session-rename-record-set! session #f)]
            [(git-status-record-fields value) =>
             (lambda (fields)
               (if (rename-status? (car fields))
                   (git-status-session-rename-record-set! session fields)
                   (append-status! editor session (car fields) (cadr fields) #f)))])))
      records))

  (define (apply-git-status-output context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [session
             (result-producer-event-session
               active-git-statuses editor event git-status-session?)])
      (when session
        (cond
          [(= (managed-process-event-flags event) process-stdout)
           (consume-records!
             editor
             session
             (result-producer-split-output!
               session
               (managed-process-event-data event)
               (lambda (bytes) (split-complete-records bytes 0))))]
          [(= (managed-process-event-flags event) process-stderr)
           (result-producer-append-error-output!
             session (managed-process-event-data event))]))
      '()))

  (define (apply-git-status-exit context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [session
             (result-producer-event-session
               active-git-statuses editor event git-status-session?)])
      (when session
        (let ([remainder (result-producer-session-pending-output session)])
          (unless (zero? (bytevector-length remainder))
            (consume-records! editor session (list remainder))))
        (when (git-status-session-rename-record session)
          (let ([pending (git-status-session-rename-record session)])
            (append-status! editor session (car pending) (cadr pending) #f)
            (git-status-session-rename-record-set! session #f)))
        (let* ([status (managed-process-event-status event)]
               [count
                 (length
                   (location-list-items
                     (result-producer-session-locations session)))])
          (editor-finish-result-producer!
            editor
            (result-producer-session-buffer session)
            (if (zero? status) 'ready 'failed)
            (cond
              [(and (zero? status) (zero? count))
               "Working tree clean."]
              [(not (zero? status))
               (let ([stderr (result-producer-session-error-output session)])
                 (if (zero? (bytevector-length stderr))
                     (string-append
                       "Git status failed with status "
                       (number->string status))
                     (guard (condition [else "Git status produced invalid UTF-8"])
                       (utf8->string stderr))))]
              [else #f])
            (if (zero? status) 'info 'error))
          (editor-set-status-message!
            editor
            (if (zero? status)
                (string-append
                  "Git status: "
                  (number->string count)
                  " files")
                (string-append
                  "Git status failed with status " (number->string status))))))
      '()))

  (define (cancel-git-status context)
    (let* ([editor (command-context-editor context)]
           [session (command-context-argument context)])
      (if (not (git-status-session? session))
          '()
          (let* ([operation
                   (git-status-session-operation-process session)]
                 [process (git-status-session-active-process session)]
                 [operation? (and operation (eq? process operation))])
            (result-producer-cancel!
              active-git-statuses
              editor
              session
              process
              (if operation?
                  "Git operation cancelled."
                  "Git status cancelled."))))))

  (define (start-git-status! context project)
    (let* ([editor (command-context-editor context)]
           [origin-view-id
             (editor-result-origin-view-id editor (command-context-view context))]
           [scope
             (view-workbench-id
               (editor-view-ref editor origin-view-id))]
           [root (project-primary-root project)]
           [locations (make-location-list 'git-status '())]
           [session
             (%make-git-status-session
               origin-view-id scope locations #f #f
               (make-bytevector 0) (make-bytevector 0) #f
               project root #f #f)]
           [process
             (make-managed-process
               "git-status"
               (list "git" "status" "--porcelain=v1" "-z"
                     "--untracked-files=all")
               root session 'git.status-output 'git.status-exit)]
           [old
             (result-producer-registry-ref
               active-git-statuses editor scope)]
           [buffer
             (editor-open-result-buffer!
               editor "*Git Status*" 'git-status-mode
               "Git status" locations origin-view-id
               'git-status 'git.status-cancel session)])
      (result-producer-session-buffer-set! session buffer)
      (result-producer-session-process-set! session process)
      (buffer-set-result-producer-state! buffer 'running)
      (buffer-set-local! buffer 'git-status-session session)
      (register-git-status-actions! buffer session)
      (buffer-set-result-refresh!
        buffer
        (lambda (refresh-context refresh-buffer)
          (start-git-status! refresh-context project)))
      (result-producer-registry-activate!
        active-git-statuses editor session)
      (editor-set-current-location-list! editor locations)
      (let ([old-process
              (and old (git-status-session-active-process old))])
        (append
          (if old
              (result-producer-retire! old old-process)
              '())
          (list (make-command-effect 'managed-process.start process))))))

  (define (item-status item)
    (let ([entry
            (and (list? (location-item-metadata item))
                 (assq 'git-status (location-item-metadata item)))])
      (and entry (cdr entry))))

  (define (status-result-view editor session)
    (find
      (lambda (view)
        (eq? (view-buffer view) (result-producer-session-buffer session)))
      (editor-views editor)))

  (define (apply-git-operation-output context)
    (let* ([event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [operation (and process (managed-process-owner process))])
      (when (and (git-operation? operation)
                 (let ([session
                         (git-operation-status-session operation)])
                   (and
                     (not (result-producer-session-closed? session))
                     (eq?
                       process
                       (git-status-session-operation-process session))))
                 (= (managed-process-event-flags event) process-stderr))
        (git-operation-stderr-output-set!
          operation
          (bytevector-append
            (git-operation-stderr-output operation)
            (managed-process-event-data event))))
      '()))

  (define (apply-git-operation-exit context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [operation (and process (managed-process-owner process))])
      (if (not (git-operation? operation))
          '()
          (let* ([status (managed-process-event-status event)]
                 [session (git-operation-status-session operation)]
                 [view (status-result-view editor session)])
            (if (or (result-producer-session-closed? session)
                    (not
                      (eq? process
                           (git-status-session-operation-process session))))
                '()
                (begin
                  (git-status-session-operation-process-set! session #f)
                  (if (zero? status)
                      (begin
                        (editor-set-status-message!
                          editor
                          (string-append
                            (git-operation-label operation)
                            " succeeded"))
                        (if view
                            (start-git-status!
                              (make-command-context editor view #f #f #f)
                              (git-status-session-project session))
                            (begin
                              (editor-finish-result-producer!
                                editor
                                (result-producer-session-buffer session)
                                'ready
                                (string-append
                                  (git-operation-label operation)
                                  " succeeded.")
                                'info)
                              '())))
                      (let ([message
                              (let ([stderr
                                      (git-operation-stderr-output operation)])
                                (if (zero? (bytevector-length stderr))
                                    (string-append
                                      (git-operation-label operation)
                                      " failed with status "
                                      (number->string status))
                                    (guard
                                      (condition [else "Git operation failed"])
                                      (utf8->string stderr))))])
                        (editor-finish-result-producer!
                          editor
                          (result-producer-session-buffer session)
                          'failed
                          message
                          'error)
                        (editor-set-status-message! editor message)
                        '()))))))))

  (define (start-git-operation session label arguments)
    (let* ([operation
             (make-git-operation session label (make-bytevector 0))]
           [process
             (make-managed-process
               label arguments (git-status-session-root session) operation
               'git.operation-output 'git.operation-exit)])
      (buffer-set-result-producer-state!
        (result-producer-session-buffer session) 'running)
      (git-status-session-operation-process-set! session process)
      (list (make-command-effect 'managed-process.start process))))

  (define (git-status-item? buffer item)
    (and (location-item? item) (item-status item)))

  (define (git-status-action-ready? buffer item)
    (and
      (eq? (buffer-result-producer-state buffer) 'ready)
      (git-status-item? buffer item)))

  (define (untracked-status? status)
    (and (string? status) (string=? status "??")))

  (define (index-change? status)
    (and
      (string? status)
      (= (string-length status) 2)
      (not (memv (string-ref status 0) '(#\space #\? #\!)))))

  (define (worktree-change? status)
    (and
      (string? status)
      (= (string-length status) 2)
      (or
        (untracked-status? status)
        (not (memv (string-ref status 1) '(#\space #\!))))))

  (define (git-stageable-item? buffer item)
    (and
      (git-status-action-ready? buffer item)
      (worktree-change? (item-status item))))

  (define (git-unstageable-item? buffer item)
    (and
      (git-status-action-ready? buffer item)
      (index-change? (item-status item))))

  (define (git-diffable-item? buffer item)
    (and
      (git-status-action-ready? buffer item)
      (not (untracked-status? (item-status item)))))

  (define (git-staged-diffable-item? buffer item)
    (and
      (git-status-action-ready? buffer item)
      (index-change? (item-status item))))

  (define (git-discardable-item? buffer item)
    (and
      (git-status-action-ready? buffer item)
      (worktree-change? (item-status item))
      (not (untracked-status? (item-status item)))))

  (define (start-git-diff context session item cached?)
    (let ([arguments
            (append
              (list "git" "diff" "--no-ext-diff")
              (if cached? (list "--cached") '())
              (list "--" (location-item-excerpt item)))])
      (start-compilation!
        context
        (string-append
          (if cached? "Git staged diff: " "Git diff: ")
          (location-item-excerpt item))
        arguments
        (git-status-session-root session))))

  (define (marked-git-paths entries)
    (map
      (lambda (entry) (location-item-excerpt (cdr entry)))
      entries))

  (define (request-git-discard! context session paths)
    (let ([editor (command-context-editor context)]
          [count (length paths)])
      (editor-open-prompt!
        editor
        (make-prompt-request
          (string-append
            "Discard worktree changes in "
            (number->string count)
            (if (= count 1) " path" " paths")
            "? Type yes: ")
          ""
          #f
          #f
          'free
          (lambda (value) (string-ci=? value "yes"))
          'git.apply-discard
          #f
          (make-git-discard-request session paths)))
      '()))

  (define (apply-git-discard context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [request
             (and (prompt-result? result) (prompt-result-data result))])
      (if
        (and
          (git-discard-request? request)
          (eq? (prompt-result-status result) 'accepted)
          (string-ci=? (prompt-result-value result) "yes")
          (result-producer-registry-current?
            active-git-statuses
            editor
            (git-discard-request-status-session request))
          (eq?
            (buffer-result-producer-state
              (result-producer-session-buffer
                (git-discard-request-status-session request)))
            'ready))
        (start-git-operation
          (git-discard-request-status-session request)
          "Git discard worktree changes"
          (append
            (list "git" "restore" "--worktree" "--")
            (git-discard-request-paths request)))
        (begin
          (editor-set-status-message!
            editor "Git discard was not applied")
          '()))))

  (define (git-status-has-staged-changes? buffer)
    (and
      (eq? (buffer-result-producer-state buffer) 'ready)
      (exists
        (lambda (range)
          (let ([item
                  (buffer-text-property-ref
                    buffer (car range) 'result-item #f)])
            (and item (index-change? (item-status item)))))
        (buffer-text-property-ranges buffer 'result-index))))

  (define (request-git-commit! context buffer)
    (let* ([editor (command-context-editor context)]
           [session (buffer-local-ref buffer 'git-status-session #f)])
      (unless
        (and
          (git-status-session? session)
          (result-producer-registry-current?
            active-git-statuses editor session)
          (git-status-has-staged-changes? buffer))
        (editor-user-error
          'git.commit "No staged changes are ready to commit"))
      (editor-open-prompt!
        editor
        (make-prompt-request
          "Commit message: "
          ""
          'git-commit-message
          #f
          'free
          nonblank-string?
          'git.apply-commit
          #f
          (make-git-commit-request session)))
      '()))

  (define (apply-git-commit context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [request
             (and (prompt-result? result) (prompt-result-data result))]
           [message
             (and (prompt-result? result) (prompt-result-value result))]
           [session
             (and
               (git-commit-request? request)
               (git-commit-request-status-session request))])
      (if
        (and
          session
          (eq? (prompt-result-status result) 'accepted)
          (nonblank-string? message)
          (result-producer-registry-current?
            active-git-statuses editor session)
          (git-status-has-staged-changes?
            (result-producer-session-buffer session)))
        (start-git-operation
          session
          "Git commit"
          (list "git" "commit" "-m" message))
        (begin
          (editor-set-status-message! editor "Git commit was not started")
          '()))))

  (define (register-git-status-actions! buffer session)
    (buffer-register-result-panel-action!
      buffer
      (make-result-panel-action
        'commit
        "Commit staged changes"
        git-status-has-staged-changes?
        request-git-commit!))
    (for-each
      (lambda (action)
        (buffer-register-result-action! buffer action))
      (list
        (make-result-action
          'stage "Stage"
          git-stageable-item?
          (lambda (context buffer item index)
            (start-git-operation
              session "Git stage"
              (list "git" "add" "--" (location-item-excerpt item))))
          (lambda (context buffer entries)
            (start-git-operation
              session "Git stage"
              (append
                (list "git" "add" "--")
                (marked-git-paths entries)))))
        (make-result-action
          'unstage "Unstage"
          git-unstageable-item?
          (lambda (context buffer item index)
            (start-git-operation
              session "Git unstage"
              (list "git" "reset" "--" (location-item-excerpt item))))
          (lambda (context buffer entries)
            (start-git-operation
              session "Git unstage"
              (append
                (list "git" "reset" "--")
                (marked-git-paths entries)))))
        (make-result-action
          'diff "Show diff"
          git-diffable-item?
          (lambda (context buffer item index)
            (let ([status (item-status item)])
              (start-git-diff
                context
                session
                item
                (and (index-change? status)
                     (not (worktree-change? status)))))))
        (make-result-action
          'diff-staged "Show staged diff"
          git-staged-diffable-item?
          (lambda (context buffer item index)
            (start-git-diff context session item #t)))
        (make-result-action
          'discard "Discard worktree changes"
          git-discardable-item?
          (lambda (context buffer item index)
            (request-git-discard!
              context session (list (location-item-excerpt item))))
          (lambda (context buffer entries)
            (request-git-discard!
              context session (marked-git-paths entries))))))
    buffer)

  (define (stage-git-entry context)
    (invoke-buffer-item-action context 'stage))

  (define (unstage-git-entry context)
    (invoke-buffer-item-action context 'unstage))

  (define (diff-git-entry context)
    (invoke-buffer-item-action context 'diff))

  (define (diff-staged-git-entry context)
    (invoke-buffer-item-action context 'diff-staged))

  (define (discard-git-entry context)
    (invoke-buffer-item-action context 'discard))

  (define (commit-git-status context)
    (invoke-result-panel-action context 'commit))

  (define (bind-status-key! keymap character command)
    (keymap-bind!
      keymap
      (list (make-key-stroke 'character (char->integer character) 0))
      command))

  (define (install-git-results! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'git-status-mode 'result-list-mode #f 'interface
        'git-status-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-status-key! keymap #\g 'buffer-item.refresh)
      (bind-status-key! keymap #\s 'git.stage)
      (bind-status-key! keymap #\u 'git.unstage)
      (bind-status-key! keymap #\d 'git.diff)
      (bind-status-key! keymap #\D 'git.diff-staged)
      (bind-status-key! keymap #\x 'git.discard)
      (bind-status-key! keymap #\c 'git.commit)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'git-status-mode-map keymap))
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'git.stage stage-git-entry "Stage the Git entry at point.")
        (list 'git.unstage unstage-git-entry "Unstage the Git entry at point.")
        (list 'git.diff diff-git-entry "Show the default diff for the Git entry at point.")
        (list 'git.diff-staged diff-staged-git-entry
              "Show the staged diff for the Git entry at point.")
        (list 'git.discard discard-git-entry
              "Discard tracked worktree changes after confirmation.")
        (list 'git.commit commit-git-status
              "Commit staged changes from the Git status Buffer.")))
    (for-each
      (lambda (entry)
        (editor-register-internal-command!
          editor
          (make-internal-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'git.status-output apply-git-status-output
              "Append records to a Git status Buffer.")
        (list 'git.status-exit apply-git-status-exit
              "Finalize a Git status process.")
        (list 'git.status-cancel cancel-git-status
              "Cancel a Git status process.")
        (list 'git.operation-output apply-git-operation-output
              "Collect output from a Git operation.")
        (list 'git.operation-exit apply-git-operation-exit
              "Finalize a Git operation and refresh status.")
        (list 'git.apply-discard apply-git-discard
              "Apply a confirmed Git worktree discard.")
        (list 'git.apply-commit apply-git-commit
              "Start a Git commit with the accepted message.")))
    editor)
)
