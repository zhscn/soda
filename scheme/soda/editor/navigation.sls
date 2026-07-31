(library (soda editor navigation)
  (export editor-jump-to-location!
          editor-jump-to-buffer!
          editor-jump-view-to-buffer!
          editor-begin-async-jump!
          editor-complete-async-jump!
          editor-cancel-async-jump!
          editor-jump-history
          editor-jump-back!
          editor-jump-forward!
          install-navigation-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor display-placement)
          (soda editor keymap)
          (soda editor jump-graph)
          (soda editor location)
          (soda editor resource-context)
          (soda editor state)
          (soda editor window)
          (soda editor workbench))

  (define walk-limit 100)

  (define-record-type
    (pending-jump make-pending-jump pending-jump?)
    (fields resource
            kind
            placeholder
            entry-count
            jump-count
            cursor))

  (define (replace-at values index replacement)
    (let loop ([values values] [index index])
      (cond
        [(null? values)
         (assertion-violation
           'replace-at
           "index is outside the list")]
        [(zero? index) (cons replacement (cdr values))]
        [else
         (cons
           (car values)
           (loop (cdr values) (- index 1)))])))

  (define (take values count)
    (if (or (zero? count) (null? values))
        '()
        (cons (car values) (take (cdr values) (- count 1)))))

  (define (drop values count)
    (if (or (zero? count) (null? values))
        values
        (drop (cdr values) (- count 1))))

  (define (close-locations! values)
    (for-each editor-location-close! values))

  (define (drop-last values)
    (reverse (cdr (reverse values))))

  (define (pending-current? walk pending)
    (let ([cursor (navigation-walk-cursor walk)]
          [entries (navigation-walk-entries walk)])
      (and cursor
           (= cursor (- (length entries) 1))
           (eq? (list-ref entries cursor)
                (pending-jump-placeholder pending)))))

  (define (cancel-pending-walk! walk)
    (let ([pending (navigation-walk-pending walk)])
      (when pending
        (when (pending-current? walk pending)
          (let* ([entry-count (pending-jump-entry-count pending)]
                 [entries (navigation-walk-entries walk)]
                 [discarded (drop entries entry-count)])
            (navigation-walk-replace-entries!
              walk (take entries entry-count))
            (navigation-walk-replace-jumps!
              walk
              (take
                (navigation-walk-jumps walk)
                (pending-jump-jump-count pending)))
            (navigation-walk-cursor-set!
              walk (pending-jump-cursor pending))
            (close-locations! discarded)))
        (navigation-walk-pending-set! walk #f))))

  (define (current-location view)
    (make-buffer-location
      (view-buffer view)
      (view-caret view)))

  (define (replace-current! walk location)
    (let ([cursor (navigation-walk-cursor walk)]
          [entries (navigation-walk-entries walk)])
      (if (not cursor)
          (begin
            (navigation-walk-replace-entries!
              walk
              (list location))
            (navigation-walk-cursor-set! walk 0))
          (begin
            (editor-location-close! (list-ref entries cursor))
            (navigation-walk-replace-entries!
              walk
              (replace-at entries cursor location))))))

  (define (editor-buffer-find editor id)
    (find
      (lambda (buffer) (= (buffer-id buffer) id))
      (editor-buffers editor)))

  (define (location-valid? editor location)
    (let ([buffer
            (editor-buffer-find
              editor
              (editor-location-buffer-id location))])
      (and buffer
           (editor-location-valid-for-buffer? location buffer))))

  (define (activate-location! editor view location)
    (let ([buffer
            (editor-buffer-find
              editor
              (editor-location-buffer-id location))])
      (unless (and buffer
                   (editor-location-valid-for-buffer?
                     location buffer))
        (assertion-violation
          'activate-location!
          "jump target is stale or unavailable"
          (editor-location-buffer-id location)
          (editor-location-revision location)))
      (unless (= (buffer-id (view-buffer view)) (buffer-id buffer))
        (let ([context
                (editor-view-resource-context editor (view-id view))])
          (editor-set-view-buffer!
            editor
            (view-id view)
            (buffer-id buffer))
          (editor-set-view-resource-context!
            editor
            (view-id view)
            context)))
      (view-set-caret! view (editor-location-offset location))
      (ensure-view-visible! view)
      location))

  (define (trim-walk! walk)
    (let* ([entries (navigation-walk-entries walk)]
           [excess (max 0 (- (length entries) (+ walk-limit 1)))])
      (when (positive? excess)
        (close-locations! (take entries excess))
        (navigation-walk-replace-entries!
          walk
          (drop entries excess))
        (navigation-walk-replace-jumps!
          walk
          (drop (navigation-walk-jumps walk) excess))
        (navigation-walk-cursor-set!
          walk
          (- (navigation-walk-cursor walk) excess)))))

  (define (editor-jump-history editor)
    (require-open-editor 'editor-jump-history editor)
    (navigation-walk-jumps
      (view-navigation-walk (editor-active-view editor))))

  (define (jump-view-to-location! editor view location kind)
       (require-open-editor 'editor-jump-to-location! editor)
       (unless (and (editor-location? location) (symbol? kind))
         (assertion-violation
           'editor-jump-to-location!
           "expected an editor location and jump kind"
           location
           kind))
       (unless (location-valid? editor location)
         (assertion-violation
           'editor-jump-to-location!
           "jump target is stale or unavailable"
           (editor-location-buffer-id location)))
       (let* ([walk (view-navigation-walk view)]
              [source-language-context
                (resource-context-language-context
                  (editor-view-resource-context editor (view-id view)))]
              [ignored (cancel-pending-walk! walk)]
              [current (current-location view)]
              [cursor (navigation-walk-cursor walk)]
              [branched?
                (and cursor
                     (< cursor
                        (- (length (navigation-walk-entries walk)) 1)))]
              [revisit (and branched? (current-location view))]
              [ignored
                (when cursor (replace-current! walk current))]
              [base-entries
                (cond
                  [branched?
                   (append
                     (navigation-walk-entries walk)
                     (list revisit))]
                  [cursor (navigation-walk-entries walk)]
                  [else (list current)])]
              [base-jumps
                (if branched?
                    (let* ([previous
                             (car
                               (reverse
                                 (navigation-walk-entries walk)))]
                           [bridge-kind 'history-branch])
                      (append
                        (navigation-walk-jumps walk)
                        (list
                          (make-jump-history-entry
                            bridge-kind
                            (editor-location->item
                              previous 'source bridge-kind
                              source-language-context)
                            (editor-location->item
                              revisit 'target bridge-kind
                              source-language-context)))))
                    (navigation-walk-jumps walk))]
              [source-location (or revisit current)]
              [activated (activate-location! editor view location)]
              [target-language-context
                (resource-context-language-context
                  (editor-view-resource-context editor (view-id view)))]
              [jump
                (make-jump-history-entry
                  kind
                  (editor-location->item
                    source-location 'source kind source-language-context)
                  (editor-location->item
                    location 'target kind target-language-context))])
         (let ([workbench
                 (editor-workbench-for-view editor (view-id view))])
           (when workbench
             (jump-graph-record!
               (workbench-jump-graph workbench)
               (jump-history-entry-source jump)
               (jump-history-entry-target jump)
               kind)))
         (navigation-walk-replace-entries!
           walk
           (append base-entries (list location)))
         (navigation-walk-replace-jumps!
           walk
           (append base-jumps (list jump)))
         (navigation-walk-cursor-set!
           walk
           (- (length (navigation-walk-entries walk)) 1))
         (trim-walk! walk)
         activated))

  (define editor-jump-to-location!
    (case-lambda
      [(editor location)
       (editor-jump-to-location! editor location 'explicit)]
      [(editor location kind)
       (jump-view-to-location!
         editor (editor-active-view editor) location kind)]))

  (define (editor-jump-view-to-buffer!
            editor view buffer offset kind)
    (require-open-editor 'editor-jump-view-to-buffer! editor)
    (unless (and
              (view? view)
              (buffer? buffer)
              (integer? offset)
              (exact? offset)
              (not (negative? offset))
              (symbol? kind))
      (assertion-violation
        'editor-jump-view-to-buffer!
        "expected a View, Buffer, offset, and jump kind"
        view buffer offset kind))
    (unless
      (eq? (editor-view-ref editor (view-id view)) view)
      (assertion-violation
        'editor-jump-view-to-buffer!
        "View does not belong to the editor"
        view))
    (jump-view-to-location!
      editor
      view
      (make-buffer-location buffer offset)
      kind))

  (define (editor-begin-async-jump! editor view resource kind)
    (require-open-editor 'editor-begin-async-jump! editor)
    (unless (and (view? view) (string? resource) (symbol? kind))
      (assertion-violation
        'editor-begin-async-jump!
        "expected a view, resource, and jump kind"
        view resource kind))
    (let ([walk (view-navigation-walk view)])
      (cancel-pending-walk! walk)
      (let ([entry-count (length (navigation-walk-entries walk))]
            [jump-count (length (navigation-walk-jumps walk))]
            [cursor (navigation-walk-cursor walk)])
        (jump-view-to-location!
          editor
          view
          (make-buffer-location (view-buffer view) (view-caret view))
          kind)
        (navigation-walk-pending-set!
          walk
          (make-pending-jump
            resource
            kind
            (list-ref
              (navigation-walk-entries walk)
              (navigation-walk-cursor walk))
            entry-count
            jump-count
            cursor)))))

  (define (editor-complete-async-jump!
            editor view buffer offset resource)
    (require-open-editor 'editor-complete-async-jump! editor)
    (let* ([walk (view-navigation-walk view)]
           [pending (navigation-walk-pending walk)])
      (and
        pending
        (string=? resource (pending-jump-resource pending))
        (pending-current? walk pending)
        (let* ([target (make-buffer-location buffer offset)]
               [entries (navigation-walk-entries walk)]
               [jumps (navigation-walk-jumps walk)]
               [jump (car (reverse jumps))]
               [placeholder (pending-jump-placeholder pending)])
          (navigation-walk-replace-entries!
            walk (append (drop-last entries) (list target)))
          (let ([completed
                  (make-jump-history-entry
                    (pending-jump-kind pending)
                    (jump-history-entry-source jump)
                    (editor-location->item
                      target
                      'target
                      (pending-jump-kind pending)
                      (resource-context-language-context
                        (editor-view-resource-context
                          editor
                          (view-id view)))))])
            (navigation-walk-replace-jumps!
              walk
              (append (drop-last jumps) (list completed)))
            (let ([workbench
                    (editor-workbench-for-view editor (view-id view))])
              (when workbench
                (jump-graph-record!
                  (workbench-jump-graph workbench)
                  (jump-history-entry-source completed)
                  (jump-history-entry-target completed)
                  (pending-jump-kind pending)))))
          (navigation-walk-pending-set! walk #f)
          (editor-location-close! placeholder)
          (activate-location! editor view target)
          #t))))

  (define (editor-cancel-async-jump! editor view resource)
    (require-open-editor 'editor-cancel-async-jump! editor)
    (let* ([walk (view-navigation-walk view)]
           [pending (navigation-walk-pending walk)])
      (when (and pending
                 (or (not resource)
                     (string=? resource (pending-jump-resource pending))))
        (cancel-pending-walk! walk))))

  (define editor-jump-to-buffer!
    (case-lambda
      [(editor buffer offset)
       (editor-jump-to-buffer! editor buffer offset 'explicit)]
      [(editor buffer offset kind)
       (let ([origin (editor-active-view editor)])
         (editor-jump-to-buffer!
           editor
           buffer
           offset
           kind
           (editor-view-resource-context
             editor
             (view-id origin))))]
      [(editor buffer offset kind resource-context)
       (let* ([origin (editor-active-view editor)]
              [request
                (make-display-request
                  (buffer-id buffer)
                  'jump
                  (view-id origin)
                  #f
                  resource-context)]
              [plan (editor-plan-display editor request)]
              [workbench
                (editor-workbench-ref
                  editor
                  (display-plan-workbench-id plan))])
         (if (eq? (display-plan-action plan) 'split)
             (let ([view (editor-display-buffer! editor request)])
               (view-set-caret! view offset)
               (ensure-view-visible! view)
               #t)
             (let* ([leaf
                      (window-node-find
                        (workbench-layout workbench)
                        (display-plan-window-id plan))]
                    [view
                      (editor-view-ref
                        editor
                        (window-leaf-view-id leaf))]
                    [result
                      (jump-view-to-location!
                        editor
                        view
                        (make-buffer-location buffer offset)
                        kind)])
               (editor-set-view-resource-context!
                 editor
                 (view-id view)
                 (display-request-resource-context request))
               (when (display-plan-role plan)
                 (workbench-set-slot!
                   workbench
                   (display-plan-role plan)
                   (window-leaf-id leaf)))
               (when (eq? workbench (editor-active-workbench editor))
                 (editor-set-active-window-id!
                   editor
                   (window-leaf-id leaf))
                 (editor-set-active-view! editor (view-id view)))
               result)))]))

  (define (valid-step-index editor entries start delta)
    (let loop ([index (+ start delta)])
      (cond
        [(or (negative? index) (>= index (length entries))) #f]
        [(location-valid? editor (list-ref entries index)) index]
        [else (loop (+ index delta))])))

  (define (walk-step! editor delta)
    (let* ([view (editor-active-view editor)]
           [walk (view-navigation-walk view)]
           [cursor (navigation-walk-cursor walk)]
           [entries (navigation-walk-entries walk)]
           [target-index
             (and cursor
                  (valid-step-index editor entries cursor delta))])
      (if (not target-index)
          #f
          (begin
            (replace-current! walk (current-location view))
            (navigation-walk-cursor-set! walk target-index)
            (activate-location!
              editor
              view
              (list-ref
                (navigation-walk-entries walk)
                target-index))))))

  (define (editor-jump-back! editor)
    (require-open-editor 'editor-jump-back! editor)
    (walk-step! editor -1))

  (define (editor-jump-forward! editor)
    (require-open-editor 'editor-jump-forward! editor)
    (walk-step! editor 1))

  (define (jump-back-command context)
    (let ([editor (command-context-editor context)])
      (unless (editor-jump-back! editor)
        (editor-set-status-message! editor "No earlier location"))
      '()))

  (define (jump-forward-command context)
    (let ([editor (command-context-editor context)])
      (unless (editor-jump-forward! editor)
        (editor-set-status-message! editor "No later location"))
      '()))

  (define (install-navigation-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'navigation.back
        jump-back-command
        "Return to the previous location in this view."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'navigation.forward
        jump-forward-command
        "Advance to the next location in this view."))
    (editor-bind-key!
      editor
      (list
        (make-key-stroke
          'character
          (char->integer #\,)
          2))
      'navigation.back)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke
          'character
          (char->integer #\,)
          6))
      'navigation.forward)
    editor))
