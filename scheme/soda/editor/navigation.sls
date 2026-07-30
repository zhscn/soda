(library (soda editor navigation)
  (export editor-jump-to-location!
          editor-jump-to-buffer!
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

  (define (drop-prefix values count)
    (if (zero? count)
        values
        (begin
          (editor-location-close! (car values))
          (drop-prefix (cdr values) (- count 1)))))

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

  (define (activate-location! editor view location)
    (let ([buffer
            (editor-buffer-ref
              editor
              (editor-location-buffer-id location))])
      (unless (= (buffer-id (view-buffer view)) (buffer-id buffer))
        (editor-set-view-buffer!
          editor
          (view-id view)
          (buffer-id buffer)))
      (view-set-caret! view (editor-location-offset location))
      (ensure-view-visible! view)
      location))

  (define (editor-jump-to-location! editor location)
    (require-open-editor 'editor-jump-to-location! editor)
    (unless (editor-location? location)
      (assertion-violation
        'editor-jump-to-location!
        "expected an editor location"
        location))
    (let* ([view (editor-active-view editor)]
           [walk (view-navigation-walk view)]
           [current (current-location view)]
           [entries (navigation-walk-entries walk)]
           [cursor (navigation-walk-cursor walk)])
      (if (and cursor (< cursor (- (length entries) 1)))
          (let ([revisit (current-location view)])
            (replace-current! walk current)
            (let* ([extended
                     (append
                       (navigation-walk-entries walk)
                       (list revisit location))]
                   [excess
                     (max 0 (- (length extended) walk-limit))]
                   [trimmed (drop-prefix extended excess)])
              (navigation-walk-replace-entries! walk trimmed)
              (navigation-walk-cursor-set!
                walk
                (- (length trimmed) 1))))
          (begin
            (if cursor
                (replace-current! walk current)
                (begin
                  (navigation-walk-replace-entries!
                    walk
                    (list current))
                  (navigation-walk-cursor-set! walk 0)))
            (let* ([extended
                     (append
                       (navigation-walk-entries walk)
                       (list location))]
                   [excess
                     (max 0 (- (length extended) walk-limit))]
                   [trimmed (drop-prefix extended excess)])
              (navigation-walk-replace-entries! walk trimmed)
              (navigation-walk-cursor-set!
                walk
                (- (length trimmed) 1)))))
      (activate-location! editor view location)))

  (define (editor-jump-to-buffer! editor buffer offset)
    (editor-jump-to-location!
      editor
      (make-buffer-location buffer offset)))

  (define (walk-step! editor delta)
    (let* ([view (editor-active-view editor)]
           [walk (view-navigation-walk view)]
           [cursor (navigation-walk-cursor walk)]
           [entries (navigation-walk-entries walk)]
           [target-index (and cursor (+ cursor delta))])
      (if (or (not target-index)
              (negative? target-index)
              (>= target-index (length entries)))
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
