(library (soda editor navigable-buffer)
  (export make-buffer-navigation-interface
          buffer-navigation-interface?
          buffer-navigation-interface-cyclic?
          buffer-set-navigation-interface!
          buffer-navigation-interface-ref
          editor-note-navigation-buffer!
          install-navigable-buffer-commands!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor state)
          (soda editor window-runtime))

  (define editor-navigation-buffers (make-weak-eq-hashtable))

  (define-record-type
    (buffer-navigation-interface
      %make-buffer-navigation-interface
      buffer-navigation-interface?)
    (fields cyclic?
            activate
            quit))

  (define (make-buffer-navigation-interface cyclic? activate quit)
    (unless (and (boolean? cyclic?)
                 (procedure? activate)
                 (procedure? quit))
      (assertion-violation
        'make-buffer-navigation-interface
        "invalid Buffer navigation interface"
        cyclic? activate quit))
    (%make-buffer-navigation-interface cyclic? activate quit))

  (define (buffer-set-navigation-interface! buffer interface)
    (unless (and (buffer? buffer)
                 (buffer-navigation-interface? interface))
      (assertion-violation
        'buffer-set-navigation-interface!
        "expected a Buffer and navigation interface"
        buffer interface))
    (buffer-set-local! buffer 'navigation-interface interface)
    (buffer-set-local! buffer 'result-current-index #f)
    buffer)

  (define (buffer-navigation-interface-ref buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-navigation-interface-ref "expected a Buffer" buffer))
    (buffer-local-ref buffer 'navigation-interface #f))

  (define (editor-note-navigation-buffer! editor buffer)
    (unless (and (editor? editor) (buffer? buffer)
                 (buffer-navigation-interface?
                   (buffer-navigation-interface-ref buffer)))
      (assertion-violation
        'editor-note-navigation-buffer!
        "expected an Editor and navigable Buffer"
        editor buffer))
    (hashtable-set! editor-navigation-buffers editor (buffer-id buffer))
    buffer)

  (define (require-interface context who)
    (let* ([buffer (view-buffer (command-context-view context))]
           [interface (buffer-navigation-interface-ref buffer)])
      (unless (buffer-navigation-interface? interface)
        (editor-user-error who "Current Buffer is not navigable"))
      (values buffer interface)))

  (define (property-positions buffer interface)
    (map
      (lambda (range) (cons (car range) (caddr range)))
      (buffer-text-property-ranges buffer 'result-index)))

  (define (property-starts buffer property)
    (map car (buffer-text-property-ranges buffer property)))

  (define (selected-item context who)
    (let-values ([(buffer interface) (require-interface context who)])
      (let* ([position (view-caret (command-context-view context))]
             [item
               (buffer-text-property-ref
                 buffer position 'result-item #f)]
             [index
               (buffer-text-property-ref
                 buffer position 'result-index #f)])
        (unless (and item (integer? index) (exact? index))
          (editor-user-error who "Point is not on a navigable item"))
        (buffer-set-local! buffer 'result-current-index index)
        (values buffer interface item index))))

  (define (activate-selected context disposition)
    (let-values ([(buffer interface item index)
                  (selected-item context 'buffer-item.activate)])
      ((buffer-navigation-interface-activate interface)
       context buffer item index disposition)))

  (define (bounded-index current delta size cyclic?)
    (let ([candidate (+ current delta)])
      (cond
        [cyclic? (mod candidate size)]
        [(< candidate 0) 0]
        [(>= candidate size) (- size 1)]
        [else candidate])))

  (define (move-buffer-item context buffer interface view delta)
      (let ([positions (property-positions buffer interface)])
        (if (null? positions)
            (begin
              (editor-set-status-message!
                (command-context-editor context) "No navigable items")
              '())
            (let* ([current
                     (or
                       (and view
                            (buffer-text-property-ref
                              buffer (view-caret view) 'result-index #f))
                       (buffer-local-ref buffer 'result-current-index #f))]
                   [base
                     (if current
                         current
                         (if (positive? delta) -1 (length positions)))]
                   [target
                     (bounded-index
                       base delta (length positions)
                       (buffer-navigation-interface-cyclic? interface))]
                   [entry (list-ref positions target)]
                   [position (car entry)]
                   [index (cdr entry)]
                   [item
                     (buffer-text-property-ref
                       buffer position 'result-item #f)])
              (when view
                (view-set-caret! view position)
                (ensure-view-visible! view))
              (buffer-set-local! buffer 'result-current-index index)
              ((buffer-navigation-interface-activate interface)
               context buffer item index 'preview)))))

  (define (move-item context delta)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.next)])
      (move-buffer-item
        context buffer interface (command-context-view context) delta)))

  (define (index-of-position positions position)
    (let loop ([items positions] [index 0] [found #f])
      (cond
        [(null? items) found]
        [(<= (car items) position)
         (loop (cdr items) (+ index 1) index)]
        [else found])))

  (define (first-item-after positions position limit)
    (find
      (lambda (entry)
        (and (> (car entry) position)
             (or (not limit) (< (car entry) limit))))
      positions))

  (define (move-buffer-group context buffer interface view direction)
    (let* ([groups (property-starts buffer 'result-group)]
           [items (property-positions buffer interface)])
      (if (or (null? groups) (null? items))
          (begin
            (editor-set-status-message!
              (command-context-editor context) "No result groups")
            '())
          (let* ([position
                   (if view
                       (view-caret view)
                       (let ([index
                               (buffer-local-ref
                                 buffer 'result-current-index #f)])
                         (if (and index (< index (length items)))
                             (car (list-ref items index))
                             0)))]
                 [current (index-of-position groups position)]
                 [base
                   (if current
                       current
                       (if (positive? direction) -1 (length groups)))]
                 [target
                   (bounded-index
                     base direction (length groups)
                     (buffer-navigation-interface-cyclic? interface))]
                 [group-start (list-ref groups target)]
                 [group-limit
                   (and (< (+ target 1) (length groups))
                        (list-ref groups (+ target 1)))]
                 [entry
                   (first-item-after items group-start group-limit)])
            (if (not entry)
                (begin
                  (editor-set-status-message!
                    (command-context-editor context)
                    "Result group contains no items")
                  '())
                (let* ([item-position (car entry)]
                       [index (cdr entry)]
                       [item
                         (buffer-text-property-ref
                           buffer item-position 'result-item #f)])
                  (when view
                    (view-set-caret! view item-position)
                    (ensure-view-visible! view))
                  (buffer-set-local! buffer 'result-current-index index)
                  ((buffer-navigation-interface-activate interface)
                   context buffer item index 'preview)))))))

  (define (move-group context direction)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.next-group)])
      (move-buffer-group
        context buffer interface (command-context-view context) direction)))

  (define (quit-buffer-items context)
    (let-values ([(buffer interface)
                  (require-interface context 'buffer-item.quit)])
      ((buffer-navigation-interface-quit interface) context buffer)))

  (define (global-navigation-context context)
    (let* ([editor (command-context-editor context)]
           [latest-buffer-id
                   (hashtable-ref editor-navigation-buffers editor #f)]
           [buffer
                   (and latest-buffer-id
                        (guard (condition [else #f])
                          (editor-buffer-ref editor latest-buffer-id)))]
           [view
                   (and latest-buffer-id
                        (find
                          (lambda (candidate)
                            (=
                              (buffer-id (view-buffer candidate))
                              latest-buffer-id))
                          (editor-views editor)))])
      (unless (and buffer
                   (buffer-navigation-interface-ref buffer))
        (editor-user-error
          'buffer-item.next-global
          "No navigable result Buffer"))
      (values buffer view)))

  (define (move-global-item context direction)
    (let ([active-buffer
            (view-buffer (command-context-view context))])
      (if (buffer-navigation-interface-ref active-buffer)
          (move-item context (* direction (command-context-count context)))
          (let-values ([(buffer view) (global-navigation-context context)])
            (move-buffer-item
              context
              buffer
              (buffer-navigation-interface-ref buffer)
              view
              (* direction (command-context-count context)))))))

  (define (install-navigable-buffer-commands! editor)
    (for-each
      (lambda (spec)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car spec) (cadr spec) (caddr spec))))
      (list
        (list 'buffer-item.next
              (lambda (context)
                (move-item context (command-context-count context)))
              "Move to and preview the next navigable Buffer item.")
        (list 'buffer-item.previous
              (lambda (context)
                (move-item context (- (command-context-count context))))
              "Move to and preview the previous navigable Buffer item.")
        (list 'buffer-item.next-group
              (lambda (context)
                (move-group context (command-context-count context)))
              "Move to and preview the next result group.")
        (list 'buffer-item.previous-group
              (lambda (context)
                (move-group context (- (command-context-count context))))
              "Move to and preview the previous result group.")
        (list 'buffer-item.activate
              (lambda (context) (activate-selected context 'select))
              "Activate the navigable Buffer item at point.")
        (list 'buffer-item.preview
              (lambda (context) (activate-selected context 'preview))
              "Preview the navigable Buffer item at point.")
        (list 'buffer-item.activate-and-close
              (lambda (context) (activate-selected context 'select-and-close))
              "Activate the item at point and close its presenting Buffer.")
        (list 'buffer-item.quit
              quit-buffer-items
              "Close the current navigable Buffer.")
        (list 'buffer-item.next-global
              (lambda (context) (move-global-item context 1))
              "Advance the most recent visible navigable Buffer.")
        (list 'buffer-item.previous-global
              (lambda (context) (move-global-item context -1))
              "Move backward in the most recent visible navigable Buffer.")
        (list 'xref.next-location
              (lambda (context) (move-global-item context 1))
              "Advance the most recent visible navigable Buffer.")
        (list 'xref.previous-location
              (lambda (context) (move-global-item context -1))
              "Move backward in the most recent visible navigable Buffer.")))
    editor)
)
