(library (soda editor regexp)
  (export regexp-find-forward regexp-find-backward)
  (import (rnrs))

  (define (parse-regexp pattern)
    (let ([index 0] [size (string-length pattern)])
      (define (peek)
        (and (< index size) (string-ref pattern index)))
      (define (take!)
        (let ([character (peek)])
          (when character (set! index (+ index 1)))
          character))
      (define (escaped-character)
        (let ([character (take!)])
          (unless character
            (assertion-violation 'parse-regexp "trailing escape" pattern))
          (case character
            [(#\n) #\newline]
            [(#\t) #\tab]
            [(#\r) #\return]
            [else character])))
      (define (parse-class)
        (let ([negated? (and (eqv? (peek) #\^) (begin (take!) #t))])
          (let loop ([items '()])
            (let ([character (take!)])
              (cond
                [(not character)
                 (assertion-violation
                   'parse-regexp "unterminated character class" pattern)]
                [(char=? character #\])
                 (list 'class negated? (reverse items))]
                [else
                 (let* ([first
                          (if (char=? character #\\)
                              (escaped-character)
                              character)]
                        [range?
                          (and
                            (eqv? (peek) #\-)
                            (< (+ index 1) size)
                            (not (char=?
                                   (string-ref pattern (+ index 1))
                                   (integer->char 93))))])
                   (if range?
                       (begin
                         (take!)
                         (let ([last (take!)])
                           (loop
                             (cons
                               (cons
                                 first
                                 (if (char=? last #\\)
                                     (escaped-character)
                                     last))
                               items))))
                       (loop (cons first items))))])))))
      (define (parse-atom)
        (let ([character (take!)])
          (cond
            [(not character) #f]
            [(char=? character #\.) '(any)]
            [(char=? character #\^) '(bol)]
            [(char=? character #\$) '(eol)]
            [(char=? character #\[) (parse-class)]
            [(char=? character #\\)
             (list 'literal (escaped-character))]
            [(char=? character #\()
             (let ([expression (parse-alternation)])
               (unless (eqv? (take!) #\))
                 (assertion-violation
                   'parse-regexp "unterminated group" pattern))
               expression)]
            [else (list 'literal character)])))
      (define (parse-piece)
        (let ([atom (parse-atom)])
          (if
            (not atom)
            #f
            (case (peek)
              [(#\*) (take!) (list 'repeat atom 0 #f)]
              [(#\+) (take!) (list 'repeat atom 1 #f)]
              [(#\?) (take!) (list 'repeat atom 0 1)]
              [else atom]))))
      (define (parse-sequence)
        (let loop ([nodes '()])
          (if
            (or (not (peek))
                (memv (peek) '(#\| #\))))
            (cons 'sequence (reverse nodes))
            (loop (cons (parse-piece) nodes)))))
      (define (parse-alternation)
        (let loop ([branches (list (parse-sequence))])
          (if (eqv? (peek) #\|)
              (begin
                (take!)
                (loop (cons (parse-sequence) branches)))
              (if (null? (cdr branches))
                  (car branches)
                  (cons 'alternation (reverse branches))))))
      (let ([result (parse-alternation)])
        (unless (= index size)
          (assertion-violation 'parse-regexp "unexpected closing group" pattern))
        result)))

  (define (class-matches? node character)
    (let* ([negated? (cadr node)]
           [matched?
             (exists
               (lambda (item)
                 (if (pair? item)
                     (and
                       (char<=? (car item) character)
                       (char<=? character (cdr item)))
                     (char=? item character)))
               (caddr node))])
      (if negated? (not matched?) matched?)))

  (define (match-node node characters position)
    (let ([size (vector-length characters)])
      (case (car node)
        [(literal)
         (if
           (and (< position size)
                (char=? (vector-ref characters position) (cadr node)))
           (list (+ position 1)) '())]
        [(any)
         (if
           (and (< position size)
                (not (char=?
                       (vector-ref characters position) #\newline)))
           (list (+ position 1)) '())]
        [(class)
         (if
           (and (< position size)
                (class-matches?
                  node (vector-ref characters position)))
           (list (+ position 1)) '())]
        [(bol)
         (if
           (or (zero? position)
               (char=?
                 (vector-ref characters (- position 1)) #\newline))
           (list position) '())]
        [(eol)
         (if
           (or (= position size)
               (char=? (vector-ref characters position) #\newline))
           (list position) '())]
        [(alternation)
         (apply append
           (map
             (lambda (branch)
               (match-node branch characters position))
             (cdr node)))]
        [(sequence)
         (let loop ([nodes (cdr node)] [positions (list position)])
           (if
             (or (null? nodes) (null? positions))
             positions
             (loop
               (cdr nodes)
               (apply append
                 (map
                   (lambda (current)
                     (match-node (car nodes) characters current))
                   positions)))))]
        [(repeat)
         (let ([body (cadr node)] [minimum (caddr node)] [maximum (cadddr node)])
           (let loop ([count 0]
                      [frontier (list position)]
                      [accepted '()])
             (let ([accepted
                     (if (>= count minimum)
                         (append frontier accepted)
                         accepted)])
               (if
                 (or (null? frontier)
                     (and maximum (= count maximum)))
                 accepted
                 (let ([next
                         (apply append
                           (map
                             (lambda (current)
                               (filter
                                 (lambda (end) (> end current))
                                 (match-node body characters current)))
                             frontier))])
                   (loop (+ count 1) next accepted))))))]
        [else
         (assertion-violation 'match-node "invalid regexp node" node)])))

  (define (string-byte-offsets value)
    (let* ([size (string-length value)]
           [offsets (make-vector (+ size 1) 0)])
      (let loop ([index 0] [offset 0])
        (vector-set! offsets index offset)
        (if (= index size)
            offsets
            (loop
              (+ index 1)
              (+ offset
                 (bytevector-length
                   (string->utf8
                     (string (string-ref value index))))))))))

  (define (byte->character-index offsets byte-offset)
    (let loop ([index 0])
      (if
        (or (= index (- (vector-length offsets) 1))
            (>= (vector-ref offsets index) byte-offset))
        index
        (loop (+ index 1)))))

  (define (find-match pattern value byte-start byte-end backward?)
    (let* ([ast (parse-regexp pattern)]
           [characters (list->vector (string->list value))]
           [offsets (string-byte-offsets value)]
           [start (byte->character-index offsets byte-start)]
           [end (byte->character-index offsets byte-end)])
      (let loop ([position (if backward? end start)] [best #f])
        (if
          (if backward? (< position start) (> position end))
          best
          (let* ([ends
                   (filter
                     (lambda (match-end) (<= match-end end))
                     (match-node ast characters position))]
                 [match-end
                   (and (pair? ends) (apply max ends))]
                 [match
                   (and match-end
                        (cons
                          (vector-ref offsets position)
                          (vector-ref offsets match-end)))])
            (if
              match
              match
              (loop
                (if backward? (- position 1) (+ position 1))
                (or match best))))))))

  (define (regexp-find-forward pattern value start end)
    (find-match pattern value start end #f))

  (define (regexp-find-backward pattern value start end)
    (find-match pattern value start end #t)))
