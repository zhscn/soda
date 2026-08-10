(library (soda packages base fundamental-interface)
  (export fundamental-scroll-visual fundamental-recenter-viewport
          fundamental-move-to-viewport-row fundamental-pointer-selection)
  (import (rnrs)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base text-motion)
          (soda host command)
          (soda host input-event)
          (soda host render)
          (soda host value))

  (define (viewport-intent context kind argument)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        #f #f #f '() '()
        (make-scroll-request
          kind (command-context-surface-id context)
          (command-context-window-id context) (command-context-view-id context)
          argument))))

  (define (fundamental-scroll-visual context amount page?)
    (viewport-intent context (if page? 'scroll-pages 'scroll-rows) amount))

  (define (fundamental-recenter-viewport context placement)
    (viewport-intent context 'recenter placement))

  (define (fundamental-move-to-viewport-row context placement)
    (viewport-intent context 'move-point-to-window-row placement))

  (define (context-selection context)
    (view-state-selection (command-context-view-state context)))

  (define (with-context-text context procedure)
    (let ([text (snapshot-text
                  (buffer-state-document (command-context-buffer-state context)))])
      (dynamic-wind (lambda () #f) (lambda () (procedure text))
                    (lambda () (text-close! text)))))

  (define (view-selection-transaction context selection)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        selection #f #f '() '() #f)))

  (define (replace-primary-selection selection range)
    (let ([primary (selection-primary selection)])
      (make-selection
        (let loop ([remaining (selection-ranges selection)] [index 0] [result '()])
          (if (null? remaining)
              (reverse result)
              (loop (cdr remaining) (+ index 1)
                    (cons (if (= index primary) range (car remaining)) result))))
        primary)))

  (define (pointer-word-range text offset)
    (let ([size (text-size text)])
      (cond
        [(and (< offset size) (text-word-character-at? text offset))
         (make-selection-range (text-backward-word-offset text offset)
                               (text-forward-word-offset text offset))]
        [(text-word-character-before? text offset)
         (make-selection-range (text-backward-word-offset text offset)
                               (text-forward-word-offset text offset))]
        [else (make-selection-range offset offset)])))

  (define (pointer-line-range text offset)
    (let ([line (car (text-position text offset))])
      (make-selection-range (text-line-start text line)
                            (text-line-content-end text line)
                            'before 'line '())))

  (define (fundamental-pointer-selection context)
    (let ([event (command-context-event context)] [hit (command-context-target context)])
      (if (not (and (pointer-event? event) (surface-hit? hit)
                    (surface-hit-document-offset hit)))
          (command-handled)
          (let* ([selection (context-selection context)]
                 [primary (selection-primary-range selection)]
                 [offset (surface-hit-document-offset hit)]
                 [phase (pointer-event-phase event)]
                 [clicks (pointer-event-click-count event)]
                 [shift? (pointer-event-modifier? event 'shift)]
                 [ctrl? (pointer-event-modifier? event 'ctrl)])
            (with-context-text
              context
              (lambda (text)
                (let ([range
                       (cond
                         [(eq? phase 'release) primary]
                         [(eq? phase 'move)
                          (make-selection-range (selection-range-anchor primary) offset)]
                         [(>= clicks 3) (pointer-line-range text offset)]
                         [(= clicks 2) (pointer-word-range text offset)]
                         [shift?
                          (make-selection-range (selection-range-anchor primary) offset)]
                         [else (make-selection-range offset offset)])])
                  (view-selection-transaction
                    context
                    (if (and ctrl? (eq? phase 'press))
                        (make-selection
                          (append (selection-ranges selection) (list range))
                          (length (selection-ranges selection)))
                        (replace-primary-selection selection range))))))))))
)
