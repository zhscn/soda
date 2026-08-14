(library (soda packages buffer-ui commands)
  (export install-buffer-item-commands!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host package)
          (soda host value)
          (soda packages buffer-ui action)
          (soda packages buffer-ui item))

  (define (all-item-ranges state)
    (list-sort
      (lambda (left right)
        (or (< (range-value-from left) (range-value-from right))
            (and (= (range-value-from left) (range-value-from right))
                 (< (range-value-to left) (range-value-to right)))))
      (apply append (map range-set-ranges (buffer-item-ranges state)))))

  (define (context-point context)
    (selection-range-head
      (selection-primary-range
        (view-state-selection (command-context-view-state context)))))

  (define (move-to-item context range)
    (make-view-transaction-spec
      (command-context-view-id context)
      (view-state-generation (command-context-view-state context))
      (make-selection
        (list (make-selection-range (range-value-from range) (range-value-from range))))
      #f #f '() '() #f))

  (define (move-line context amount)
    (let* ([state (command-context-buffer-state context)]
           [snapshot (buffer-state-document state)]
           [text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([position (text-position text (context-point context))]
                 [line (max 0 (min (- (text-line-count text) 1)
                                   (+ (car position) amount)))]
                 [point (text-offset text line (cdr position))])
            (move-to-item context (make-range-value point point #f))))
        (lambda () (text-close! text)))))

  (define (scroll-page context amount)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        #f #f #f '() '()
        (make-scroll-request
          'scroll-pages
          (command-context-surface-id context)
          (command-context-window-id context)
          (command-context-view-id context)
          amount))))

  (define (next-item-range state point)
    (let loop ([ranges (all-item-ranges state)])
      (and (pair? ranges)
           (if (> (range-value-from (car ranges)) point)
               (car ranges)
               (loop (cdr ranges))))))

  (define (previous-item-range state point)
    (let loop ([ranges (all-item-ranges state)] [previous #f])
      (if (null? ranges)
          previous
          (if (>= (range-value-from (car ranges)) point)
              previous
              (loop (cdr ranges) (car ranges))))))

  (define (edge-item-range state first?)
    (let ([ranges (all-item-ranges state)])
      (and (pair? ranges)
           (if first?
               (car ranges)
               (let loop ([items (cdr ranges)] [last (car ranges)])
                 (if (null? items) last (loop (cdr items) (car items))))))))

  (define (install-buffer-item-commands! runtime owner actions host)
    (unless (and (command-runtime? runtime) (owner? owner)
                 (buffer-item-action-service? actions) (package-host? host))
      (assertion-violation 'install-buffer-item-commands!
                           "invalid BufferItem command dependencies" runtime owner actions))
    (define-command
      runtime owner 'buffer.next-line (context)
      (documentation "Move to the next logical line in a special Buffer.")
      (class 'generated-buffer) (scope 'mode) (repeatable #t) (undo 'ignore)
      (move-line context 1))
    (define-command
      runtime owner 'buffer.previous-line (context)
      (documentation "Move to the previous logical line in a special Buffer.")
      (class 'generated-buffer) (scope 'mode) (repeatable #t) (undo 'ignore)
      (move-line context -1))
    (define-command
      runtime owner 'buffer.page-up (context)
      (documentation "Scroll a special Buffer toward its beginning.")
      (class 'generated-buffer) (scope 'mode) (repeatable #t) (undo 'ignore)
      (scroll-page context -1))
    (define-command
      runtime owner 'buffer.page-down (context)
      (documentation "Scroll a special Buffer toward its end.")
      (class 'generated-buffer) (scope 'mode) (repeatable #t) (undo 'ignore)
      (scroll-page context 1))
    (define-command
      runtime owner 'buffer.next-item (context)
      (documentation "Move to the next semantic Buffer item.")
      (class 'buffer-item) (scope 'mode) (repeatable #t) (undo 'ignore)
      (let ([range (next-item-range (command-context-buffer-state context)
                                    (context-point context))])
        (if range (move-to-item context range) (command-handled))))
    (define-command
      runtime owner 'buffer.previous-item (context)
      (documentation "Move to the previous semantic Buffer item.")
      (class 'buffer-item) (scope 'mode) (repeatable #t) (undo 'ignore)
      (let ([range (previous-item-range (command-context-buffer-state context)
                                        (context-point context))])
        (if range (move-to-item context range) (command-handled))))
    (define-command
      runtime owner 'buffer.first-item (context)
      (documentation "Move to the first semantic Buffer item.")
      (class 'buffer-item) (scope 'mode) (repeatable #t) (undo 'ignore)
      (let ([range (edge-item-range (command-context-buffer-state context) #t)])
        (if range (move-to-item context range) (command-handled))))
    (define-command
      runtime owner 'buffer.last-item (context)
      (documentation "Move to the last semantic Buffer item.")
      (class 'buffer-item) (scope 'mode) (repeatable #t) (undo 'ignore)
      (let ([range (edge-item-range (command-context-buffer-state context) #f)])
        (if range (move-to-item context range) (command-handled))))
    (define-command
      runtime owner 'buffer.activate-item (context)
      (documentation "Run the primary action for the semantic item at point.")
      (class 'buffer-item) (scope 'mode) (undo 'ignore)
      (let ([item (buffer-item-at-point (command-context-buffer-state context)
                                        (context-point context))])
        (if (and item (buffer-item-primary-action item))
            (or (buffer-item-action-invoke
                  actions (buffer-item-primary-action item) item context)
                (command-handled))
            (command-handled))))
    (define-command
      runtime owner 'buffer.quit (context)
      (documentation "Return from the active special Buffer without killing it.")
      (class 'generated-buffer) (scope 'mode) (undo 'ignore)
      (package-host-bury-window! host context)
      (command-handled)))
)
