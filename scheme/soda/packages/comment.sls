(library (soda packages comment)
  (export make-comment-service!
          comment-service?
          comment-keymap)
  (import (rnrs)
          (rnrs sorting)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value))

  (define-record-type
    (comment-service %make-comment-service comment-service?)
    (fields (immutable keymap comment-keymap)))

  (define (context-comment-syntax context)
    (let ([mode
           (configuration-facet
             (buffer-state-configuration (command-context-buffer-state context))
             buffer-mode-facet 'buffer)])
      (and mode (mode-spec-effective-comment-syntax mode))))

  (define (unique-sorted values)
    (let loop ([remaining (list-sort < values)] [previous #f] [result '()])
      (cond
        [(null? remaining) (reverse result)]
        [(and previous (= previous (car remaining)))
         (loop (cdr remaining) previous result)]
        [else
         (loop (cdr remaining) (car remaining) (cons (car remaining) result))])))

  (define (selected-lines text selection)
    (unique-sorted
      (fold-left
        append '()
        (map
          (lambda (range)
            (let* ([from (selection-range-from range)]
                   [to (selection-range-to range)]
                   [first (car (text-position text from))]
                   [last
                    (car
                      (text-position
                        text
                        (if (and (> to from) (> to 0)) (- to 1) to)))])
              (let loop ([line first] [result '()])
                (if (> line last)
                    (reverse result)
                    (loop (+ line 1) (cons line result))))))
          (selection-ranges selection)))))

  (define (bytevector-prefix-at? text offset prefix)
    (and (<= (+ offset (bytevector-length prefix)) (text-size text))
         (let loop ([index 0])
           (or (= index (bytevector-length prefix))
               (and (= (text-byte-at text (+ offset index))
                       (bytevector-u8-ref prefix index))
                    (loop (+ index 1)))))))

  (define (line-indent-end text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (if (>= offset end)
            offset
            (let ([byte (text-byte-at text offset)])
              (if (or (= byte #x20) (= byte #x09))
                  (loop (+ offset 1))
                  offset))))))

  (define (line-comment-changes text selection prefix uncomment?)
    (let ([bytes (string->utf8 prefix)])
      (fold-right
        (lambda (line changes)
          (let ([offset (line-indent-end text line)])
            (if uncomment?
                (if (bytevector-prefix-at? text offset bytes)
                    (cons
                      (make-text-change
                        offset (+ offset (bytevector-length bytes))
                        (make-bytevector 0))
                      changes)
                    changes)
                (cons (make-text-change offset offset bytes) changes))))
        '() (selected-lines text selection))))

  (define (block-ranges text selection)
    (map
      (lambda (range)
        (if (selection-range-empty? range)
            (let* ([line (car (text-position text (selection-range-head range)))]
                   [from (text-line-start text line)]
                   [to (text-line-content-end text line)])
              (cons from to))
            (cons (selection-range-from range) (selection-range-to range))))
      (selection-ranges selection)))

  (define (block-comment-changes text selection syntax uncomment?)
    (let ([start (string->utf8 (comment-syntax-block-start syntax))]
          [end (string->utf8 (comment-syntax-block-end syntax))])
      (fold-right
        (lambda (range changes)
          (let ([from (car range)] [to (cdr range)])
            (if uncomment?
                (if (and (bytevector-prefix-at? text from start)
                         (>= (- to from)
                             (+ (bytevector-length start)
                                (bytevector-length end)))
                         (bytevector-prefix-at?
                           text (- to (bytevector-length end)) end))
                    (cons
                      (make-text-change
                        from (+ from (bytevector-length start))
                        (make-bytevector 0))
                      (cons
                        (make-text-change
                          (- to (bytevector-length end)) to
                          (make-bytevector 0))
                        changes))
                    changes)
                (cons (make-text-change from from start)
                      (cons (make-text-change to to end) changes)))))
        '() (block-ranges text selection))))

  (define (comment-transaction context uncomment?)
    (let* ([syntax (context-comment-syntax context)]
           [state (command-context-buffer-state context)]
           [document (buffer-state-document state)]
           [selection
            (view-state-selection (command-context-view-state context))])
      (unless syntax
        (assertion-violation
          (if uncomment? 'comment.remove 'comment.add)
          "the active major mode does not describe comment syntax"))
      (let ([text (snapshot-text document)])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let ([changes
                   (if (comment-syntax-line-prefix syntax)
                       (line-comment-changes
                         text selection (comment-syntax-line-prefix syntax)
                         uncomment?)
                       (block-comment-changes text selection syntax uncomment?))])
              (make-transaction-spec
                (command-context-buffer-id context)
                (command-context-view-id context)
                (buffer-state-generation state)
                (make-change-set (snapshot-byte-size document) changes)
                #f '() '())))
          (lambda () (text-close! text))))))

  (define (make-comment-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-comment-service!
                           "expected a PackageHost and Owner" host owner))
    (owner-assert-active 'make-comment-service! owner)
    (let ([keymap (make-keymap 'comment)]
          [runtime (package-host-command-runtime host)])
      (define-command
        runtime owner 'comment.add (context)
        (documentation "Comment every logical line covered by the active selections.")
        (class 'editing)
        (scope 'mode)
        (repeatable #t)
        (undo 'amalgamate)
        (comment-transaction context #f))
      (define-command
        runtime owner 'comment.remove (context)
        (documentation "Remove mode-defined comments from the selected logical lines.")
        (class 'editing)
        (scope 'mode)
        (repeatable #t)
        (undo 'amalgamate)
        (comment-transaction context #t))
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\;) 2))
        'comment.add)
      (keymap-bind!
        keymap (list (make-key-stroke 'character (char->integer #\:) 2))
        'comment.remove)
      (%make-comment-service keymap)))
)
