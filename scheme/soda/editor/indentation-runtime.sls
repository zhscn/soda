(library (soda editor indentation-runtime)
  (export buffer-indentation-provider
          buffer-reindent-range!
          buffer-reindent-line!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor indentation-protocol)
          (soda editor language))

  (define (buffer-indentation-provider buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-indentation-provider
        "expected a buffer"
        buffer))
    (let ([profile (buffer-language-profile buffer)])
      (and profile (language-profile-indent profile))))

  (define (line-whitespace-end text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (if
          (and
            (< offset end)
            (memv (text-byte-at text offset) '(9 32)))
          (loop (+ offset 1))
          offset))))

  (define (bytevector-equal? left right)
    (and
      (= (bytevector-length left)
         (bytevector-length right))
      (let loop ([index 0])
        (or
          (= index (bytevector-length left))
          (and
            (= (bytevector-u8-ref left index)
               (bytevector-u8-ref right index))
            (loop (+ index 1)))))))

  (define (range-lines text start end)
    (let* ([first (car (text-position text start))]
           [last-offset
             (if (> end start) (- end 1) end)]
           [last (car (text-position text last-offset))])
      (values first last)))

  (define (collect-replacements
            provider
            context
            session
            snapshot
            text
            first
            last)
    (let loop ([line first] [replacements '()])
      (if (> line last)
          replacements
          (let* ([start (text-line-start text line)]
                 [content-end
                   (text-line-content-end text line)]
                 [whitespace-end
                   (line-whitespace-end text line)])
            (if (= whitespace-end content-end)
                (loop (+ line 1) replacements)
                (let ([indentation
                        (indentation-provider-line
                          provider
                          context
                          session
                          snapshot
                          line)])
                  (if
                    (or
                      (not indentation)
                      (bytevector-equal?
                        indentation
                        (text-subbytevector
                          text start whitespace-end)))
                    (loop (+ line 1) replacements)
                    (loop
                      (+ line 1)
                      (cons
                        (list
                          start
                          whitespace-end
                          indentation)
                        replacements)))))))))

  (define (apply-replacements! buffer replacements)
    (if (null? replacements)
        0
        (let ([change #f])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (call-with-values
                (lambda ()
                  (call-with-buffer-transaction
                    buffer
                    (lambda (transaction)
                      (for-each
                        (lambda (replacement)
                          (transaction-replace!
                            transaction
                            (car replacement)
                            (cadr replacement)
                            (caddr replacement)))
                        replacements)
                      (length replacements))))
                (lambda (count committed-change)
                  (set! change committed-change)
                  count)))
            (lambda ()
              (when change (change-close! change)))))))

  (define (buffer-reindent-range! buffer start end)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-reindent-range!
        "expected a buffer"
        buffer))
    (let ([provider (buffer-indentation-provider buffer)])
      (if
        (not provider)
        #f
        (let ([snapshot
                (document-snapshot
                  (buffer-document buffer))]
              [context #f]
              [opened? #f])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ([text (snapshot-text snapshot)])
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (unless
                      (and
                        (integer? start)
                        (exact? start)
                        (integer? end)
                        (exact? end)
                        (<= 0 start end (text-size text)))
                      (assertion-violation
                        'buffer-reindent-range!
                        "invalid indentation range"
                        start
                        end))
                    (set!
                      context
                      (indentation-provider-open
                        provider
                        (lambda (key default)
                          (buffer-setting-ref
                            buffer key default))))
                    (set! opened? #t)
                    (call-with-values
                      (lambda ()
                        (range-lines text start end))
                      (lambda (first last)
                        (apply-replacements!
                          buffer
                          (collect-replacements
                            provider
                            context
                            (buffer-language-session buffer)
                            snapshot
                            text
                            first
                            last)))))
                  (lambda () (text-close! text)))))
            (lambda ()
              (when opened?
                (indentation-provider-close!
                  provider context))
              (snapshot-close! snapshot)))))))

  (define (buffer-reindent-line! buffer offset)
    (let ([snapshot
            (document-snapshot
              (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let* ([line (car (text-position text offset))]
                       [start (text-line-start text line)]
                       [end (text-line-content-end text line)])
                  (buffer-reindent-range!
                    buffer start end)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot))))))
