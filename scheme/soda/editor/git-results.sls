(library (soda editor git-results)
  (export install-git-results! start-git-status!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor line-stream)
          (soda editor location)
          (soda editor location-results)
          (soda editor managed-process)
          (soda editor project)
          (soda editor state)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (git-status-session %make-git-status-session git-status-session?)
    (fields root locations
            (mutable buffer) (mutable process)
            (mutable pending-output) (mutable stderr-output)
            (mutable rename-record) (mutable closed?)))

  (define active-git-statuses (make-weak-eq-hashtable))

  (define (rename-status? status)
    (and (= (string-length status) 2)
         (or (memv (string-ref status 0) '(#\R #\C))
             (memv (string-ref status 1) '(#\R #\C)))))

  (define (deleted-status? status)
    (and (= (string-length status) 2)
         (or (char=? (string-ref status 0) #\D)
             (char=? (string-ref status 1) #\D))))

  (define (decode-record bytes)
    (guard (condition [else #f]) (utf8->string bytes)))

  (define (status-record-fields value)
    (and value
         (>= (string-length value) 3)
         (char=? (string-ref value 2) #\space)
         (list (substring value 0 2)
               (substring value 3 (string-length value)))))

  (define (status-item root status path)
    (and (not (deleted-status? status))
         (make-location-item
           #f (vfs-resolve-path root path) 0 0 0 path
           (list
             (cons 'file-open-position (make-file-utf16-position 0 0))
             (cons 'git-status status)))))

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
            [(status-record-fields value) =>
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
               root locations #f #f (make-bytevector 0) (make-bytevector 0) #f #f)]
           [process
             (make-managed-process
               "git-status"
               (list "git" "status" "--porcelain=v1" "-z"
                     "--untracked-files=all")
               root session 'git.status-output 'git.status-exit)]
           [old (hashtable-ref active-git-statuses editor #f)]
           [buffer
             (editor-open-result-buffer!
               editor "*Git Status*" "Git status" locations origin-view-id
               'git-status 'git.status-cancel session)])
      (git-status-session-buffer-set! session buffer)
      (git-status-session-process-set! session process)
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

  (define (install-git-results! editor)
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
              "Cancel a Git status process.")))
    editor)
)
