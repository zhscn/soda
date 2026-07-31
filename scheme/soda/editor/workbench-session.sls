(library (soda editor workbench-session)
  (export default-workbench-session-path
          workbench-session-encode
          workbench-session-decode
          workbench-session-resources
          editor-restore-workbench-session!
          load-workbench-session-file
          ensure-workbench-session-directory!)
  (import (rnrs)
          (only (chezscheme)
                file-directory?
                getenv
                mkdir
                path-parent)
          (soda document)
          (soda editor buffer)
          (soda editor location)
          (soda editor project)
          (soda editor resource-context)
          (soda editor state)
          (soda editor window)
          (soda editor workbench))

  (define schema-name 'soda-workbench-session)
  (define schema-version 1)

  (define-record-type
    (workbench-session-snapshot
      %make-workbench-session-snapshot
      workbench-session-snapshot?)
    (fields active-index workbenches))

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (stable-resource? value)
    (and
      (non-empty-string? value)
      (not (char=? (string-ref value 0) #\*))))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (default-workbench-session-path)
    (let ([override (getenv "SODA_WORKBENCH_SESSION_FILE")])
      (if override
          (and (non-empty-string? override) override)
          (let ([xdg-state-home (getenv "XDG_STATE_HOME")]
                [home (getenv "HOME")])
            (cond
              [(non-empty-string? xdg-state-home)
               (string-append xdg-state-home "/soda/workbenches.ss")]
              [(non-empty-string? home)
               (string-append
                 home
                 "/.local/state/soda/workbenches.ss")]
              [else #f])))))

  (define (buffer-resource-for-session buffer)
    (let ([resource
            (or (buffer-file-path buffer) (buffer-resource buffer))])
      (and (stable-resource? resource) resource)))

  (define (location-datum location)
    (let ([resource (editor-location-resource location)])
      (and
        (stable-resource? resource)
        (list resource (editor-location-offset location)))))

  (define (location-item-datum item)
    (let ([resource (location-item-resource item)])
      (and
        (stable-resource? resource)
        (list resource (location-item-start item)))))

  (define (jump-datum jump)
    (let ([source (location-item-datum (jump-history-entry-source jump))]
          [target (location-item-datum (jump-history-entry-target jump))])
      (and
        source
        target
        (list (jump-history-entry-kind jump) source target))))

  (define (navigation-datum view)
    (let* ([walk (view-navigation-walk view)]
           [entries
             (filter
               (lambda (value) value)
               (map location-datum
                    (navigation-walk-entries walk)))]
           [jumps
             (filter
               (lambda (value) value)
               (map jump-datum (navigation-walk-jumps walk)))]
           [cursor (navigation-walk-cursor walk)])
      (list
        entries
        (and
          cursor
          (pair? entries)
          (min cursor (- (length entries) 1)))
        jumps)))

  (define (view-datum editor view)
    (let* ([context
             (editor-view-resource-context editor (view-id view))]
           [project (resource-context-project-hint context)])
      (list
        (buffer-resource-for-session (view-buffer view))
        (view-caret view)
        (view-mark view)
        (view-mark-active? view)
        (view-first-line view)
        (view-first-visual-row view)
        (view-first-column view)
        (resource-context-base-resource context)
        (and project (project-primary-root project))
        (navigation-datum view))))

  (define (layout-datum editor workbench node)
    (if (window-leaf? node)
        (list
          'leaf
          (workbench-window-role workbench (window-leaf-id node))
          (workbench-window-pinned?
            workbench
            (window-leaf-id node))
          (view-datum
            editor
            (editor-view-ref editor (window-leaf-view-id node))))
        (list
          'split
          (window-split-orientation node)
          (map
            (lambda (child)
              (layout-datum editor workbench child))
            (window-split-children node)))))

  (define (project-root-for-id editor id)
    (let ([project
            (project-catalog-find-known
              (editor-project-catalog editor)
              id)])
      (and project (project-primary-root project))))

  (define (buffer-resource-for-id editor id)
    (guard (condition [else #f])
      (buffer-resource-for-session (editor-buffer-ref editor id))))

  (define (workbench-datum editor workbench)
    (let* ([leaves (window-node-leaves (workbench-layout workbench))]
           [active-index
             (let loop ([remaining leaves] [index 0])
               (cond
                 [(null? remaining) 0]
                 [(= (window-leaf-id (car remaining))
                     (workbench-active-window-id workbench))
                  index]
                 [else (loop (cdr remaining) (+ index 1))]))])
      (list
        (workbench-name workbench)
        (filter
          (lambda (value) value)
          (map
            (lambda (id) (project-root-for-id editor id))
            (workbench-scope workbench)))
        (filter
          (lambda (value) value)
          (map
            (lambda (id) (buffer-resource-for-id editor id))
            (workbench-mru workbench)))
        active-index
        (layout-datum editor workbench (workbench-layout workbench)))))

  (define (active-workbench-index editor workbenches)
    (let ([active (editor-active-workbench editor)])
      (let loop ([remaining workbenches] [index 0])
        (cond
          [(null? remaining) 0]
          [(eq? (car remaining) active) index]
          [else (loop (cdr remaining) (+ index 1))]))))

  (define (workbench-session-encode editor)
    (let* ([workbenches (editor-workbenches editor)]
           [datum
             (list
               schema-name
               schema-version
               (active-workbench-index editor workbenches)
               (map
                 (lambda (workbench)
                   (workbench-datum editor workbench))
                 workbenches))])
      (let-values ([(port extract) (open-string-output-port)])
        (write datum port)
        (newline port)
        (string->utf8 (extract)))))

  (define (valid-location-datum? value)
    (and
      (list? value)
      (= (length value) 2)
      (stable-resource? (car value))
      (exact-non-negative-integer? (cadr value))))

  (define (valid-navigation-datum? value)
    (and
      (list? value)
      (= (length value) 3)
      (let ([entries (car value)]
            [cursor (cadr value)]
            [jumps (caddr value)])
        (and
          (list? entries)
          (for-all valid-location-datum? entries)
          (or
            (not cursor)
            (and
              (exact-non-negative-integer? cursor)
              (< cursor (length entries))))
          (list? jumps)
          (for-all
            (lambda (jump)
              (and
                (list? jump)
                (= (length jump) 3)
                (symbol? (car jump))
                (valid-location-datum? (cadr jump))
                (valid-location-datum? (caddr jump))))
            jumps)))))

  (define (valid-view-datum? value)
    (and
      (list? value)
      (= (length value) 10)
      (or (not (list-ref value 0))
          (stable-resource? (list-ref value 0)))
      (exact-non-negative-integer? (list-ref value 1))
      (or (not (list-ref value 2))
          (exact-non-negative-integer? (list-ref value 2)))
      (boolean? (list-ref value 3))
      (exact-non-negative-integer? (list-ref value 4))
      (exact-non-negative-integer? (list-ref value 5))
      (exact-non-negative-integer? (list-ref value 6))
      (non-empty-string? (list-ref value 7))
      (or (not (list-ref value 8))
          (stable-resource? (list-ref value 8)))
      (valid-navigation-datum? (list-ref value 9))))

  (define (valid-layout-datum? value)
    (and
      (list? value)
      (pair? value)
      (case (car value)
        [(leaf)
         (and
           (= (length value) 4)
           (or (not (cadr value)) (symbol? (cadr value)))
           (boolean? (caddr value))
           (valid-view-datum? (cadddr value)))]
        [(split)
         (and
           (= (length value) 3)
           (memq (cadr value) '(horizontal vertical))
           (list? (caddr value))
           (>= (length (caddr value)) 2)
           (for-all valid-layout-datum? (caddr value)))]
        [else #f])))

  (define (valid-workbench-datum? value)
    (and
      (list? value)
      (= (length value) 5)
      (non-empty-string? (list-ref value 0))
      (list? (list-ref value 1))
      (for-all stable-resource? (list-ref value 1))
      (list? (list-ref value 2))
      (for-all stable-resource? (list-ref value 2))
      (exact-non-negative-integer? (list-ref value 3))
      (valid-layout-datum? (list-ref value 4))))

  (define (workbench-session-decode bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'workbench-session-decode
        "expected a bytevector"
        bytes))
    (guard
      (condition
        [else
         (assertion-violation
           'workbench-session-decode
           "invalid Workbench session state"
           condition)])
      (let* ([port (open-string-input-port (utf8->string bytes))]
             [datum (read port)]
             [trailing (read port)])
        (unless
          (and
            (eof-object? trailing)
            (list? datum)
            (= (length datum) 4)
            (eq? (car datum) schema-name)
            (= (cadr datum) schema-version)
            (exact-non-negative-integer? (caddr datum))
            (list? (cadddr datum))
            (pair? (cadddr datum))
            (< (caddr datum) (length (cadddr datum)))
            (for-all valid-workbench-datum? (cadddr datum)))
          (assertion-violation
            'workbench-session-decode
            "unsupported or malformed Workbench session state"))
        (%make-workbench-session-snapshot
          (caddr datum)
          (cadddr datum)))))

  (define (collect-layout-resources layout result)
    (case (car layout)
      [(leaf)
       (let* ([view (cadddr layout)]
              [resource (list-ref view 0)]
              [navigation (list-ref view 9)]
              [locations
                (append
                  (car navigation)
                  (apply
                    append
                    (map
                      (lambda (jump) (list (cadr jump) (caddr jump)))
                      (caddr navigation))))])
         (fold-left
           (lambda (resources location)
             (cons (car location) resources))
           (if resource (cons resource result) result)
           locations))]
      [(split)
       (fold-left
         (lambda (resources child)
           (collect-layout-resources child resources))
         result
         (caddr layout))]))

  (define (unique-strings values)
    (fold-left
      (lambda (result value)
        (if (member value result) result (cons value result)))
      '()
      values))

  (define (workbench-session-resources snapshot)
    (unless (workbench-session-snapshot? snapshot)
      (assertion-violation
        'workbench-session-resources
        "expected a Workbench session snapshot"
        snapshot))
    (reverse
      (unique-strings
        (fold-left
          (lambda (result workbench)
            (append
              (list-ref workbench 2)
              (collect-layout-resources
                (list-ref workbench 4)
                result)))
          '()
          (workbench-session-snapshot-workbenches snapshot)))))

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

  (define (resolve-project! editor root)
    (or
      (find
        (lambda (project)
          (string=? (project-primary-root project) root))
        (editor-known-projects editor))
      (let ([project (editor-discover-project editor root)])
        (if project
            (begin (editor-remember-project! editor project) project)
            (let ([fallback
                    (make-project
                      (string-append "session:" root)
                      (list root)
                      'session
                      'restored
                      #f
                      #f
                      '())])
              (editor-remember-project! editor fallback)
              fallback)))))

  (define (project-for-root projects root)
    (and
      root
      (find
        (lambda (project)
          (string=? (project-primary-root project) root))
        projects)))

  (define (restore-location buffer-loader datum)
    (let ([buffer (buffer-loader (car datum))])
      (and
        buffer
        (make-buffer-location
          buffer
          (min (cadr datum) (buffer-size buffer))))))

  (define (restore-location-item buffer-loader datum role kind)
    (let ([buffer (buffer-loader (car datum))]
          [location #f])
      (and
        buffer
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (set! location
              (make-buffer-location
                buffer
                (min (cadr datum) (buffer-size buffer))))
            (editor-location->item location role kind))
          (lambda ()
            (when location (editor-location-close! location)))))))

  (define (restore-navigation! view datum buffer-loader)
    (let* ([walk (view-navigation-walk view)]
           [entries
             (filter
               (lambda (value) value)
               (map
                 (lambda (location)
                   (restore-location buffer-loader location))
                 (car datum)))]
           [jumps
             (filter
               (lambda (value) value)
               (map
                 (lambda (jump)
                   (let* ([kind (car jump)]
                          [source
                            (restore-location-item
                              buffer-loader (cadr jump) 'source kind)]
                          [target
                            (restore-location-item
                              buffer-loader (caddr jump) 'target kind)])
                     (and source target
                          (make-jump-history-entry
                            kind source target))))
                 (caddr datum)))]
           [cursor (cadr datum)])
      (navigation-walk-replace-entries! walk entries)
      (navigation-walk-replace-jumps! walk jumps)
      (navigation-walk-cursor-set!
        walk
        (and cursor
             (pair? entries)
             (min cursor (- (length entries) 1))))))

  (define (restore-view!
            editor datum buffer-loader fallback-buffer projects)
    (let* ([resource (list-ref datum 0)]
           [buffer (or (and resource (buffer-loader resource)) fallback-buffer)]
           [context
             (make-resource-context
               (list-ref datum 7)
               #f
               (project-for-root projects (list-ref datum 8))
               #f)]
           [view
             (editor-open-view!
               editor
               (buffer-id buffer)
               context)]
           [end (buffer-size buffer)]
           [point (min (list-ref datum 1) end)]
           [mark
             (and
               (list-ref datum 2)
               (min (list-ref datum 2) end))])
      (view-set-caret! view point)
      (when mark
        (view-set-mark! view mark)
        (unless (list-ref datum 3)
          (view-deactivate-mark! view)))
      (view-set-first-line! view (list-ref datum 4))
      (view-set-first-visual-row! view (list-ref datum 5))
      (view-set-first-column! view (list-ref datum 6))
      (restore-navigation! view (list-ref datum 9) buffer-loader)
      view))

  (define (restore-layout!
            editor datum buffer-loader fallback-buffer projects metadata)
    (case (car datum)
      [(leaf)
       (let* ([view
                (restore-view!
                  editor
                  (cadddr datum)
                  buffer-loader
                  fallback-buffer
                  projects)]
              [leaf
                (make-window-leaf
                  (editor-allocate-window-id! editor)
                  (view-id view))])
         (vector-set!
           metadata
           0
           (append (vector-ref metadata 0) (list leaf)))
         (when (cadr datum)
           (vector-set!
             metadata
             1
             (cons
               (cons (cadr datum) (window-leaf-id leaf))
               (vector-ref metadata 1))))
         (when (caddr datum)
           (vector-set!
             metadata
             2
             (cons
               (window-leaf-id leaf)
               (vector-ref metadata 2))))
         leaf)]
      [(split)
       (make-window-split
         (editor-allocate-window-id! editor)
         (cadr datum)
         (map
           (lambda (child)
             (restore-layout!
               editor child buffer-loader fallback-buffer projects metadata))
           (caddr datum)))]))

  (define (restore-workbench!
            editor workbench datum buffer-loader fallback-buffer)
    (let* ([projects
             (map
               (lambda (root) (resolve-project! editor root))
               (list-ref datum 1))]
           [metadata (vector '() '() '())]
           [old-view-ids
             (map
               window-leaf-view-id
               (window-node-leaves (workbench-layout workbench)))]
           [layout
             (restore-layout!
               editor
               (list-ref datum 4)
               buffer-loader
               fallback-buffer
               projects
               metadata)]
           [leaves (vector-ref metadata 0)]
           [active-index
             (min
               (list-ref datum 3)
               (- (length leaves) 1))]
           [active-window-id
             (window-leaf-id (list-ref leaves active-index))])
      (workbench-set-name! workbench (list-ref datum 0))
      (for-each
        (lambda (project-id)
          (workbench-remove-project! workbench project-id))
        (workbench-scope workbench))
      (if (eq? workbench (editor-active-workbench editor))
          (begin
            (editor-set-window-root! editor layout)
            (editor-set-active-window-id! editor active-window-id)
            (editor-set-active-view!
              editor
              (window-leaf-view-id
                (window-node-find layout active-window-id))))
          (begin
            (workbench-set-layout! workbench layout)
            (workbench-set-active-window-id! workbench active-window-id)))
      (for-each
        (lambda (project)
          (workbench-adopt-project!
            workbench
            (project-id project)))
        projects)
      (for-each
        (lambda (entry)
          (workbench-set-slot! workbench (car entry) (cdr entry)))
        (vector-ref metadata 1))
      (for-each
        (lambda (window-id)
          (workbench-pin-window! workbench window-id))
        (vector-ref metadata 2))
      (workbench-replace-mru!
        workbench
        (filter
          (lambda (value) value)
          (map
            (lambda (resource)
              (let ([buffer (buffer-loader resource)])
                (and buffer (buffer-id buffer))))
            (list-ref datum 2))))
      (for-each
        (lambda (view-id) (editor-close-view! editor view-id))
        old-view-ids)
      workbench))

  (define (editor-restore-workbench-session!
            editor snapshot buffer-loader)
    (unless (workbench-session-snapshot? snapshot)
      (assertion-violation
        'editor-restore-workbench-session!
        "expected a Workbench session snapshot"
        snapshot))
    (unless (procedure? buffer-loader)
      (assertion-violation
        'editor-restore-workbench-session!
        "buffer loader must be a procedure"
        buffer-loader))
    (when (editor-active-prompt editor)
      (assertion-violation
        'editor-restore-workbench-session!
        "cannot restore while the minibuffer is active"))
    (let* ([states (workbench-session-snapshot-workbenches snapshot)]
           [existing (editor-workbenches editor)]
           [fallback-buffer (view-buffer (editor-active-view editor))]
           [targets
             (cons
               (car existing)
               (map
                 (lambda (state)
                   (editor-create-workbench!
                     editor
                     (car state)
                     '()))
                 (cdr states)))])
      (for-each
        (lambda (workbench state)
          (restore-workbench!
            editor workbench state buffer-loader fallback-buffer))
        targets
        states)
      (editor-switch-workbench!
        editor
        (workbench-id
          (list-ref
            targets
            (workbench-session-snapshot-active-index snapshot))))
      targets))

  (define (load-workbench-session-file path)
    (and
      path
      (file-exists? path)
      (guard (condition [else #f])
        (call-with-port
          (open-file-input-port path)
          (lambda (port)
            (workbench-session-decode
              (get-bytevector-all port)))))))

  (define (ensure-directory! directory)
    (unless
      (or
        (string=? directory "")
        (string=? directory ".")
        (string=? directory "/")
        (file-directory? directory))
      (let ([parent (path-parent directory)])
        (unless (string=? parent directory)
          (ensure-directory! parent)))
      (mkdir directory)))

  (define (ensure-workbench-session-directory! path)
    (unless (non-empty-string? path)
      (assertion-violation
        'ensure-workbench-session-directory!
        "path must be non-empty"
        path))
    (ensure-directory! (path-parent path))
    path)
)
