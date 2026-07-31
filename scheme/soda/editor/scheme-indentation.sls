(library (soda editor scheme-indentation)
  (export scheme-continuation-indent)
  (import (rnrs))

  (define-record-type
    (indent-frame make-indent-frame indent-frame?)
    (fields
      opener
      column
      (mutable children indent-frame-children indent-frame-children-set!)))

  (define (delimiter? character)
    (memv character
          '(#\( #\) #\[ #\] #\{ #\} #\" #\;)))

  (define (separator? character)
    (or (char-whitespace? character)
        (delimiter? character)))

  (define (matching-opener character)
    (case character
      [(#\)) #\(]
      [(#\]) #\[]
      [(#\}) #\{]
      [else #f]))

  (define (record-child! stack column value)
    (unless (null? stack)
      (let ([frame (car stack)])
        (when (< (length (indent-frame-children frame)) 2)
          (indent-frame-children-set!
            frame
            (append
              (indent-frame-children frame)
              (list (cons column value))))))))

  (define (close-frame stack closer)
    (let ([opener (matching-opener closer)])
      (cond
        [(null? stack) stack]
        [(char=? opener (indent-frame-opener (car stack)))
         (cdr stack)]
        [else stack])))

  (define (character-literal-end source index limit)
    (let ([start (+ index 2)])
      (if
        (>= start limit)
        limit
        (if
          (separator? (string-ref source start))
          (+ start 1)
          (let loop ([next (+ start 1)])
            (if
              (and
                (< next limit)
                (not (separator? (string-ref source next))))
              (loop (+ next 1))
              next))))))

  (define (scan source)
    (let ([limit (string-length source)])
      (let loop ([index 0]
                 [column 0]
                 [stack '()]
                 [state 'normal]
                 [comment-depth 0])
        (if
          (= index limit)
          stack
          (let ([character (string-ref source index)])
            (case state
              [(line-comment)
               (if
                 (char=? character #\newline)
                 (loop (+ index 1) 0 stack 'normal 0)
                 (loop
                   (+ index 1)
                   (+ column 1)
                   stack
                   state
                   comment-depth))]
              [(string)
               (cond
                 [(char=? character #\\)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'string-escape
                    0)]
                 [(char=? character #\")
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'normal
                    0)]
                 [(char=? character #\newline)
                  (loop (+ index 1) 0 stack state 0)]
                 [else
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    state
                    0)])]
              [(string-escape)
               (loop
                 (+ index 1)
                 (if (char=? character #\newline)
                     0
                     (+ column 1))
                 stack
                 'string
                 0)]
              [(quoted-symbol)
               (cond
                 [(char=? character #\\)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'quoted-symbol-escape
                    0)]
                 [(char=? character #\|)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'normal
                    0)]
                 [(char=? character #\newline)
                  (loop (+ index 1) 0 stack state 0)]
                 [else
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    state
                    0)])]
              [(quoted-symbol-escape)
               (loop
                 (+ index 1)
                 (if (char=? character #\newline)
                     0
                     (+ column 1))
                 stack
                 'quoted-symbol
                 0)]
              [(block-comment)
               (cond
                 [(and
                    (< (+ index 1) limit)
                    (char=? character #\#)
                    (char=? (string-ref source (+ index 1)) #\|))
                  (loop
                    (+ index 2)
                    (+ column 2)
                    stack
                    state
                    (+ comment-depth 1))]
                 [(and
                    (< (+ index 1) limit)
                    (char=? character #\|)
                    (char=? (string-ref source (+ index 1)) #\#))
                  (loop
                    (+ index 2)
                    (+ column 2)
                    stack
                    (if (= comment-depth 1)
                        'normal
                        state)
                    (- comment-depth 1))]
                 [(char=? character #\newline)
                  (loop
                    (+ index 1)
                    0
                    stack
                    state
                    comment-depth)]
                 [else
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    state
                    comment-depth)])]
              [else
               (cond
                 [(char=? character #\newline)
                  (loop
                    (+ index 1)
                    0
                    stack
                    'normal
                    0)]
                 [(char-whitespace? character)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'normal
                    0)]
                 [(char=? character #\;)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'line-comment
                    0)]
                 [(and
                    (< (+ index 1) limit)
                    (char=? character #\#)
                    (char=? (string-ref source (+ index 1)) #\\))
                  (record-child! stack column 'datum)
                  (let ([next
                          (character-literal-end
                            source
                            index
                            limit)])
                    (loop
                      next
                      (+ column (- next index))
                      stack
                      'normal
                      0))]
                 [(and
                    (< (+ index 1) limit)
                    (char=? character #\#)
                    (char=? (string-ref source (+ index 1)) #\|))
                  (loop
                    (+ index 2)
                    (+ column 2)
                    stack
                    'block-comment
                    1)]
                 [(char=? character #\")
                  (record-child! stack column 'datum)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'string
                    0)]
                 [(char=? character #\|)
                  (record-child! stack column 'datum)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    stack
                    'quoted-symbol
                    0)]
                 [(memv character '(#\( #\[ #\{))
                  (record-child! stack column 'datum)
                  (loop
                    (+ index 1)
                    (+ column 1)
                    (cons
                      (make-indent-frame character column '())
                      stack)
                    'normal
                    0)]
                 [(memv character '(#\) #\] #\}))
                  (loop
                    (+ index 1)
                    (+ column 1)
                    (close-frame stack character)
                    'normal
                    0)]
                 [else
                  (let atom ([next (+ index 1)])
                    (if
                      (and
                        (< next limit)
                        (not
                          (separator?
                            (string-ref source next))))
                      (atom (+ next 1))
                      (begin
                        (record-child!
                          stack
                          column
                          (string->symbol
                            (substring source index next)))
                        (loop
                          next
                          (+ column (- next index))
                          stack
                          'normal
                          0))))])]))))))

  (define (frame-indent frame standard-indent)
    (let ([children (indent-frame-children frame)])
      (cond
        [(null? children)
         (+ (indent-frame-column frame) 1)]
        [(and
           (pair? (cdr children))
           (symbol? (cdr (car children)))
           (not (memq (cdr (car children)) '(let rec)))
           (< (- (car (cadr children))
                 (indent-frame-column frame))
              6))
         (car (cadr children))]
        [else
         (+ (indent-frame-column frame) standard-indent)])))

  (define (scheme-continuation-indent source standard-indent)
    (unless (string? source)
      (assertion-violation
        'scheme-continuation-indent
        "source must be a string"
        source))
    (unless
      (and
        (integer? standard-indent)
        (exact? standard-indent)
        (not (negative? standard-indent)))
      (assertion-violation
        'scheme-continuation-indent
        "standard indent must be a non-negative exact integer"
        standard-indent))
    (let ([stack (scan source)])
      (if
        (null? stack)
        0
        (frame-indent (car stack) standard-indent)))))
