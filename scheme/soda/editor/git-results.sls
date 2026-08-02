(library (soda editor git-results)
  (export install-git-results! start-git-status! git-status-record-fields)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
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
          (soda editor project)
          (soda editor result-buffer)
          (soda editor state)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (git-status-session %make-git-status-session git-status-session?)
    (fields project root origin-view-id locations
            (mutable buffer) (mutable process)
            (mutable pending-output) (mutable stderr-output)
            (mutable rename-record) (mutable closed?)))

  (define active-git-statuses (make-weak-eq-hashtable))

  (define-record-type git-operation
    (fields status-session label (mutable stderr-output)))

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
        editor (git-status-session-buffer session) line
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

  (define (session-current? editor session)
    (and (not (git-status-session-closed? session))
         (eq? (hashtable-ref active-git-statuses editor #f) session)))

  (define (apply-git-status-output context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (when (and (git-status-session? session)
                 (session-current? editor session)
                 (= (managed-process-event-generation event)
                    (managed-process-generation process)))
        (cond
          [(= (managed-process-event-flags event) process-stdout)
           (let ([combined
                   (bytevector-append
                     (git-status-session-pending-output session)
                     (managed-process-event-data event))])
             (let-values ([(records remainder)
                           (split-complete-records combined 0)])
               (git-status-session-pending-output-set! session remainder)
               (consume-records! editor session records)))]
          [(= (managed-process-event-flags event) process-stderr)
           (git-status-session-stderr-output-set!
             session
             (bytevector-append
               (git-status-session-stderr-output session)
               (managed-process-event-data event)))]))
      '()))

  (define (apply-git-status-exit context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (when (and (git-status-session? session)
                 (session-current? editor session))
        (let ([remainder (git-status-session-pending-output session)])
          (unless (zero? (bytevector-length remainder))
            (consume-records! editor session (list remainder))))
        (when (git-status-session-rename-record session)
          (let ([pending (git-status-session-rename-record session)])
            (append-status! editor session (car pending) (cadr pending) #f)
            (git-status-session-rename-record-set! session #f)))
        (hashtable-delete! active-git-statuses editor)
        (let ([status (managed-process-event-status event)])
          (buffer-set-result-producer-state!
            (git-status-session-buffer session)
            (if (zero? status) 'ready 'failed))
          (when (and (not (zero? status))
                     (positive?
                       (bytevector-length
                         (git-status-session-stderr-output session))))
            (editor-append-result-text!
              editor
              (git-status-session-buffer session)
              (guard (condition [else "Git status produced invalid UTF-8\n"])
                (utf8->string (git-status-session-stderr-output session)))
              '()))
          (editor-set-status-message!
            editor
            (if (zero? status)
                (string-append
                  "Git status: "
                  (number->string
                    (length (location-list-items
                              (git-status-session-locations session))))
                  " files")
                (string-append
                  "Git status failed with status " (number->string status))))))
      '()))

  (define (cancel-git-status context)
    (let* ([editor (command-context-editor context)]
           [session (command-context-argument context)])
      (if (not (git-status-session? session))
          '()
          (let ([process (git-status-session-process session)])
            (git-status-session-closed?-set! session #t)
            (when (git-status-session-buffer session)
              (buffer-set-result-producer-state!
                (git-status-session-buffer session) 'cancelled))
            (when (eq? (hashtable-ref active-git-statuses editor #f) session)
              (hashtable-delete! active-git-statuses editor))
            (if (and process (managed-process-running? process))
                (list
                  (make-command-effect
                    'managed-process.signal
                    (make-managed-process-signal-request process 15)))
                '())))))

  (define (start-git-status! context project)
    (let* ([editor (command-context-editor context)]
           [origin-view-id
             (editor-result-origin-view-id editor (command-context-view context))]
           [root (project-primary-root project)]
           [locations (make-location-list 'git-status '())]
           [session
             (%make-git-status-session
               project root origin-view-id locations #f #f
               (make-bytevector 0) (make-bytevector 0) #f #f)]
           [process
             (make-managed-process
               "git-status"
               (list "git" "status" "--porcelain=v1" "-z"
                     "--untracked-files=all")
               root session 'git.status-output 'git.status-exit)]
           [old (hashtable-ref active-git-statuses editor #f)]
           [buffer
             (editor-open-result-buffer!
               editor "*Git Status*" 'git-status-mode
               "Git status" locations origin-view-id
               'git-status 'git.status-cancel session)])
      (git-status-session-buffer-set! session buffer)
      (git-status-session-process-set! session process)
      (buffer-set-result-producer-state! buffer 'running)
      (buffer-set-local! buffer 'git-status-session session)
      (register-git-status-actions! buffer session)
      (buffer-set-result-refresh!
        buffer
        (lambda (refresh-context refresh-buffer)
          (start-git-status! refresh-context project)))
      (hashtable-set! active-git-statuses editor session)
      (editor-set-current-location-list! editor locations)
      (append
        (if (and old (git-status-session-process old)
                 (managed-process-running? (git-status-session-process old)))
            (begin
              (git-status-session-closed?-set! old #t)
              (list
                (make-command-effect
                  'managed-process.signal
                  (make-managed-process-signal-request
                    (git-status-session-process old) 15))))
            '())
        (list (make-command-effect 'managed-process.start process)))))

  (define (item-status item)
    (let ([entry
            (and (list? (location-item-metadata item))
                 (assq 'git-status (location-item-metadata item)))])
      (and entry (cdr entry))))

  (define (status-result-view editor session)
    (find
      (lambda (view)
        (eq? (view-buffer view) (git-status-session-buffer session)))
      (editor-views editor)))

  (define (apply-git-operation-output context)
    (let* ([event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [operation (and process (managed-process-owner process))])
      (when (and (git-operation? operation)
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
            (if (zero? status)
                (begin
                  (editor-set-status-message!
                    editor (string-append (git-operation-label operation) " succeeded"))
                  (if view
                      (start-git-status!
                        (make-command-context editor view #f #f #f)
                        (git-status-session-project session))
                      '()))
                (begin
                  (editor-set-status-message!
                    editor
                    (let ([stderr (git-operation-stderr-output operation)])
                      (if (zero? (bytevector-length stderr))
                          (string-append
                            (git-operation-label operation) " failed with status "
                            (number->string status))
                          (guard (condition [else "Git operation failed"])
                            (utf8->string stderr)))))
                  '()))))))

  (define (start-git-operation session label arguments)
    (let* ([operation
             (make-git-operation session label (make-bytevector 0))]
           [process
             (make-managed-process
               label arguments (git-status-session-root session) operation
               'git.operation-output 'git.operation-exit)])
      (list (make-command-effect 'managed-process.start process))))

  (define (git-status-item? buffer item)
    (and (location-item? item) (item-status item)))

  (define (register-git-status-actions! buffer session)
    (for-each
      (lambda (action)
        (buffer-register-result-action! buffer action))
      (list
        (make-result-action
          'stage "Stage"
          git-status-item?
          (lambda (context buffer item index)
            (start-git-operation
              session "Git stage"
              (list "git" "add" "--" (location-item-excerpt item)))))
        (make-result-action
          'unstage "Unstage"
          git-status-item?
          (lambda (context buffer item index)
            (start-git-operation
              session "Git unstage"
              (list "git" "reset" "--" (location-item-excerpt item)))))
        (make-result-action
          'diff "Show diff"
          git-status-item?
          (lambda (context buffer item index)
            (let* ([status (item-status item)]
                   [cached?
                     (and status
                          (not (char=? (string-ref status 0) #\space))
                          (char=? (string-ref status 1) #\space))]
                   [arguments
                     (append
                       (list "git" "diff" "--no-ext-diff")
                       (if cached? (list "--cached") '())
                       (list "--" (location-item-excerpt item)))])
              (start-compilation!
                context
                (string-append
                  "Git diff: " (location-item-excerpt item))
                arguments
                (git-status-session-root session)))))))
    buffer)

  (define (stage-git-entry context)
    (invoke-buffer-item-action context 'stage))

  (define (unstage-git-entry context)
    (invoke-buffer-item-action context 'unstage))

  (define (diff-git-entry context)
    (invoke-buffer-item-action context 'diff))

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
        (list 'git.diff diff-git-entry "Show the diff for the Git entry at point.")))
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
              "Finalize a Git operation and refresh status.")))
    editor)
)
