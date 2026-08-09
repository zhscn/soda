(library (soda packages file-format)
  (export file-format?
          file-format-encoding
          file-format-newline
          file-format-final-newline?
          file-format-bom?
          make-default-file-format
          decode-file-contents
          encode-file-contents)
  (import (rnrs))

  ;; Documents use UTF-8 with LF line separators.  FileFormat records the
  ;; external representation needed to reproduce a visited resource.  Mixed
  ;; line endings retain their ordered spelling so an unchanged document has
  ;; a byte-for-byte newline round trip.
  (define-record-type
    (file-format %make-file-format file-format?)
    (fields encoding newline final-newline? bom? endings))

  (define (make-default-file-format)
    (%make-file-format 'utf-8 'lf #f #f '()))

  (define (utf8-continuation? byte)
    (and (>= byte #x80) (<= byte #xbf)))

  (define (valid-utf8? bytes)
    (let ([size (bytevector-length bytes)])
      (let loop ([index 0])
        (if (= index size)
            #t
            (let ([first (bytevector-u8-ref bytes index)])
              (cond
                [(<= first #x7f) (loop (+ index 1))]
                [(and (>= first #xc2) (<= first #xdf)
                      (< (+ index 1) size)
                      (utf8-continuation? (bytevector-u8-ref bytes (+ index 1))))
                 (loop (+ index 2))]
                [(and (>= first #xe0) (<= first #xef)
                      (< (+ index 2) size)
                      (let ([second (bytevector-u8-ref bytes (+ index 1))]
                            [third (bytevector-u8-ref bytes (+ index 2))])
                        (and (utf8-continuation? second)
                             (utf8-continuation? third)
                             (or (not (= first #xe0)) (>= second #xa0))
                             (or (not (= first #xed)) (<= second #x9f)))))
                 (loop (+ index 3))]
                [(and (>= first #xf0) (<= first #xf4)
                      (< (+ index 3) size)
                      (let ([second (bytevector-u8-ref bytes (+ index 1))]
                            [third (bytevector-u8-ref bytes (+ index 2))]
                            [fourth (bytevector-u8-ref bytes (+ index 3))])
                        (and (utf8-continuation? second)
                             (utf8-continuation? third)
                             (utf8-continuation? fourth)
                             (or (not (= first #xf0)) (>= second #x90))
                             (or (not (= first #xf4)) (<= second #x8f)))))
                 (loop (+ index 4))]
                [else #f]))))))

  (define (utf8-bom? bytes)
    (and (>= (bytevector-length bytes) 3)
         (= (bytevector-u8-ref bytes 0) #xef)
         (= (bytevector-u8-ref bytes 1) #xbb)
         (= (bytevector-u8-ref bytes 2) #xbf)))

  (define (bytevector-slice bytes from to)
    (let ([result (make-bytevector (- to from))])
      (bytevector-copy! bytes from result 0 (- to from))
      result))

  (define (list->bytes values)
    (let ([result (make-bytevector (length values))])
      (let loop ([remaining values] [index 0])
        (unless (null? remaining)
          (bytevector-u8-set! result index (car remaining))
          (loop (cdr remaining) (+ index 1))))
      result))

  (define (decode-file-contents bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'decode-file-contents
                           "expected file contents as a bytevector" bytes))
    (let* ([bom? (utf8-bom? bytes)]
           [payload (if bom? (bytevector-slice bytes 3 (bytevector-length bytes))
                        (bytevector-copy bytes))])
      (unless (valid-utf8? payload)
        (assertion-violation
          'decode-file-contents
          "file is not valid UTF-8; explicit transcoding is required"))
      (let loop ([index 0] [output '()] [endings '()])
        (if (= index (bytevector-length payload))
            (let* ([ordered (reverse endings)]
                   [has-lf? (memq 'lf ordered)]
                   [has-crlf? (memq 'crlf ordered)]
                   [newline
                    (cond [(and has-lf? has-crlf?) 'mixed]
                          [has-crlf? 'crlf]
                          [else 'lf])]
                   [final?
                    (and (pair? ordered)
                         (let ([size (bytevector-length payload)])
                           (= (bytevector-u8-ref payload (- size 1)) #x0a)))])
              (values
                (list->bytes (reverse output))
                (%make-file-format 'utf-8 newline final? bom? ordered)))
            (let ([byte (bytevector-u8-ref payload index)])
              (if (and (= byte #x0d)
                       (< (+ index 1) (bytevector-length payload))
                       (= (bytevector-u8-ref payload (+ index 1)) #x0a))
                  (loop (+ index 2) (cons #x0a output) (cons 'crlf endings))
                  (loop (+ index 1) (cons byte output)
                        (if (= byte #x0a) (cons 'lf endings) endings))))))))

  (define (require-policy who value allowed)
    (unless (memq value allowed)
      (assertion-violation who "invalid file format policy" value allowed)))

  (define (effective-ending format newline-policy index)
    (case newline-policy
      [(lf) 'lf]
      [(crlf) 'crlf]
      [else
       (let loop ([remaining (file-format-endings format)] [position index])
         (cond [(pair? remaining)
                (if (zero? position) (car remaining)
                    (loop (cdr remaining) (- position 1)))]
               [(eq? (file-format-newline format) 'crlf) 'crlf]
               [else 'lf]))]))

  (define (encode-file-contents contents format newline-policy bom-policy final-policy)
    (unless (and (bytevector? contents) (file-format? format))
      (assertion-violation 'encode-file-contents
                           "expected normalized contents and FileFormat"
                           contents format))
    (unless (valid-utf8? contents)
      (assertion-violation 'encode-file-contents
                           "document contents are not valid UTF-8"))
    (require-policy 'encode-file-contents newline-policy '(preserve lf crlf))
    (require-policy 'encode-file-contents bom-policy '(preserve yes no))
    (require-policy 'encode-file-contents final-policy '(preserve yes no))
    (let* ([size (bytevector-length contents)]
           [has-final? (and (positive? size)
                            (= (bytevector-u8-ref contents (- size 1)) #x0a))]
           [want-final?
            (case final-policy
              [(yes) #t]
              [(no) #f]
              [else has-final?])]
           [limit (if (and has-final? (not want-final?)) (- size 1) size)]
           [bom? (case bom-policy
                   [(yes) #t]
                   [(no) #f]
                   [else (file-format-bom? format)])])
      (let loop ([index 0] [line 0]
                 [output (if bom? (reverse '(#xef #xbb #xbf)) '())]
                 [written-endings '()])
        (if (= index limit)
            (let* ([ending (effective-ending format newline-policy line)]
                   [with-final
                    (if (and want-final? (not has-final?))
                        (if (eq? ending 'crlf)
                            (cons #x0a (cons #x0d output))
                            (cons #x0a output))
                        output)]
                   [endings
                    (reverse
                      (if (and want-final? (not has-final?))
                          (cons ending written-endings)
                          written-endings))]
                   [newline
                    (if (eq? newline-policy 'preserve)
                        (file-format-newline format)
                        newline-policy)])
              (values
                (list->bytes (reverse with-final))
                (%make-file-format 'utf-8 newline want-final? bom? endings)))
            (let ([byte (bytevector-u8-ref contents index)])
              (if (= byte #x0a)
                  (let ([ending (effective-ending format newline-policy line)])
                    (if (eq? ending 'crlf)
                        (loop (+ index 1) (+ line 1)
                              (cons #x0a (cons #x0d output))
                              (cons ending written-endings))
                        (loop (+ index 1) (+ line 1)
                              (cons #x0a output)
                              (cons ending written-endings))))
                  (loop (+ index 1) line (cons byte output) written-endings)))))))
)
