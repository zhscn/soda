(library (soda editor regexp)
  (export regexp-match?
          regexp-match-start
          regexp-match-end
          regexp-match-group-count
          regexp-match-group
          regexp-expand-replacement
          compile-regexp
          regexp-program?
          make-regexp-source
          regexp-source?
          regexp-source-value
          regexp-source-byte-length
          regexp-program-search-forward
          regexp-program-search-backward
          regexp-program-find-forward
          regexp-program-find-backward
          regexp-search-forward
          regexp-search-backward
          regexp-find-forward
          regexp-find-backward)
  (import (rnrs))

  (define-record-type
    (regexp-match %make-regexp-match regexp-match?)
    (fields start end groups))

  (define-record-type
    (regexp-program %make-regexp-program regexp-program?)
    (fields pattern ast group-count))

  (define-record-type
    (regexp-source %make-regexp-source regexp-source?)
    (fields value characters offsets byte-length))

  (define (regexp-match-group-count match)
    (unless (regexp-match? match)
      (assertion-violation
        'regexp-match-group-count "expected a regexp match" match))
    (- (vector-length (regexp-match-groups match)) 1))

  (define (regexp-match-group match index)
    (unless (and (regexp-match? match)
                 (integer? index)
                 (exact? index)
                 (<= 0 index)
                 (< index (vector-length (regexp-match-groups match))))
      (assertion-violation
        'regexp-match-group
        "invalid match or capture index"
        match
        index))
    (vector-ref (regexp-match-groups match) index))

  (define (byte-substring value range)
    (if (not range)
        ""
        (let* ([bytes (string->utf8 value)]
               [start (car range)]
               [end (cdr range)])
          (unless (and (<= 0 start end)
                       (<= end (bytevector-length bytes)))
            (assertion-violation
              'regexp-expand-replacement
              "capture range is outside the source"
              range))
          (let ([result (make-bytevector (- end start))])
            (bytevector-copy! bytes start result 0 (- end start))
            (utf8->string result)))))

  (define (regexp-expand-replacement template value match)
    (unless (and (string? template)
                 (string? value)
                 (regexp-match? match))
      (assertion-violation
        'regexp-expand-replacement
        "expected a template, source string, and regexp match"
        template
        value
        match))
    (let-values ([(port extract) (open-string-output-port)])
      (let ([persistent-case #f] [next-case #f] [size (string-length template)])
        (define (ascii-digit? character)
          (char<=? #\0 character #\9))
        (define (convert character mode)
          (case mode
            [(upper) (char-upcase character)]
            [(lower) (char-downcase character)]
            [else character]))
        (define (emit-string text)
          (for-each
            (lambda (character)
              (put-char
                port
                (convert
                  character
                  (or next-case persistent-case)))
              (when next-case (set! next-case #f)))
            (string->list text)))
        (define (emit-group index)
          (when (> index (regexp-match-group-count match))
            (assertion-violation
              'regexp-expand-replacement
              "capture reference is outside the pattern"
              index))
          (emit-string
            (byte-substring value (regexp-match-group match index))))
        (let loop ([index 0])
          (if (= index size)
              (extract)
              (let ([character (string-ref template index)])
                (if (not (char=? character #\\))
                    (begin
                      (emit-string (string character))
                      (loop (+ index 1)))
                    (begin
                      (when (= (+ index 1) size)
                        (assertion-violation
                          'regexp-expand-replacement
                          "trailing replacement escape"
                          template))
                      (let ([escaped (string-ref template (+ index 1))])
                        (cond
                          [(ascii-digit? escaped)
                           (let digits ([cursor (+ index 1)] [number 0])
                             (if (and (< cursor size)
                                      (ascii-digit?
                                        (string-ref template cursor)))
                                 (digits
                                   (+ cursor 1)
                                   (+
                                     (* number 10)
                                     (-
                                       (char->integer
                                         (string-ref template cursor))
                                       (char->integer #\0))))
                                 (begin
                                   (emit-group number)
                                   (loop cursor))))]
                          [(char=? escaped #\&)
                           (emit-group 0)
                           (loop (+ index 2))]
                          [(char=? escaped #\n)
                           (emit-string (string #\newline))
                           (loop (+ index 2))]
                          [(char=? escaped #\t)
                           (emit-string (string #\tab))
                           (loop (+ index 2))]
                          [(char=? escaped #\r)
                           (emit-string (string #\return))
                           (loop (+ index 2))]
                          [(char=? escaped #\u)
                           (set! next-case 'upper)
                           (loop (+ index 2))]
                          [(char=? escaped #\l)
                           (set! next-case 'lower)
                           (loop (+ index 2))]
                          [(char=? escaped #\U)
                           (set! persistent-case 'upper)
                           (set! next-case #f)
                           (loop (+ index 2))]
                          [(char=? escaped #\L)
                           (set! persistent-case 'lower)
                           (set! next-case #f)
                           (loop (+ index 2))]
                          [(char=? escaped #\E)
                           (set! persistent-case #f)
                           (set! next-case #f)
                           (loop (+ index 2))]
                          [else
                           (emit-string (string escaped))
                           (loop (+ index 2))]))))))))))

  (define (parse-regexp pattern)
    (unless (string? pattern)
      (assertion-violation 'parse-regexp "pattern must be a string" pattern))
    (let ([index 0]
          [size (string-length pattern)]
          [next-group 1])
      (define (peek)
        (and (< index size) (string-ref pattern index)))
      (define (take!)
        (let ([character (peek)])
          (when character (set! index (+ index 1)))
          character))
      (define (escaped-token in-class?)
        (let ([character (take!)])
          (unless character
            (assertion-violation 'parse-regexp "trailing escape" pattern))
          (case character
            [(#\n) (list 'literal #\newline)]
            [(#\t) (list 'literal #\tab)]
            [(#\r) (list 'literal #\return)]
            [(#\d) '(character-kind digit #t)]
            [(#\D) '(character-kind digit #f)]
            [(#\w) '(character-kind word #t)]
            [(#\W) '(character-kind word #f)]
            [(#\s) '(character-kind space #t)]
            [(#\S) '(character-kind space #f)]
            [(#\b)
             (if in-class?
                 (list 'literal (integer->char 8))
                 '(word-boundary #t))]
            [(#\B)
             (if in-class?
                 (list 'literal #\B)
                 '(word-boundary #f))]
            [else (list 'literal character)])))
      (define (class-token)
        (let ([character (take!)])
          (if (char=? character #\\)
              (escaped-token #t)
              (list 'literal character))))
      (define (parse-class)
        (let ([negated? (and (eqv? (peek) #\^) (begin (take!) #t))])
          (let loop ([items '()] [first? #t])
            (let ([character (peek)])
              (cond
                [(not character)
                 (assertion-violation
                   'parse-regexp "unterminated character class" pattern)]
                [(and (char=? character #\]) (not first?))
                 (take!)
                 (list 'class negated? (reverse items))]
                [else
                 (let* ((first (class-token))
                        (range?
                          (and
                            (eq? (car first) 'literal)
                            (eqv? (peek) #\-)
                            (< (+ index 1) size)
                            (not
                              (char=?
                                (string-ref pattern (+ index 1))
                                #\])))))
                   (if range?
                       (begin
                         (take!)
                         (let ([last (class-token)])
                           (unless (eq? (car last) 'literal)
                             (assertion-violation
                               'parse-regexp
                               "character class range requires literals"
                               pattern))
                           (loop
                             (cons
                               (list 'range (cadr first) (cadr last))
                               items)
                             #f)))
                       (loop (cons first items) #f)))])))))
      (define (parse-atom)
        (let ([character (take!)])
          (cond
            [(not character) #f]
            [(char=? character #\.) '(any)]
            [(char=? character #\^) '(bol)]
            [(char=? character #\$) '(eol)]
            [(char=? character #\[) (parse-class)]
            [(char=? character #\\) (escaped-token #f)]
            [(char=? character #\()
             (let* ([capturing?
                      (not
                        (and
                          (eqv? (peek) #\?)
                          (< (+ index 1) size)
                          (char=?
                            (string-ref pattern (+ index 1))
                            #\:)))]
                    [group
                      (and
                        capturing?
                        (let ([value next-group])
                          (set! next-group (+ next-group 1))
                          value))])
               (unless capturing?
                 (take!)
                 (take!))
               (let ([expression (parse-alternation)])
                 (unless (eqv? (take!) #\))
                   (assertion-violation
                     'parse-regexp "unterminated group" pattern))
                 (if group
                     (list 'group group expression)
                     expression)))]
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
            (or (not (peek)) (memv (peek) '(#\| #\))))
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
          (assertion-violation
            'parse-regexp "unexpected closing group" pattern))
        (cons result (- next-group 1)))))

  (define (word-character? character)
    (or (char-alphabetic? character)
        (char-numeric? character)
        (char=? character #\_)))

  (define (character-kind-matches? kind character)
    (case kind
      [(digit) (char-numeric? character)]
      [(word) (word-character? character)]
      [(space) (char-whitespace? character)]
      [else
       (assertion-violation
         'character-kind-matches? "unknown character kind" kind)]))

  (define (literal-matches? expected actual case-fold?)
    (if case-fold?
        (char-ci=? expected actual)
        (char=? expected actual)))

  (define (class-item-matches? item character case-fold?)
    (case (car item)
      [(literal) (literal-matches? (cadr item) character case-fold?)]
      [(range)
       (if case-fold?
           (and
             (char-ci<=? (cadr item) character)
             (char-ci<=? character (caddr item)))
           (and
             (char<=? (cadr item) character)
             (char<=? character (caddr item))))]
      [(character-kind)
       (eqv?
         (character-kind-matches? (cadr item) character)
         (caddr item))]
      [else
       (assertion-violation
         'class-item-matches? "invalid character class item" item)]))

  (define (class-matches? node character case-fold?)
    (let ([matched?
            (exists
              (lambda (item)
                (class-item-matches? item character case-fold?))
              (caddr node))])
      (if (cadr node) (not matched?) matched?)))

  (define-record-type match-state
    (fields position groups))

  (define (copy-groups groups)
    (vector-map (lambda (value) value) groups))

  (define (match-node node characters state case-fold?)
    (let ([position (match-state-position state)]
          [size (vector-length characters)])
      (case (car node)
        [(literal)
         (if (and (< position size)
                  (literal-matches?
                    (cadr node)
                    (vector-ref characters position)
                    case-fold?))
             (list
               (make-match-state
                 (+ position 1)
                 (match-state-groups state)))
             '())]
        [(any)
         (if (and (< position size)
                  (not
                    (char=?
                      (vector-ref characters position)
                      #\newline)))
             (list
               (make-match-state
                 (+ position 1)
                 (match-state-groups state)))
             '())]
        [(character-kind)
         (if (and (< position size)
                  (eqv?
                    (character-kind-matches?
                      (cadr node)
                      (vector-ref characters position))
                    (caddr node)))
             (list
               (make-match-state
                 (+ position 1)
                 (match-state-groups state)))
             '())]
        [(class)
         (if (and (< position size)
                  (class-matches?
                    node
                    (vector-ref characters position)
                    case-fold?))
             (list
               (make-match-state
                 (+ position 1)
                 (match-state-groups state)))
             '())]
        [(bol)
         (if (or (zero? position)
                 (char=?
                   (vector-ref characters (- position 1))
                   #\newline))
             (list state)
             '())]
        [(eol)
         (if (or (= position size)
                 (char=?
                   (vector-ref characters position)
                   #\newline))
             (list state)
             '())]
        [(word-boundary)
         (let ([boundary?
                 (not
                   (eqv?
                     (and (> position 0)
                          (word-character?
                            (vector-ref characters (- position 1))))
                     (and (< position size)
                          (word-character?
                            (vector-ref characters position)))))])
           (if (eqv? boundary? (cadr node)) (list state) '()))]
        [(group)
         (let ([group-index (cadr node)] [body (caddr node)])
           (map
             (lambda (result)
               (let ([groups (copy-groups (match-state-groups result))])
                 (vector-set!
                   groups
                   group-index
                   (cons position (match-state-position result)))
                 (make-match-state
                   (match-state-position result)
                   groups)))
             (match-node body characters state case-fold?)))]
        [(alternation)
         (apply append
           (map
             (lambda (branch)
               (match-node branch characters state case-fold?))
             (cdr node)))]
        [(sequence)
         (let loop ([nodes (cdr node)] [states (list state)])
           (if (or (null? nodes) (null? states))
               states
               (loop
                 (cdr nodes)
                 (apply append
                   (map
                     (lambda (current)
                       (match-node
                         (car nodes) characters current case-fold?))
                     states)))))]
        [(repeat)
         (let ([body (cadr node)]
               [minimum (caddr node)]
               [maximum (cadddr node)])
           (let loop ([count 0]
                      [frontier (list state)]
                      [accepted '()])
             (let ([accepted
                     (if (>= count minimum)
                         (append frontier accepted)
                         accepted)])
               (if (or (null? frontier)
                       (and maximum (= count maximum)))
                   accepted
                   (let ([next
                           (apply append
                             (map
                               (lambda (current)
                                 (filter
                                   (lambda (result)
                                     (>
                                       (match-state-position result)
                                       (match-state-position current)))
                                   (match-node
                                     body
                                     characters
                                     current
                                     case-fold?)))
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

  (define (compile-regexp pattern)
    (unless (string? pattern)
      (assertion-violation
        'compile-regexp "expected a regexp string" pattern))
    (let ([parsed (parse-regexp pattern)])
      (%make-regexp-program pattern (car parsed) (cdr parsed))))

  (define (make-regexp-source value)
    (unless (string? value)
      (assertion-violation
        'make-regexp-source "expected a source string" value))
    (let ([offsets (string-byte-offsets value)])
      (%make-regexp-source
        value
        (list->vector (string->list value))
        offsets
        (vector-ref offsets (- (vector-length offsets) 1)))))

  (define (byte->character-ceiling offsets byte-offset)
    (let loop ([index 0])
      (if (or (= index (- (vector-length offsets) 1))
              (>= (vector-ref offsets index) byte-offset))
          index
          (loop (+ index 1)))))

  (define (byte->character-floor offsets byte-offset)
    (let loop ([index 0])
      (if (or (= index (- (vector-length offsets) 1))
              (> (vector-ref offsets (+ index 1)) byte-offset))
          index
          (loop (+ index 1)))))

  (define (capture->bytes capture offsets)
    (and capture
         (cons
           (vector-ref offsets (car capture))
           (vector-ref offsets (cdr capture)))))

  (define (best-state states)
    (fold-left
      (lambda (best state)
        (if (or (not best)
                (> (match-state-position state)
                   (match-state-position best)))
            state
            best))
      #f
      states))

  (define (match-at ast group-count characters offsets position end case-fold?)
    (let* ([groups (make-vector (+ group-count 1) #f)]
           [state
             (best-state
               (filter
                 (lambda (candidate)
                   (<= (match-state-position candidate) end))
                 (match-node
                   ast
                   characters
                   (make-match-state position groups)
                   case-fold?)))])
      (and
        state
        (let ([byte-groups
                (vector-map
                  (lambda (capture) (capture->bytes capture offsets))
                  (match-state-groups state))]
              [start-byte (vector-ref offsets position)]
              [end-byte
                (vector-ref offsets (match-state-position state))])
          (vector-set! byte-groups 0 (cons start-byte end-byte))
          (%make-regexp-match start-byte end-byte byte-groups)))))

  (define (program-search
            program source byte-start byte-end backward? case-fold?)
    (unless (and (regexp-program? program)
                 (regexp-source? source)
                 (integer? byte-start)
                 (exact? byte-start)
                 (integer? byte-end)
                 (exact? byte-end)
                 (<= 0 byte-start byte-end)
                 (<= byte-end (regexp-source-byte-length source)))
      (assertion-violation 'regexp-search
        "invalid program, source, or byte range"
        program source byte-start byte-end))
    (let* ([ast (regexp-program-ast program)]
           [group-count (regexp-program-group-count program)]
           [characters (regexp-source-characters source)]
           [offsets (regexp-source-offsets source)]
           [start (byte->character-ceiling offsets byte-start)]
           [end (byte->character-floor offsets byte-end)])
      (if backward?
          (let loop ([position start] [best #f])
            (if (> position end)
                best
                (let ([candidate
                        (match-at
                          ast
                          group-count
                          characters
                          offsets
                          position
                          end
                          case-fold?)])
                  (loop
                    (+ position 1)
                    (if
                      (and
                        candidate
                        (or
                          (not best)
                          (> (regexp-match-end candidate)
                             (regexp-match-end best))
                          (and
                            (= (regexp-match-end candidate)
                               (regexp-match-end best))
                            (< (regexp-match-start candidate)
                               (regexp-match-start best)))))
                      candidate
                      best)))))
          (let loop ([position start])
            (and
              (<= position end)
              (or
                (match-at
                  ast
                  group-count
                  characters
                  offsets
                  position
                  end
                  case-fold?)
                (loop (+ position 1))))))))

  (define regexp-program-search-forward
    (case-lambda
      [(program source start end)
       (program-search program source start end #f #f)]
      [(program source start end case-fold?)
       (program-search program source start end #f case-fold?)]))

  (define regexp-program-search-backward
    (case-lambda
      [(program source start end)
       (program-search program source start end #t #f)]
      [(program source start end case-fold?)
       (program-search program source start end #t case-fold?)]))

  (define regexp-program-find-forward
    (case-lambda
      [(program source start end)
       (let ([match
               (regexp-program-search-forward program source start end)])
         (and match (regexp-match-group match 0)))]
      [(program source start end case-fold?)
       (let ([match
               (regexp-program-search-forward
                 program source start end case-fold?)])
         (and match (regexp-match-group match 0)))]))

  (define regexp-program-find-backward
    (case-lambda
      [(program source start end)
       (let ([match
               (regexp-program-search-backward program source start end)])
         (and match (regexp-match-group match 0)))]
      [(program source start end case-fold?)
       (let ([match
               (regexp-program-search-backward
                 program source start end case-fold?)])
         (and match (regexp-match-group match 0)))]))

  (define regexp-search-forward
    (case-lambda
      [(pattern value start end)
       (regexp-program-search-forward
         (compile-regexp pattern) (make-regexp-source value) start end)]
      [(pattern value start end case-fold?)
       (regexp-program-search-forward
         (compile-regexp pattern)
         (make-regexp-source value)
         start end case-fold?)]))

  (define regexp-search-backward
    (case-lambda
      [(pattern value start end)
       (regexp-program-search-backward
         (compile-regexp pattern) (make-regexp-source value) start end)]
      [(pattern value start end case-fold?)
       (regexp-program-search-backward
         (compile-regexp pattern)
         (make-regexp-source value)
         start end case-fold?)]))

  (define regexp-find-forward
    (case-lambda
      [(pattern value start end)
       (let ([match (regexp-search-forward pattern value start end)])
         (and match (regexp-match-group match 0)))]
      [(pattern value start end case-fold?)
       (let ([match
               (regexp-search-forward
                 pattern value start end case-fold?)])
         (and match (regexp-match-group match 0)))]))

  (define regexp-find-backward
    (case-lambda
      [(pattern value start end)
       (let ([match (regexp-search-backward pattern value start end)])
         (and match (regexp-match-group match 0)))]
      [(pattern value start end case-fold?)
       (let ([match
               (regexp-search-backward
                 pattern value start end case-fold?)])
         (and match (regexp-match-group match 0)))])))
