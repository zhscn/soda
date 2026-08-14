(library (soda packages base fundamental-kill)
  (export make-kill-ring
          kill-ring?
          record-kill!
          copy-region
          kill-region
          kill-word
          kill-line
          cut-text
          yank)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base editing-context)
          (soda packages base fundamental-edit)
          (soda packages base fundamental-selection)
          (soda packages base text-motion)
          (soda host command))

  (define-record-type
    (kill-ring %make-kill-ring kill-ring?)
    (fields (mutable entries kill-ring-entries kill-ring-entries-set!)))

  (define (make-kill-ring)
    (%make-kill-ring '()))

  (define (replace-primary-selection selection range)
    (let ([primary (selection-primary selection)])
      (make-selection
        (let loop ([remaining (selection-ranges selection)]
                   [index 0] [result '()])
          (if (null? remaining)
              (reverse result)
              (loop
                (cdr remaining) (+ index 1)
                (cons (if (= index primary) range (car remaining)) result))))
        primary)))

  (define (primary-region-bytes context)
    (let ([range (selection-primary-range (context-selection context))])
      (and (not (selection-range-empty? range))
           (with-context-text
             context
             (lambda (text)
               (text-subbytevector text
                                   (selection-range-from range)
                                   (selection-range-to range)))))))

  (define (record-kill! ring bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'fundamental.record-kill "expected UTF-8 bytes" bytes))
    (let ([entries (cons (bytevector-copy bytes) (kill-ring-entries ring))])
      (kill-ring-entries-set!
        ring
        (let loop ([items entries] [remaining 60])
          (if (or (zero? remaining) (null? items))
              '()
              (cons (car items) (loop (cdr items) (- remaining 1)))))))
    bytes)

  (define (copy-region context)
    (let ([bytes (primary-region-bytes context)])
      (if (not bytes)
          (command-handled)
          (make-command-result
            (list
              (fundamental-deactivate-mark context)
              (make-command-effect 'fundamental.record-kill bytes)
              (make-command-effect 'clipboard.write bytes))))))

  (define (kill-range context range start end)
    (if (= start end)
        (command-handled)
        (let ([bytes
               (with-context-text
                 context
                 (lambda (text) (text-subbytevector text start end)))])
          (let* ([length (context-document-length context)]
                 [changes (make-change-set
                            length
                            (list (make-text-change start end (make-bytevector 0))))]
                 [selection (make-selection (list (collapse-range range start)) 0)])
            (make-command-result
              (list
                (make-transaction-spec
                  (command-context-buffer-id context)
                  (command-context-view-id context)
                  (buffer-state-generation (command-context-buffer-state context))
                  changes selection '() '())
                (make-command-effect 'fundamental.record-kill bytes)
                (make-command-effect 'clipboard.write bytes)))))))

  (define (kill-region context)
    (let ([range (selection-primary-range (context-selection context))])
      (kill-range context range (selection-range-from range) (selection-range-to range))))

  (define (kill-word context direction)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (kill-region context)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [other ((if (eq? direction 'backward)
                                 text-backward-word-offset
                                 text-forward-word-offset)
                             text point)])
                (kill-range context range (min point other) (max point other))))))))

  (define (kill-line context)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (kill-region context)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [line (car (text-position text point))]
                     [end (text-line-content-end text line)]
                     [to (if (< point end)
                             end
                             (text-next-grapheme-offset text point))])
                (kill-range context range point to)))))))

  ;; The line-oriented variant removes the complete logical line when there
  ;; is no active region.  It remains a separate reusable primitive from
  ;; kill-to-end-of-line.
  (define (cut-text context)
    (let ([range (selection-primary-range (context-selection context))])
      (if (not (selection-range-empty? range))
          (kill-region context)
          (with-context-text
            context
            (lambda (text)
              (let* ([point (selection-range-head range)]
                     [line (car (text-position text point))]
                     [from (text-line-start text line)]
                     [content-end (text-line-content-end text line)]
                     [size (text-size text)]
                     ;; Include the line terminator when one exists.  This
                     ;; makes cutting a middle line leave its neighbours
                     ;; adjacent, while a final unterminated line remains a
                     ;; valid empty Buffer.
                     [to (if (< content-end size)
                             (text-next-grapheme-offset text content-end)
                             content-end)])
                (kill-range context range from to)))))))

  (define (yank context ring)
    (let ([entries (kill-ring-entries ring)])
      (if (null? entries)
          (command-handled)
          (replace-selection context (bytevector-copy (car entries))))))
)
