(library (soda editor scheme-indentation)
  (export scheme-continuation-indent
          scheme-line-indent
          scheme-reindent-entry
          scheme-string-line-position
          scheme-string-line-start
          scheme-string-line-end
          scheme-string-leading-whitespace-end)
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
          (values stack state)
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

  (define (require-standard-indent who standard-indent)
    (unless
      (and
        (integer? standard-indent)
        (exact? standard-indent)
        (not (negative? standard-indent)))
      (assertion-violation
        who
        "standard indent must be a non-negative exact integer"
        standard-indent)))

  (define (context-indent stack standard-indent)
    (if
      (null? stack)
      0
      (frame-indent (car stack) standard-indent)))

  (define (current-line-leading-width source)
    (let ([length (string-length source)])
      (let find-start ([index length])
        (if
          (and
            (positive? index)
            (not
              (char=?
                (string-ref source (- index 1))
                #\newline)))
          (find-start (- index 1))
          (let count ([index index] [width 0])
            (if
              (and
                (< index length)
                (memv (string-ref source index) '(#\space #\tab)))
              (count (+ index 1) (+ width 1))
              width))))))

  (define (scheme-continuation-indent source standard-indent)
    (unless (string? source)
      (assertion-violation
        'scheme-continuation-indent
        "source must be a string"
        source))
    (require-standard-indent
      'scheme-continuation-indent
      standard-indent)
    (call-with-values
      (lambda () (scan source))
      (lambda (stack state)
        (if
          (memq state '(normal line-comment))
          (context-indent stack standard-indent)
          (current-line-leading-width source)))))

  (define (scheme-line-indent source standard-indent)
    (unless (string? source)
      (assertion-violation
        'scheme-line-indent
        "source prefix must be a string"
        source))
    (require-standard-indent 'scheme-line-indent standard-indent)
    (call-with-values
      (lambda () (scan source))
      (lambda (stack state)
        (and
          (eq? state 'normal)
          (context-indent stack standard-indent)))))

  (define (scheme-string-line-position source offset)
    (let loop ([index 0] [line 0] [line-start 0])
      (if
        (= index offset)
        (values line line-start (- offset line-start))
        (if
          (char=? (string-ref source index) #\newline)
          (loop (+ index 1) (+ line 1) (+ index 1))
          (loop (+ index 1) line line-start)))))

  (define (scheme-string-line-start source target-line)
    (let ([length (string-length source)])
      (let loop ([index 0] [line 0])
        (cond
          [(= line target-line) index]
          [(= index length) length]
          [(char=? (string-ref source index) #\newline)
           (loop (+ index 1) (+ line 1))]
          [else (loop (+ index 1) line)]))))

  (define (scheme-string-line-end source start)
    (let ([length (string-length source)])
      (let loop ([index start])
        (if
          (or
            (= index length)
            (char=? (string-ref source index) #\newline))
          index
          (loop (+ index 1))))))

  (define (scheme-string-leading-whitespace-end source start end)
    (let loop ([index start])
      (if
        (and
          (< index end)
          (memv (string-ref source index) '(#\space #\tab)))
        (loop (+ index 1))
        index)))

  (define (spaces count)
    (make-string count #\space))

  (define (scheme-reindent-entry source standard-indent)
    (unless (string? source)
      (assertion-violation
        'scheme-reindent-entry
        "source must be a string"
        source))
    (require-standard-indent 'scheme-reindent-entry standard-indent)
    (let ([length (string-length source)])
      (let loop ([start 0] [parts '()])
        (if
          (= start length)
          (apply string-append (reverse parts))
          (let* ([end (scheme-string-line-end source start)]
                 [whitespace-end
                   (scheme-string-leading-whitespace-end source start end)]
                 [prefix
                   (apply string-append (reverse parts))]
                 [indentation
                   (scheme-line-indent prefix standard-indent)]
                 [content
                   (substring source whitespace-end end)]
                 [line
                   (if
                     indentation
                     (string-append
                       (if (zero? (string-length content))
                           ""
                           (spaces indentation))
                       content)
                     (substring source start end))]
                 [terminated? (< end length)]
                 [part
                   (if terminated?
                       (string-append line "\n")
                       line)])
            (loop
              (if terminated? (+ end 1) end)
              (cons part parts))))))))
