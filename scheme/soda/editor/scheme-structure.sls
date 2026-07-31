(library (soda editor scheme-structure)
  (export make-scheme-structure-index)
  (import (rnrs)
          (soda document)
          (soda editor scheme-semantics)
          (soda editor structure))

  (define (token-property token)
    (let ([value (scheme-lexical-token-value token)])
      (if value
          (list (cons 'spelling value))
          '())))

  (define (atom-roles kind)
    (case kind
      [(string) '(sexp string text)]
      [(comment) '(comment text)]
      [else '(sexp atom)]))

  (define (make-token-thing token depth)
    (let* ([kind (scheme-lexical-token-kind token)]
           [start (scheme-lexical-token-start token)]
           [end (scheme-lexical-token-end token)]
           [quoted?
             (and
               (eq? kind 'string)
               (< start end))]
           [inner-start (if quoted? (+ start 1) start)]
           [inner-end
             (if
               (and quoted? (< inner-start end))
               (- end 1)
               end)])
      (make-structural-thing
        (atom-roles kind)
        start
        end
        (min inner-start end)
        (max (min inner-start end) inner-end)
        depth
        kind
        (token-property token))))

  (define (make-scheme-structure-index snapshot)
    (unless (snapshot? snapshot)
      (assertion-violation
        'make-scheme-structure-index
        "expected a document snapshot"
        snapshot))
    (let* ([text (snapshot-text snapshot)]
           [bytes
             (dynamic-wind
               (lambda () #f)
               (lambda () (text->bytevector text))
               (lambda () (text-close! text)))]
           [size (bytevector-length bytes)]
           [tokens
             (list->vector
               (scheme-lexical-tokenize bytes))]
           [limit (vector-length tokens)])
      (define (token-at index)
        (vector-ref tokens index))

      (define (thing-spelling thing)
        (let ([entry (assq 'spelling
                       (structural-thing-properties thing))])
          (and entry (cdr entry))))

      (define (list-roles depth)
        (if (zero? depth)
            '(sexp list defun)
            '(sexp list)))

      (define (parse-list open-index depth)
        (let* ([open (token-at open-index)]
               [start (scheme-lexical-token-start open)]
               [inner-start (scheme-lexical-token-end open)])
          (let loop
            ([index (+ open-index 1)]
             [immediate '()]
             [nested '()])
            (cond
              [(= index limit)
               (let ([thing
                       (make-structural-thing
                         (list-roles depth)
                         start
                         size
                         inner-start
                         size
                         depth
                         'list
                         (append
                           (if (null? immediate)
                               '()
                               (list
                                 (cons
                                   'head
                                   (thing-spelling
                                     (car immediate)))))
                           '((complete? . #f))))])
                 (values limit thing (cons thing nested)))]
              [(eq?
                 (scheme-lexical-token-kind (token-at index))
                 'close)
               (let* ([close (token-at index)]
                      [end (scheme-lexical-token-end close)]
                      [thing
                        (make-structural-thing
                          (list-roles depth)
                          start
                          end
                          inner-start
                          (scheme-lexical-token-start close)
                          depth
                          'list
                          (append
                            (if (null? immediate)
                                '()
                                (list
                                  (cons
                                    'head
                                    (thing-spelling
                                      (car immediate)))))
                            '((complete? . #t))))])
                 (values
                   (+ index 1)
                   thing
                   (cons thing nested)))]
              [else
               (call-with-values
                 (lambda () (parse-datum index (+ depth 1)))
                 (lambda (next thing things)
                   (loop
                     next
                     (if
                       (and
                         thing
                         (structural-thing-has-role?
                           thing
                           'sexp))
                       (append immediate (list thing))
                       immediate)
                     (append nested things))))]))))

      (define (parse-prefix index depth)
        (let ([prefix (token-at index)])
          (if (= (+ index 1) limit)
              (let ([thing
                      (make-structural-thing
                        '(sexp)
                        (scheme-lexical-token-start prefix)
                        (scheme-lexical-token-end prefix)
                        (scheme-lexical-token-end prefix)
                        (scheme-lexical-token-end prefix)
                        depth
                        (scheme-lexical-token-kind prefix)
                        '((complete? . #f)))])
                (values (+ index 1) thing (list thing)))
              (call-with-values
                (lambda () (parse-datum (+ index 1) (+ depth 1)))
                (lambda (next child things)
                  (let* ([end
                           (if child
                               (structural-thing-end child)
                               (scheme-lexical-token-end prefix))]
                         [thing
                           (make-structural-thing
                             '(sexp)
                             (scheme-lexical-token-start prefix)
                             end
                             (scheme-lexical-token-end prefix)
                             end
                             depth
                             (scheme-lexical-token-kind prefix)
                             '())])
                    (values
                      next
                      thing
                      (cons thing things))))))))

      (define (parse-datum-comment index depth)
        (let ([prefix (token-at index)])
          (if (= (+ index 1) limit)
              (let ([thing
                      (make-structural-thing
                        '(comment text)
                        (scheme-lexical-token-start prefix)
                        (scheme-lexical-token-end prefix)
                        (scheme-lexical-token-start prefix)
                        (scheme-lexical-token-end prefix)
                        depth
                        'datum-comment
                        '((complete? . #f)))])
                (values (+ index 1) thing (list thing)))
              (call-with-values
                (lambda () (parse-datum (+ index 1) (+ depth 1)))
                (lambda (next child things)
                  (let* ([end
                           (if child
                               (structural-thing-end child)
                               (scheme-lexical-token-end prefix))]
                         [thing
                           (make-structural-thing
                             '(comment text)
                             (scheme-lexical-token-start prefix)
                             end
                             (scheme-lexical-token-end prefix)
                             end
                             depth
                             'datum-comment
                             '())])
                    (values next thing (list thing))))))))

      (define (parse-datum index depth)
        (let* ([token (token-at index)]
               [kind (scheme-lexical-token-kind token)])
          (case kind
            [(open) (parse-list index depth)]
            [(prefix syntax-prefix)
             (parse-prefix index depth)]
            [(datum-comment)
             (parse-datum-comment index depth)]
            [(close)
             (values (+ index 1) #f '())]
            [else
             (let ([thing (make-token-thing token depth)])
               (values (+ index 1) thing (list thing)))])))

      (let loop ([index 0] [things '()])
        (if (= index limit)
            (make-structure-index
              (snapshot-document-id snapshot)
              (snapshot-revision snapshot)
              things)
            (call-with-values
              (lambda () (parse-datum index 0))
              (lambda (next thing parsed)
                (loop next (append things parsed)))))))))
