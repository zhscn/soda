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
          (soda editor jump-graph)
          (soda editor location)
          (soda editor project)
          (soda editor resource-context)
          (soda editor state)
          (soda editor tui-application)
          (soda editor tui-application-runtime)
          (soda editor window)
          (soda editor workbench))

  (define schema-name 'soda-workbench-session)
  (define schema-version 4)

  (define-record-type
    (workbench-session-snapshot
      %make-workbench-session-snapshot
      workbench-session-snapshot?)
    (fields active-index workbenches applications))

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

  (define (durable-location-item-datum item)
    (let ([resource (location-item-resource item)])
      (and
        (stable-resource? resource)
        (list
          resource
          (location-item-revision item)
          (location-item-start item)
          (location-item-end item)
          (location-item-excerpt item)))))

  (define (location-list-datum locations)
    (let ([items
            (filter
              (lambda (value) value)
              (map
                durable-location-item-datum
                (location-list-items locations)))])
      (list
        (location-list-source locations)
        (and
          (location-list-index locations)
          (pair? items)
          (min
            (location-list-index locations)
            (- (length items) 1)))
        items)))

  (define (jump-graph-datum graph)
    (list
      (map
        (lambda (node)
          (list
            (jump-node-id node)
            (jump-node-resource node)
            (jump-node-revision node)
            (jump-node-start node)
            (jump-node-end node)
            (jump-node-excerpt node)
            (jump-node-last-visit node)))
        (filter
          (lambda (node) (stable-resource? (jump-node-resource node)))
          (jump-graph-nodes graph)))
      (map
        (lambda (edge)
          (list
            (jump-edge-from edge)
            (jump-edge-to edge)
            (jump-edge-kind edge)
            (jump-edge-timestamp edge)))
        (jump-graph-edges graph))))

  (define (application-reference editor buffer application-indices)
    (let ([session
            (editor-tui-session-for-buffer editor (buffer-id buffer))])
      (and session
           (let ([entry (assv (tui-session-id session) application-indices)])
             (and entry (list 'application (cdr entry)))))))

  (define (buffer-reference editor buffer application-indices)
    (or (application-reference editor buffer application-indices)
        (buffer-resource-for-session buffer)))

  (define (view-datum editor view application-indices)
    (let* ([context
             (editor-view-resource-context editor (view-id view))]
           [project (resource-context-project-hint context)])
      (list
        (buffer-reference editor (view-buffer view) application-indices)
        (view-caret view)
        (view-mark view)
        (view-mark-active? view)
        (view-first-line view)
        (view-first-visual-row view)
        (view-first-column view)
        (resource-context-base-resource context)
        (and project (project-primary-root project))
        (navigation-datum view))))

  (define (layout-datum editor workbench node application-indices)
    (if (window-leaf? node)
        (list
          'leaf
          (workbench-window-role workbench (window-leaf-id node))
          (workbench-window-pinned?
            workbench
            (window-leaf-id node))
          (view-datum
            editor
            (editor-view-ref editor (window-leaf-view-id node))
            application-indices))
        (list
          'split
          (window-split-orientation node)
          (map
            (lambda (child)
              (layout-datum editor workbench child application-indices))
            (window-split-children node)))))

  (define (project-root-for-id editor id)
    (let ([project
            (project-catalog-find-known
              (editor-project-catalog editor)
              id)])
      (and project (project-primary-root project))))

  (define (buffer-reference-for-id editor id application-indices)
    (guard (condition [else #f])
      (buffer-reference
        editor (editor-buffer-ref editor id) application-indices)))

  (define (workbench-datum editor workbench application-indices)
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
        (and
          (workbench-focused-project-id workbench)
          (project-root-for-id
            editor
            (workbench-focused-project-id workbench)))
        (filter
          (lambda (value) value)
          (map
            (lambda (id)
              (buffer-reference-for-id editor id application-indices))
            (workbench-mru workbench)))
        active-index
        (layout-datum
          editor workbench (workbench-layout workbench) application-indices)
        (jump-graph-datum (workbench-jump-graph workbench))
        (map location-list-datum (workbench-location-lists workbench)))))

  (define (active-workbench-index editor workbenches)
    (let ([active (editor-active-workbench editor)])
      (let loop ([remaining workbenches] [index 0])
        (cond
          [(null? remaining) 0]
          [(eq? (car remaining) active) index]
          [else (loop (cdr remaining) (+ index 1))]))))

  (define (workbench-session-encode editor)
    (let* ([workbenches (editor-workbenches editor)]
           [sessions (editor-tui-sessions editor)]
           [application-indices
             (let loop ([remaining sessions] [index 0] [result '()])
               (if (null? remaining)
                   (reverse result)
                   (loop
                     (cdr remaining)
                     (+ index 1)
                     (cons
                       (cons (tui-session-id (car remaining)) index)
                       result))))]
           [applications
             (map
               (lambda (session)
                 (let ([snapshot
                         (tui-snapshot-session editor (tui-session-id session))])
                   (list
                     (tui-session-snapshot-application-name snapshot)
                     (tui-session-snapshot-buffer-resource snapshot)
                     (tui-session-snapshot-display-intent snapshot)
                     (tui-session-snapshot-arguments snapshot)
                     (tui-session-snapshot-serialized-model? snapshot)
                     (tui-session-snapshot-model snapshot)
                     (tui-session-snapshot-view-states snapshot))))
               sessions)]
           [datum
             (list
               schema-name
               schema-version
               (active-workbench-index editor workbenches)
               (map
                 (lambda (workbench)
                   (workbench-datum editor workbench application-indices))
                 workbenches)
               applications)])
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

  (define (valid-durable-location-item-datum? value)
    (and
      (list? value)
      (= (length value) 5)
      (stable-resource? (list-ref value 0))
      (exact-non-negative-integer? (list-ref value 1))
      (exact-non-negative-integer? (list-ref value 2))
      (exact-non-negative-integer? (list-ref value 3))
      (<= (list-ref value 2) (list-ref value 3))
      (or (not (list-ref value 4)) (string? (list-ref value 4)))))

  (define (valid-location-list-datum? value)
    (and
      (list? value)
      (= (length value) 3)
      (symbol? (list-ref value 0))
      (list? (list-ref value 2))
      (for-all
        valid-durable-location-item-datum?
        (list-ref value 2))
      (or
        (not (list-ref value 1))
        (and
          (exact-non-negative-integer? (list-ref value 1))
          (< (list-ref value 1) (length (list-ref value 2)))))))

  (define (valid-jump-graph-datum? value)
    (and
      (list? value)
      (= (length value) 2)
      (let ([nodes (car value)] [edges (cadr value)])
        (and
          (list? nodes)
          (for-all
            (lambda (node)
              (and
                (list? node)
                (= (length node) 7)
                (exact-non-negative-integer? (list-ref node 0))
                (positive? (list-ref node 0))
                (stable-resource? (list-ref node 1))
                (exact-non-negative-integer? (list-ref node 2))
                (exact-non-negative-integer? (list-ref node 3))
                (exact-non-negative-integer? (list-ref node 4))
                (<= (list-ref node 3) (list-ref node 4))
                (or (not (list-ref node 5))
                    (string? (list-ref node 5)))
                (exact-non-negative-integer? (list-ref node 6))))
            nodes)
          (let ([node-ids (map car nodes)])
            (for-all
              (lambda (edge)
                (and
                  (list? edge)
                  (= (length edge) 4)
                  (memv (list-ref edge 0) node-ids)
                  (memv (list-ref edge 1) node-ids)
                  (symbol? (list-ref edge 2))
                  (exact-non-negative-integer? (list-ref edge 3))))
              edges))))))

  (define (buffer-reference? value)
    (or
      (stable-resource? value)
      (and (list? value)
           (= (length value) 2)
           (eq? (car value) 'application)
           (exact-non-negative-integer? (cadr value)))))

  (define (valid-view-datum? value)
    (and
      (list? value)
      (= (length value) 10)
      (or (not (list-ref value 0))
          (buffer-reference? (list-ref value 0)))
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
      (= (length value) 8)
      (non-empty-string? (list-ref value 0))
      (list? (list-ref value 1))
      (for-all stable-resource? (list-ref value 1))
      (or
        (not (list-ref value 2))
        (member (list-ref value 2) (list-ref value 1)))
      (list? (list-ref value 3))
      (for-all buffer-reference? (list-ref value 3))
      (exact-non-negative-integer? (list-ref value 4))
      (valid-layout-datum? (list-ref value 5))
      (valid-jump-graph-datum? (list-ref value 6))
      (list? (list-ref value 7))
      (for-all valid-location-list-datum? (list-ref value 7))))

  (define (valid-application-view-state? value)
    (and
      (list? value)
      (= (length value) 2)
      (let ([viewport (car value)])
        (and
          (pair? viewport)
          (exact-non-negative-integer? (car viewport))
          (exact-non-negative-integer? (cdr viewport))))))

  (define (valid-application-datum? value)
    (and
      (list? value)
      (= (length value) 7)
      (symbol? (list-ref value 0))
      (or (not (list-ref value 1)) (string? (list-ref value 1)))
      (symbol? (list-ref value 2))
      (boolean? (list-ref value 4))
      (list? (list-ref value 6))
      (for-all valid-application-view-state? (list-ref value 6))))

  (define (upgrade-v2-workbench-datum value)
    (unless (and (list? value) (= (length value) 7))
      (assertion-violation
        'workbench-session-decode
        "malformed version 2 Workbench session state"
        value))
    (let ([roots (list-ref value 1)])
      (list
        (list-ref value 0)
        roots
        (and (list? roots)
             (= (length roots) 1)
             (car roots))
        (list-ref value 2)
        (list-ref value 3)
        (list-ref value 4)
        (list-ref value 5)
        (list-ref value 6))))

  (define (normalize-session-datum datum)
    (cond
      [(and (list? datum)
            (= (length datum) 4)
            (eq? (car datum) schema-name)
            (eqv? (cadr datum) 2)
            (list? (cadddr datum)))
       (list
         schema-name schema-version (caddr datum)
         (map upgrade-v2-workbench-datum (cadddr datum))
         '())]
      [(and (list? datum)
            (= (length datum) 4)
            (eq? (car datum) schema-name)
            (eqv? (cadr datum) 3))
       (list
         schema-name schema-version (caddr datum) (cadddr datum) '())]
      [else datum]))

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
             [datum (normalize-session-datum (read port))]
             [trailing (read port)])
        (define (valid-reference-index? reference)
          (or
            (not (and (list? reference)
                      (pair? reference)
                      (eq? (car reference) 'application)))
            (< (cadr reference) (length (list-ref datum 4)))))
        (unless
          (and
            (eof-object? trailing)
            (list? datum)
            (= (length datum) 5)
            (eq? (car datum) schema-name)
            (= (cadr datum) schema-version)
            (exact-non-negative-integer? (caddr datum))
            (list? (list-ref datum 3))
            (pair? (list-ref datum 3))
            (< (caddr datum) (length (list-ref datum 3)))
            (for-all valid-workbench-datum? (list-ref datum 3))
            (list? (list-ref datum 4))
            (for-all valid-application-datum? (list-ref datum 4))
            (for-all
              (lambda (workbench)
                (and
                  (for-all valid-reference-index? (list-ref workbench 3))
                  (let validate-layout ([layout (list-ref workbench 5)])
                    (case (car layout)
                      [(leaf)
                       (valid-reference-index?
                         (list-ref (cadddr layout) 0))]
                      [(split)
                       (for-all validate-layout (caddr layout))]))))
              (list-ref datum 3)))
          (assertion-violation
            'workbench-session-decode
            "unsupported or malformed Workbench session state"))
        (%make-workbench-session-snapshot
          (caddr datum)
          (list-ref datum 3)
          (list-ref datum 4)))))

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
           (if (stable-resource? resource)
               (cons resource result)
               result)
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
              (filter stable-resource? (list-ref workbench 3))
              (map cadr (car (list-ref workbench 6)))
              (apply
                append
                (map
                  (lambda (locations)
                    (map car (list-ref locations 2)))
                  (list-ref workbench 7)))
              (collect-layout-resources
                (list-ref workbench 5)
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

  (define (restore-durable-location-item buffer-loader datum)
    (let ([buffer (buffer-loader (list-ref datum 0))])
      (make-location-item
        (and buffer (buffer-id buffer))
        (list-ref datum 0)
        (list-ref datum 1)
        (list-ref datum 2)
        (list-ref datum 3)
        (list-ref datum 4)
        '())))

  (define (restore-location-list buffer-loader datum)
    (let* ([locations
             (make-location-list
               (list-ref datum 0)
               (map
                 (lambda (item)
                   (restore-durable-location-item buffer-loader item))
                 (list-ref datum 2)))]
           [index (list-ref datum 1)])
      (when index
        (location-list-set-index! locations index))
      locations))

  (define (restore-jump-graph! graph buffer-loader datum)
    (let ([nodes
            (map
              (lambda (node)
                (let ([buffer (buffer-loader (list-ref node 1))])
                  (make-jump-node
                    (list-ref node 0)
                    (list-ref node 1)
                    (and buffer (buffer-id buffer))
                    (list-ref node 2)
                    (list-ref node 3)
                    (list-ref node 4)
                    (list-ref node 5)
                    #f
                    (list-ref node 6))))
              (car datum))]
          [edges
            (map
              (lambda (edge)
                (make-jump-edge
                  (list-ref edge 0)
                  (list-ref edge 1)
                  (list-ref edge 2)
                  (list-ref edge 3)))
              (cadr datum))])
      (jump-graph-replace! graph nodes edges)
      (for-each
        (lambda (node)
          (let ([buffer (buffer-loader (jump-node-resource node))])
            (when buffer
              (jump-graph-attach-buffer! graph buffer))))
        nodes)
      graph))

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
               (list-ref datum 5)
               buffer-loader
               fallback-buffer
               projects
               metadata)]
           [leaves (vector-ref metadata 0)]
           [active-index
             (min
               (list-ref datum 4)
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
      (let ([focused-root (list-ref datum 2)])
        (let ([focused-project
                (and
                  focused-root
                  (find
                    (lambda (project)
                      (string=?
                        focused-root
                        (project-primary-root project)))
                    projects))])
          (workbench-set-focused-project!
            workbench
            (and focused-project (project-id focused-project)))))
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
            (list-ref datum 3))))
      (restore-jump-graph!
        (workbench-jump-graph workbench)
        buffer-loader
        (list-ref datum 6))
      (workbench-replace-location-lists!
        workbench
        (map
          (lambda (locations)
            (restore-location-list buffer-loader locations))
          (list-ref datum 7)))
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
    (for-each
      (lambda (session) (tui-close! editor (tui-session-id session)))
      (editor-tui-sessions editor))
    (let* ([application-data
             (workbench-session-snapshot-applications snapshot)]
           [existing (editor-workbenches editor)]
           [fallback-buffer (view-buffer (editor-active-view editor))]
           [application-buffers
             (map
               (lambda (datum)
                 (guard (condition [else #f])
                   (tui-restore!
                     editor
                     (make-tui-session-snapshot
                       (list-ref datum 0)
                       (list-ref datum 1)
                       (list-ref datum 2)
                       (list-ref datum 3)
                       (list-ref datum 4)
                       (list-ref datum 5)
                       (list-ref datum 6)))))
               application-data)]
           [resolve-buffer
             (lambda (reference)
               (cond
                 [(stable-resource? reference) (buffer-loader reference)]
                 [(and (list? reference)
                       (= (length reference) 2)
                       (eq? (car reference) 'application)
                       (< (cadr reference) (length application-buffers)))
                  (list-ref application-buffers (cadr reference))]
                 [else #f]))]
           [states (workbench-session-snapshot-workbenches snapshot)]
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
            editor workbench state resolve-buffer fallback-buffer))
        targets
        states)
      (editor-switch-workbench!
        editor
        (workbench-id
          (list-ref
            targets
            (workbench-session-snapshot-active-index snapshot))))
      (editor-set-current-location-list!
        editor
        (workbench-current-location-list
          (editor-active-workbench editor)))
      (for-each
        (lambda (buffer datum)
          (when buffer
            (let ([session
                    (editor-tui-session-for-buffer
                      editor
                      (buffer-id buffer))])
              (when session
                (tui-restore-session-view-states!
                  session
                  (list-ref datum 6))))))
        application-buffers
        application-data)
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
