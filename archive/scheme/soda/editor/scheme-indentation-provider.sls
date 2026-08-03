(library (soda editor scheme-indentation-provider)
  (export scheme-indentation-provider)
  (import (rnrs)
          (soda document)
          (soda editor indentation-protocol)
          (soda editor scheme-indentation))

  (define-record-type scheme-indentation-context
    (fields
      width
      (mutable revision)
      (mutable lines)))

  (define (positive-width setting-ref)
    (let ([value (setting-ref 'indent-width 2)])
      (if
        (and
          (integer? value)
          (exact? value)
          (positive? value))
        value
        2)))

  (define (normalized-line-indents source width)
    (let* ([normalized
             (scheme-reindent-entry source width)]
           [length (string-length normalized)])
      (let loop
        ([index 0]
         [indent 0]
         [leading? #t]
         [lines '()])
        (cond
          [(= index length)
           (list->vector
             (reverse (cons indent lines)))]
          [(char=? (string-ref normalized index) #\newline)
           (loop
             (+ index 1)
             0
             #t
             (cons indent lines))]
          [(and
             leading?
             (char=? (string-ref normalized index) #\space))
           (loop (+ index 1) (+ indent 1) #t lines)]
          [else
           (loop (+ index 1) indent #f lines)]))))

  (define (ensure-normalized-lines! context snapshot)
    (unless
      (and
        (scheme-indentation-context-revision context)
        (=
          (scheme-indentation-context-revision context)
          (snapshot-revision snapshot)))
      (let ([text (snapshot-text snapshot)])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (scheme-indentation-context-lines-set!
              context
              (normalized-line-indents
                (utf8->string (text->bytevector text))
                (scheme-indentation-context-width context)))
            (scheme-indentation-context-revision-set!
              context
              (snapshot-revision snapshot)))
          (lambda () (text-close! text))))))

  (define scheme-indentation-provider
    (make-indentation-provider
      (lambda (setting-ref)
        (make-scheme-indentation-context
          (positive-width setting-ref)
          #f
          #f))
      (lambda (context syntax-session snapshot line)
        (ensure-normalized-lines! context snapshot)
        (let ([lines
                (scheme-indentation-context-lines context)])
          (and
            (< line (vector-length lines))
            (make-bytevector
              (vector-ref lines line)
              32))))
      (lambda (context) #f))))
