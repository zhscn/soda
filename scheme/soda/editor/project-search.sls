(library (soda editor project-search)
  (export install-project-search!
          start-project-search!
          project-search-json-line->locations)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor editable-projection)
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
          (soda editor resource-resolver)
          (soda editor result-buffer)
          (soda editor state)
          (soda editor workspace-edit)
          (soda json)
          (soda runtime)
          (soda vfs))

  (define-record-type
    (project-search-session %make-project-search-session project-search-session?)
    (fields project
            root
            query
            origin-view-id
            locations
            (mutable buffer)
            (mutable process)
            (mutable pending-output)
            (mutable stderr-output)
            (mutable projections)
            (mutable closed?)))

  (define active-project-searches
    (make-weak-eq-hashtable))

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

  (define (session-current? editor session)
    (and (not (project-search-session-closed? session))
         (eq? (hashtable-ref active-project-searches editor #f) session)))

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
          editor (project-search-session-buffer session) items))))

  (define (apply-project-search-output context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (if (not (and (project-search-session? session)
                    (session-current? editor session)
                    (= (managed-process-event-generation event)
                       (managed-process-generation process))))
          '()
          (cond
            [(= (managed-process-event-flags event) process-stdout)
             (let ([combined
                     (bytevector-append
                       (project-search-session-pending-output session)
                       (managed-process-event-data event))])
               (let-values ([(lines remainder)
                             (split-complete-lines combined)])
                 (project-search-session-pending-output-set! session remainder)
                 (append-output-lines! editor session lines)))
             '()]
            [(= (managed-process-event-flags event) process-stderr)
             (project-search-session-stderr-output-set!
               session
               (bytevector-append
                 (project-search-session-stderr-output session)
                 (managed-process-event-data event)))
             '()]
            [else '()]))))

  (define (search-result-count session)
    (length
      (location-list-items
        (project-search-session-locations session))))

  (define (apply-project-search-exit context)
    (let* ([editor (command-context-editor context)]
           [event (command-context-argument context)]
           [process (and (managed-process-event? event)
                         (managed-process-event-process event))]
           [session (and process (managed-process-owner process))])
      (when (and (project-search-session? session)
                 (session-current? editor session))
        (let ([remainder (project-search-session-pending-output session)])
          (unless (zero? (bytevector-length remainder))
            (append-output-lines! editor session (list remainder))))
        (project-search-session-pending-output-set! session (make-bytevector 0))
        (hashtable-delete! active-project-searches editor)
        (let ([status (managed-process-event-status event)]
              [count (search-result-count session)])
          (editor-set-status-message!
            editor
            (cond
              [(or (= status 0) (= status 1))
               (string-append
                 "Project search: " (number->string count) " matches")]
              [else
               (let ([stderr (project-search-session-stderr-output session)])
                 (if (zero? (bytevector-length stderr))
                     (string-append
                       "Project search failed with status "
                       (number->string status))
                     (single-line
                       (guard (condition [else "Project search failed"])
                         (utf8->string stderr)))))]))))
      '()))

  (define (cancel-project-search context)
    (let* ([editor (command-context-editor context)]
           [session (command-context-argument context)])
      (if (not (project-search-session? session))
          '()
          (let ([process (project-search-session-process session)])
            (project-search-session-closed?-set! session #t)
            (when (eq? (hashtable-ref active-project-searches editor #f) session)
              (hashtable-delete! active-project-searches editor))
            (if (and process (managed-process-running? process))
                (list
                  (make-command-effect
                    'managed-process.signal
                    (make-managed-process-signal-request process 15)))
                '())))))

  (define (start-project-search! context project query)
    (let* ([editor (command-context-editor context)]
           [origin-view-id
             (editor-result-origin-view-id
               editor (command-context-view context))]
           [root (project-primary-root project)]
           [locations (make-location-list 'project-search '())]
           [session
             (%make-project-search-session
               project root query origin-view-id locations
               #f #f (make-bytevector 0) (make-bytevector 0) '() #f)]
           [process
             (make-managed-process
               (string-append "project-search:" query)
               (list "rg" "--json" "--smart-case" "--no-messages"
                     "--" query ".")
               root
               session
               'project.search-output
               'project.search-exit)]
           [old (hashtable-ref active-project-searches editor #f)]
           [buffer
             (editor-open-result-buffer!
               editor
               "*Project Search*"
               'project-search-mode
               (string-append "Project search: " query)
               locations
               origin-view-id
               'project-search
               'project.search-cancel
               session)])
      (project-search-session-buffer-set! session buffer)
      (project-search-session-process-set! session process)
      (buffer-set-local! buffer 'project-search-session session)
      (buffer-clear-local! buffer 'edit-guard)
      (buffer-set-local-setting! buffer 'read-only? #t)
      (buffer-set-result-refresh!
        buffer
        (lambda (refresh-context refresh-buffer)
          (start-project-search! refresh-context project query)))
      (hashtable-set! active-project-searches editor session)
      (editor-set-current-location-list! editor locations)
      (append
        (if (and old
                 (project-search-session-process old)
                 (managed-process-running?
                   (project-search-session-process old)))
            (begin
              (project-search-session-closed?-set! old #t)
              (list
                (make-command-effect
                  'managed-process.signal
                  (make-managed-process-signal-request
                    (project-search-session-process old) 15))))
            '())
        (list (make-command-effect 'managed-process.start process)))))

  (define (buffer-substring buffer start end)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (utf8->string (text-subbytevector text start end)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (item-metadata-ref item key)
    (let ([metadata (location-item-metadata item)])
      (let ([entry (and (list? metadata) (assq key metadata))])
        (and entry (cdr entry)))))

  (define (result-range-for-index buffer index)
    (find
      (lambda (range) (= (caddr range) index))
      (buffer-text-property-ranges buffer 'result-index)))

  (define (search-projection! editor result-buffer item index)
    (let* ([source-buffer
             (editor-buffer-for-resource
               editor (location-item-resource item))]
           [result-range (result-range-for-index result-buffer index)]
           [match-start (item-metadata-ref item 'search-match-start)]
           [match-end (item-metadata-ref item 'search-match-end)]
           [excerpt (or (location-item-excerpt item) "")]
           [excerpt-size (bytevector-length (string->utf8 excerpt))])
      (unless
        (and source-buffer result-range
             (integer? match-start) (exact? match-start)
             (integer? match-end) (exact? match-end)
             (<= 0 match-start match-end excerpt-size))
        (editor-user-error
          'project-search.edit "Search result cannot be projected"))
      (let* ([result-end (- (cadr result-range) 1)]
             [result-start (- result-end excerpt-size)]
             [projection-start (+ result-start match-start)]
             [projection-end (+ result-start match-end)]
             [source-start (location-item-start item)]
             [source-end (location-item-end item)]
             [shown
               (buffer-substring
                 result-buffer projection-start projection-end)]
             [current
               (buffer-substring source-buffer source-start source-end)])
        (unless (string=? shown current)
          (editor-user-error
            'project-search.edit
            "Source changed since the search result was produced"
            (location-item-resource item)))
        (make-editable-projection!
          result-buffer
          (make-workspace-text-edit
            (location-item-resource item)
            (buffer-revision source-buffer)
            source-start source-end shown)
          projection-start projection-end))))

  (define (begin-project-search-edit! editor buffer session)
    (unless
      (and (eq? (buffer-local-ref buffer 'project-search-session #f) session)
           (not (project-search-session-closed? session)))
      (editor-user-error
        'project-search.edit "Search result Buffer is no longer current"))
    (let ([projections
            (let loop ([items
                         (location-list-items
                           (project-search-session-locations session))]
                       [index 0]
                       [result '()])
              (if (null? items)
                  (reverse result)
                  (loop
                    (cdr items)
                    (+ index 1)
                    (cons
                      (search-projection!
                        editor buffer (car items) index)
                      result))))])
      (when (null? projections)
        (editor-user-error 'project-search.edit "Search has no matches"))
      (project-search-session-projections-set! session projections)
      (buffer-install-projection-edit-guard!
        buffer projections 'project-search.edit
        "Only matched text is editable")
      (buffer-set-major-mode! buffer 'project-search-edit-mode)
      (buffer-set-local-setting! buffer 'read-only? #f)
      (let ([view
              (find
                (lambda (candidate) (eq? (view-buffer candidate) buffer))
                (editor-views editor))])
        (when view
          (view-set-caret!
            view
            (car (editable-projection-range buffer (car projections))))))
      (editor-set-status-message!
        editor "Edit matches; C-c C-c applies, C-c C-k discards")
      (editor-invalidate! editor 'chrome)))

  (define (active-search-session context who)
    (let* ([buffer (view-buffer (command-context-view context))]
           [session
             (buffer-local-ref buffer 'project-search-session #f)])
      (unless (project-search-session? session)
        (editor-user-error who "Current Buffer is not a project search"))
      (values buffer session)))

  (define (unique-resources items)
    (reverse
      (fold-left
        (lambda (resources item)
          (let ([resource (location-item-resource item)])
            (if (member resource resources)
                resources
                (cons resource resources))))
        '()
        items)))

  (define (edit-project-search context)
    (let-values ([(buffer session)
                  (active-search-session context 'project-search.edit)])
      (let ([process (project-search-session-process session)])
        (when (and process (managed-process-running? process))
          (editor-user-error
            'project-search.edit "Wait for the search to finish")))
      (let ([resources
              (unique-resources
                (location-list-items
                  (project-search-session-locations session)))])
        (editor-resolve-resources!
          (command-context-editor context)
          resources
          (lambda (editor buffers)
            (when
              (and
                (exists
                  (lambda (candidate) (eq? candidate buffer))
                  (editor-buffers editor))
                (not (project-search-session-closed? session))
                (eq?
                  (buffer-local-ref buffer 'project-search-session #f)
                  session))
              (begin-project-search-edit! editor buffer session)))
          (lambda (editor resource status)
            (when
              (and
                (exists
                  (lambda (candidate) (eq? candidate buffer))
                  (editor-buffers editor))
                (not (project-search-session-closed? session)))
              (editor-set-status-message!
                editor
                (string-append
                  "Cannot edit search results: failed to read " resource))))))))

  (define (restart-project-search context session)
    (start-project-search!
      context
      (project-search-session-project session)
      (project-search-session-query session)))

  (define (accept-project-search-edit context)
    (let-values ([(buffer session)
                  (active-search-session context 'project-search.accept)])
      (let ([projections (project-search-session-projections session)])
        (unless (pair? projections)
          (editor-user-error
            'project-search.accept "Search Buffer has no editable matches"))
        (workspace-text-edits-apply!
          (command-context-editor context)
          (map
            (lambda (projection)
              (let ([edit (editable-projection-source projection)])
                (make-workspace-text-edit
                  (workspace-text-edit-resource edit)
                  (workspace-text-edit-revision edit)
                  (workspace-text-edit-start edit)
                  (workspace-text-edit-end edit)
                  (editable-projection-text buffer projection))))
            projections))
        (editor-set-status-message!
          (command-context-editor context)
          (string-append
            "Updated " (number->string (length projections))
            " search matches"))
        (list
          (make-command-effect
            'command.invoke
            (make-command-message 'buffer-item.quit #f))))))

  (define (discard-project-search-edit context)
    (let-values ([(buffer session)
                  (active-search-session context 'project-search.discard)])
      (restart-project-search context session)))

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
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'project-search-edit-mode 'fundamental-mode #f 'editing
        'project-search-edit-mode-map
        '((track-modified? . #f) (read-only? . #f))))
    (let ([keymap (make-keymap)])
      (bind-search-key! keymap #\e 0 'project-search.edit)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'project-search-mode-map keymap))
    (let ([keymap (make-keymap)]
          [control-c
            (make-key-stroke 'character (char->integer #\c) 4)])
      (keymap-bind!
        keymap
        (list control-c control-c)
        'project-search.accept)
      (keymap-bind!
        keymap
        (list control-c
              (make-key-stroke 'character (char->integer #\k) 4))
        'project-search.discard)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'project-search-edit-mode-map keymap))
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry) (cadr entry) (caddr entry))))
      (list
        (list 'project-search.edit edit-project-search
              "Edit project search matches in the result Buffer.")
        (list 'project-search.accept accept-project-search-edit
              "Apply edited project search matches.")
        (list 'project-search.discard discard-project-search-edit
              "Discard edits and refresh project search results.")))
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
              "Cancel a running Project search.")))
    editor)
)
