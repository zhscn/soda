(library (soda editor project-search)
  (export install-project-search!
          start-project-search!
          project-search-json-line->locations)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor effect)
          (soda editor event)
          (soda editor file)
          (soda editor location)
          (soda editor location-results)
          (soda editor keymap)
          (soda editor language)
          (soda editor line-stream)
          (soda editor managed-process)
          (soda editor project)
          (soda editor prompt)
          (soda editor result-buffer)
          (soda editor result-edit)
          (soda editor result-producer-session)
          (soda editor state)
          (soda json)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (project-search-session %make-project-search-session project-search-session?)
    (parent result-producer-session)
    (fields project root query))

  (define active-project-searches
    (make-result-producer-registry))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (json-text object key)
    (let ([value (and (json-object? object)
                      (json-object-ref object key #f))])
      (and (json-object? value)
           (let ([text (json-object-ref value "text" #f)])
             (and (string? text) text)))))

  (define (utf16-length value)
    (fold-left
      (lambda (length character)
        (+ length
           (if (> (char->integer character) #xffff) 2 1)))
      0
      (string->list value)))

  (define (utf16-column line-text byte-column)
    (let* ([bytes (string->utf8 line-text)]
           [column (min byte-column (bytevector-length bytes))])
      (utf16-length
        (utf8->string (bytevector-slice bytes 0 column)))))

  (define (single-line value)
    (list->string
      (map
        (lambda (character)
          (if (or (char=? character #\newline)
                  (char=? character #\return)
                  (char=? character #\tab))
              #\space
              character))
        (string->list value))))

  (define (match-message->locations root message)
    (if (not (and (json-object? message)
                  (equal? (json-object-ref message "type" #f) "match")))
        '()
        (let* ([data (json-object-ref message "data" #f)]
               [path (json-text data "path")]
               [line-text (or (json-text data "lines") "")]
               [line-number (and (json-object? data)
                                 (json-object-ref data "line_number" #f))]
               [absolute-offset (and (json-object? data)
                                     (json-object-ref data "absolute_offset" 0))]
               [submatches (and (json-object? data)
                                (json-object-ref data "submatches" #f))])
          (if (not (and path
                        (integer? line-number)
                        (exact? line-number)
                        (positive? line-number)
                        (integer? absolute-offset)
                        (exact? absolute-offset)
                        (json-array? submatches)))
              '()
              (let ([resource
                      (vfs-resolve-path
                        root path)]
                    [excerpt (single-line line-text)])
                (filter
                  (lambda (item) item)
                  (map
                    (lambda (submatch)
                      (let ([start (and (json-object? submatch)
                                       (json-object-ref submatch "start" #f))]
                            [end (and (json-object? submatch)
                                     (json-object-ref submatch "end" #f))])
                        (and
                          (integer? start) (exact? start)
                          (integer? end) (exact? end)
                          (<= 0 start end)
                          (make-location-item
                            #f
                            resource
                            0
                            (+ absolute-offset start)
                            (+ absolute-offset end)
                            excerpt
                            (list
                              (cons
                                'file-open-position
                                (make-file-utf16-position
                                  (- line-number 1)
                                  (utf16-column line-text start)))
                              (cons 'search-line-start absolute-offset)
                              (cons 'search-match-start start)
                              (cons 'search-match-end end))))))
                    (json-array-values submatches))))))))

  (define (project-search-json-line->locations root line)
    (unless (and (string? root) (bytevector? line))
      (assertion-violation
        'project-search-json-line->locations
        "expected a root path and JSON bytevector"
        root line))
    (match-message->locations root (json-parse-bytevector line)))

  (define (append-output-lines! editor session lines)
    (let ([items
            (apply append
              (map
                (lambda (line)
                  (if (zero? (bytevector-length line))
                      '()
                      (guard (condition [else '()])
                        (project-search-json-line->locations
                          (project-search-session-root session) line))))
                lines))])
      (when (pair? items)
        (editor-append-location-results!
          editor (result-producer-session-buffer session) items))))

  (define (apply-project-search-output context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (if (not (and (project-search-session? session)
                    (result-producer-registry-current?
                      active-project-searches editor session)
                    (= (managed-process-event-generation event)
                       (managed-process-generation process))))
          '()
          (cond
            [(= (managed-process-event-flags event) process-stdout)
             (let ([combined
                     (bytevector-append
                       (result-producer-session-pending-output session)
                       (managed-process-event-data event))])
               (let-values ([(lines remainder)
                             (split-complete-lines combined)])
                 (result-producer-session-pending-output-set! session remainder)
                 (append-output-lines! editor session lines)))
             '()]
            [(= (managed-process-event-flags event) process-stderr)
             (result-producer-session-error-output-set!
               session
               (bytevector-append
                 (result-producer-session-error-output session)
                 (managed-process-event-data event)))
             '()]
            [else '()]))))

  (define (search-result-count session)
    (length
      (location-list-items
        (result-producer-session-locations session))))

  (define (project-search-error-message session status)
    (let ([stderr (result-producer-session-error-output session)])
      (if (zero? (bytevector-length stderr))
          (string-append
            "Project search failed with status "
            (number->string status))
          (single-line
            (guard (condition [else "Project search failed"])
              (utf8->string stderr))))))

  (define (apply-project-search-exit context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (when (and (project-search-session? session)
                 (result-producer-registry-current?
                   active-project-searches editor session))
        (let ([remainder (result-producer-session-pending-output session)])
          (unless (zero? (bytevector-length remainder))
            (append-output-lines! editor session (list remainder))))
        (result-producer-session-pending-output-set!
          session (make-bytevector 0))
        (result-producer-registry-release!
          active-project-searches editor session)
        (let* ([status (managed-process-event-status event)]
               [count (search-result-count session)]
               [success? (or (= status 0) (= status 1))])
          (editor-finish-result-producer!
            editor
            (result-producer-session-buffer session)
            (if success? 'ready 'failed)
            (if success?
                (and (zero? count) "No matches.")
                (project-search-error-message session status))
            (if success? 'info 'error))
          (editor-set-status-message!
            editor
            (cond
              [success?
               (string-append
                 "Project search: " (number->string count) " matches")]
              [else
               (project-search-error-message session status)]))))
      '()))

  (define (cancel-project-search context)
    (let* ([editor (command-context-editor context)]
           [session (command-context-argument context)])
      (if (not (project-search-session? session))
          '()
          (result-producer-cancel!
            active-project-searches
            editor
            session
            (result-producer-session-process session)
            "Project search cancelled."))))

  (define (project-search-session-live-buffer editor session)
    (let ([buffer (result-producer-session-buffer session)])
      (and
        buffer
        (exists (lambda (candidate) (eq? candidate buffer))
                (editor-buffers editor))
        (eq?
          (buffer-local-ref buffer 'project-search-session #f)
          session)
        buffer)))

  (define (edit-project-search-query context buffer)
    (let* ([editor (command-context-editor context)]
           [session
             (buffer-local-ref buffer 'project-search-session #f)])
      (unless
        (and (project-search-session? session)
             (project-search-session-live-buffer editor session))
        (editor-user-error
          'project-search.edit-query
          "Current search result is no longer live"))
      (editor-open-prompt!
        editor
        (make-prompt-request
          "Search Project regexp: "
          (project-search-session-query session)
          'project-search
          #f
          'free
          non-empty-string?
          'project.search-apply-query
          #f
          session))
      '()))

  (define (apply-project-search-query context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [session
             (and (prompt-result? result) (prompt-result-data result))]
           [query
             (and (prompt-result? result) (prompt-result-value result))])
      (if
        (and
          (project-search-session? session)
          (eq? (prompt-result-status result) 'accepted)
          (non-empty-string? query)
          (project-search-session-live-buffer editor session))
        (start-project-search!
          context (project-search-session-project session) query)
        (begin
          (editor-set-status-message!
            editor "Project search query was not changed")
          '()))))

  (define (start-project-search! context project query)
    (let* ([editor (command-context-editor context)]
           [origin-view-id
             (editor-result-origin-view-id
               editor (command-context-view context))]
           [scope
             (view-workbench-id
               (editor-view-ref editor origin-view-id))]
           [root (project-primary-root project)]
           [locations (make-location-list 'project-search '())]
           [session
             (%make-project-search-session
               origin-view-id scope locations #f #f
               (make-bytevector 0) (make-bytevector 0) #f
               project root query)]
           [process
             (make-managed-process
               (string-append "project-search:" query)
               (list "rg" "--json" "--smart-case" "--no-messages"
                     "--" query ".")
               root
               session
               'project.search-output
               'project.search-exit)]
           [old
             (result-producer-registry-ref
               active-project-searches editor scope)]
           [buffer
             (editor-open-result-buffer!
               editor
               "*Project Search*"
               'project-search-mode
               (string-append
                 "Project search: " query
                 "\nRoot: " root)
               locations
               origin-view-id
               'project-search
               'project.search-cancel
               session)])
      (result-producer-session-buffer-set! session buffer)
      (result-producer-session-process-set! session process)
      (buffer-set-result-producer-state! buffer 'running)
      (buffer-set-local! buffer 'project-search-session session)
      (buffer-set-local!
        buffer
        'result-edit-ready?
        (lambda ()
          (cond
            [(result-producer-session-closed? session)
             "Search result Buffer is no longer current"]
            [(and (result-producer-session-process session)
                  (managed-process-running?
                    (result-producer-session-process session)))
             "Wait for the search to finish"]
            [else #t])))
      (buffer-clear-local! buffer 'edit-guard)
      (buffer-set-local-setting! buffer 'read-only? #t)
      (buffer-set-result-refresh!
        buffer
        (lambda (refresh-context refresh-buffer)
          (start-project-search! refresh-context project query)))
      (buffer-register-result-panel-action!
        buffer
        (make-result-panel-action
          'edit-query
          "Edit search query"
          (lambda (candidate)
            (not
              (or
                (buffer-local-ref candidate 'result-edit-active? #f)
                (buffer-local-ref candidate 'result-edit-pending #f))))
          edit-project-search-query))
      (buffer-enable-result-edit-action! buffer "Edit matches")
      (result-producer-registry-activate!
        active-project-searches editor session)
      (editor-set-current-location-list! editor locations)
      (append
        (if (and old
                 (result-producer-session-process old)
                 (managed-process-running?
                   (result-producer-session-process old)))
            (result-producer-retire!
              old (result-producer-session-process old))
            '())
        (list (make-command-effect 'managed-process.start process)))))

  (define (bind-search-key! keymap character modifiers command)
    (keymap-bind!
      keymap
      (list
        (make-key-stroke
          'character (char->integer character) modifiers))
      command))

  (define (install-project-search! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'project-search-mode 'location-results-mode #f 'interface
        'project-search-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (bind-search-key! keymap #\e 0 'result-edit.begin)
      (bind-search-key! keymap #\r 0 'project-search.edit-query)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'project-search-mode-map keymap))
    (for-each
      (lambda (entry)
        (editor-register-internal-command!
          editor
          (make-internal-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'project.search-output
              apply-project-search-output
              "Append structured Project search output.")
        (list 'project.search-exit
              apply-project-search-exit
              "Finalize a Project search process.")
        (list 'project.search-cancel
              cancel-project-search
              "Cancel a running Project search.")
        (list 'project.search-apply-query
              apply-project-search-query
              "Restart Project search with the edited query.")))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'project-search.edit-query
        (lambda (context)
          (invoke-result-panel-action context 'edit-query))
        "Edit and restart the current Project search query."))
    editor)
)
