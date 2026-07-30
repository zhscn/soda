(library (soda editor diagnostics)
  (export install-diagnostic-commands!)
  (import (rnrs)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor keymap)
          (soda editor location)
          (soda editor navigation)
          (soda editor state))

  (define (diagnostic-item? item)
    (let ([metadata (location-item-metadata item)])
      (and
        (annotation? metadata)
        (eq? (annotation-kind metadata) 'diagnostic))))

  (define (item-before? left right)
    (cond
      [(< (location-item-start left)
          (location-item-start right))
       #t]
      [(> (location-item-start left)
          (location-item-start right))
       #f]
      [else
       (< (location-item-end left)
          (location-item-end right))]))

  (define (insert-item item items)
    (cond
      [(null? items) (list item)]
      [(item-before? item (car items)) (cons item items)]
      [else (cons (car items)
                  (insert-item item (cdr items)))]))

  (define (sort-items items)
    (fold-left
      (lambda (result item) (insert-item item result))
      '()
      items))

  (define (current-diagnostic-items editor buffer)
    (sort-items
      (filter
        diagnostic-item?
        (fold-left
          (lambda (items set)
            (append
              items
              (annotation-set-location-items
                set
                (buffer-revision buffer))))
          '()
          (editor-annotation-sets-for-buffer
            editor
            (buffer-id buffer))))))

  (define (list-diagnostics-command context)
    (let* ([editor (command-context-editor context)]
           [buffer
             (view-buffer
               (command-context-view context))]
           [items
             (current-diagnostic-items editor buffer)])
      (if (null? items)
          (begin
            (editor-set-current-location-list! editor #f)
            (editor-set-status-message!
              editor
              "No current diagnostics"))
          (let ([locations
                  (make-location-list 'diagnostics items)])
            (editor-set-current-location-list! editor locations)
            (editor-jump-to-buffer!
              editor
              buffer
              (location-item-start
                (location-list-current locations)))
            (editor-set-status-message!
              editor
              (string-append
                "Diagnostics: "
                (number->string (length items))))))
      '()))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-diagnostic-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'diagnostics.list
        list-diagnostics-command
        "Publish current-buffer diagnostics as a location list."))
    (editor-bind-key!
      editor
      (list (stroke #\g 2) (stroke #\d 0))
      'diagnostics.list)
    editor))
