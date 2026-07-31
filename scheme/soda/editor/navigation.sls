(library (soda editor navigation)
  (export editor-jump-to-location!
          editor-jump-to-buffer!
          editor-jump-history
          editor-jump-back!
          editor-jump-forward!
          install-navigation-commands!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor keymap)
          (soda editor location)
          (soda editor state))

  (define walk-limit 100)

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
        (editor-set-view-buffer!
          editor
          (view-id view)
          (buffer-id buffer)))
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

  (define editor-jump-to-location!
    (case-lambda
      [(editor location)
       (editor-jump-to-location! editor location 'explicit)]
      [(editor location kind)
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
       (let* ([view (editor-active-view editor)]
              [walk (view-navigation-walk view)]
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
                              previous 'source bridge-kind)
                            (editor-location->item
                              revisit 'target bridge-kind)))))
                    (navigation-walk-jumps walk))]
              [source-location (or revisit current)]
              [jump
                (make-jump-history-entry
                  kind
                  (editor-location->item
                    source-location 'source kind)
                  (editor-location->item location 'target kind))])
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
         (activate-location! editor view location))]))

  (define editor-jump-to-buffer!
    (case-lambda
      [(editor buffer offset)
       (editor-jump-to-buffer! editor buffer offset 'explicit)]
      [(editor buffer offset kind)
       (editor-jump-to-location!
         editor
         (make-buffer-location buffer offset)
         kind)]))

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
