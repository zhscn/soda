(library (soda editor delimiter-structure)
  (export make-delimiter-structure-index)
  (import (rnrs)
          (soda document)
          (soda editor structure))

  (define (make-delimiter-structure-index snapshot pairs)
    (unless (snapshot? snapshot)
      (assertion-violation
        'make-delimiter-structure-index
        "expected a document snapshot"
        snapshot))
    (unless
      (and
        (list? pairs)
        (for-all
          (lambda (entry)
            (and
              (pair? entry)
              (char? (car entry))
              (char? (cdr entry))))
          pairs))
      (assertion-violation
        'make-delimiter-structure-index
        "pairs must contain character pairs"
        pairs))
    (let* ([text (snapshot-text snapshot)]
           [bytes
             (dynamic-wind
               (lambda () #f)
               (lambda () (text->bytevector text))
               (lambda () (text-close! text)))]
           [size (bytevector-length bytes)])
      (define (ascii-character index)
        (let ([byte (bytevector-u8-ref bytes index)])
          (and (< byte 128) (integer->char byte))))

      (define (open-entry character)
        (and character (assv character pairs)))

      (define (close-character? character)
        (and
          character
          (find
            (lambda (entry)
              (char=? character (cdr entry)))
            pairs)))

      (define (separator? index)
        (let ([character (ascii-character index)])
          (and
            character
            (or
              (char-whitespace? character)
              (char=? character #\")
              (open-entry character)
              (close-character? character)))))

      (define (parse-string index depth)
        (let loop ([cursor (+ index 1)] [escaped? #f])
          (cond
            [(= cursor size)
             (let ([thing
                     (make-structural-thing
                       '(sexp string text)
                       index
                       size
                       (+ index 1)
                       size
                       depth
                       'string
                       '((complete? . #f)))])
               (values size thing (list thing)))]
            [escaped?
             (loop (+ cursor 1) #f)]
            [(= (bytevector-u8-ref bytes cursor) 92)
             (loop (+ cursor 1) #t)]
            [(= (bytevector-u8-ref bytes cursor) 34)
             (let* ([end (+ cursor 1)]
                    [thing
                      (make-structural-thing
                        '(sexp string text)
                        index
                        end
                        (+ index 1)
                        cursor
                        depth
                        'string
                        '((complete? . #t)))])
               (values end thing (list thing)))]
            [else (loop (+ cursor 1) #f)])))

      (define (parse-list index depth close)
        (let loop ([cursor (+ index 1)] [nested '()])
          (cond
            [(= cursor size)
             (let ([thing
                     (make-structural-thing
                       (if (zero? depth)
                           '(sexp list defun)
                           '(sexp list))
                       index
                       size
                       (+ index 1)
                       size
                       depth
                       'list
                       '((complete? . #f)))])
               (values size thing (cons thing nested)))]
            [(let ([character (ascii-character cursor)])
               (and character (char=? character close)))
             (let* ([end (+ cursor 1)]
                    [thing
                      (make-structural-thing
                        (if (zero? depth)
                            '(sexp list defun)
                            '(sexp list))
                        index
                        end
                        (+ index 1)
                        cursor
                        depth
                        'list
                        '((complete? . #t)))])
               (values end thing (cons thing nested)))]
            [else
             (call-with-values
               (lambda () (parse-datum cursor (+ depth 1)))
               (lambda (next thing things)
                 (loop
                   (if (= next cursor) (+ cursor 1) next)
                   (append nested things))))])))

      (define (parse-atom index depth)
        (let loop ([cursor (+ index 1)])
          (if
            (or (= cursor size) (separator? cursor))
            (let ([thing
                    (make-structural-thing
                      '(sexp atom)
                      index
                      cursor
                      index
                      cursor
                      depth
                      'atom
                      '())])
              (values cursor thing (list thing)))
            (loop (+ cursor 1)))))

      (define (parse-datum index depth)
        (let ([character (ascii-character index)])
          (cond
            [(and character (char-whitespace? character))
             (values (+ index 1) #f '())]
            [(and character (char=? character #\"))
             (parse-string index depth)]
            [(open-entry character)
             =>
             (lambda (entry)
               (parse-list index depth (cdr entry)))]
            [(close-character? character)
             (values (+ index 1) #f '())]
            [else (parse-atom index depth)])))

      (let loop ([index 0] [things '()])
        (if (= index size)
            (make-structure-index
              (snapshot-document-id snapshot)
              (snapshot-revision snapshot)
              things)
            (call-with-values
              (lambda () (parse-datum index 0))
              (lambda (next thing parsed)
                (loop next (append things parsed)))))))))
