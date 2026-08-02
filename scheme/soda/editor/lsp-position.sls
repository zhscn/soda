(library (soda editor lsp-position)
  (export lsp-text-map?
          lsp-text-map-revision
          lsp-buffer-text-map
          lsp-text-map-position-at
          lsp-text-map-offset-at
          lsp-buffer-position-at
          lsp-buffer-offset-at)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor buffer)
          (soda editor lsp-protocol))

  (define-record-type lsp-text-map
    (fields buffer-id
            revision
            text
            line-character-starts
            line-byte-starts
            byte-size))

  (define text-map-cache (make-weak-eq-hashtable))

  (define (utf8-length character)
    (bytevector-length (string->utf8 (string character))))

  (define (utf16-width character)
    (if (> (char->integer character) #xffff) 2 1))

  (define (crlf? text index)
    (and
      (char=? (string-ref text index) #\return)
      (< (+ index 1) (string-length text))
      (char=? (string-ref text (+ index 1)) #\newline)))

  (define (reverse-list->vector values)
    (list->vector (reverse values)))

  (define (buffer-snapshot-string buffer)
    (buffer-string-range buffer 0 (buffer-byte-size buffer)))

  (define (build-text-map buffer)
    (let* ([revision (buffer-revision buffer)]
           [source (buffer-snapshot-string buffer)]
           [length (string-length source)])
      (let loop
        ([index 0]
         [byte 0]
         [character-starts '(0)]
         [byte-starts '(0)])
        (cond
          [(= index length)
           (make-lsp-text-map
             (buffer-id buffer)
             revision
             source
             (reverse-list->vector character-starts)
             (reverse-list->vector byte-starts)
             byte)]
          [(crlf? source index)
           (loop
             (+ index 2)
             (+ byte 2)
             (cons (+ index 2) character-starts)
             (cons (+ byte 2) byte-starts))]
          [else
           (let* ([character (string-ref source index)]
                  [next-index (+ index 1)]
                  [next-byte (+ byte (utf8-length character))])
             (if (char=? character #\newline)
                 (loop
                   next-index
                   next-byte
                   (cons next-index character-starts)
                   (cons next-byte byte-starts))
                 (loop
                   next-index
                   next-byte
                   character-starts
                   byte-starts)))]))))

  (define (lsp-buffer-text-map buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'lsp-buffer-text-map "expected a Buffer" buffer))
    (let ([cached (hashtable-ref text-map-cache buffer #f)])
      (if
        (and
          cached
          (= (lsp-text-map-revision cached) (buffer-revision buffer)))
        cached
        (let ([fresh (build-text-map buffer)])
          (hashtable-set! text-map-cache buffer fresh)
          fresh))))

  (define (line-index-at-byte starts target)
    (let loop ([low 0] [high (- (vector-length starts) 1)])
      (if (> low high)
          high
          (let* ([middle (div (+ low high) 2)]
                 [value (vector-ref starts middle)])
            (cond
              [(= value target) middle]
              [(< value target) (loop (+ middle 1) high)]
              [else (loop low (- middle 1))])))))

  (define (lsp-text-map-position-at map offset)
    (unless (lsp-text-map? map)
      (assertion-violation
        'lsp-text-map-position-at "expected an LSP text map" map))
    (unless
      (and (integer? offset) (exact? offset) (not (negative? offset)))
      (assertion-violation
        'lsp-text-map-position-at
        "offset must be a non-negative exact integer"
        offset))
    (if (> offset (lsp-text-map-byte-size map))
        #f
        (let* ([source (lsp-text-map-text map)]
               [character-starts
                 (lsp-text-map-line-character-starts map)]
               [byte-starts (lsp-text-map-line-byte-starts map)]
               [line (line-index-at-byte byte-starts offset)]
               [start-index (vector-ref character-starts line)]
               [start-byte (vector-ref byte-starts line)])
          (let loop
            ([index start-index]
             [byte start-byte]
             [character 0])
            (cond
              [(= byte offset) (make-lsp-position line character)]
              [(= index (string-length source)) #f]
              [(crlf? source index) #f]
              [else
               (let* ([current (string-ref source index)]
                      [next-byte (+ byte (utf8-length current))])
                 (cond
                   [(char=? current #\newline) #f]
                   [(< offset next-byte) #f]
                   [else
                    (loop
                      (+ index 1)
                      next-byte
                      (+ character (utf16-width current)))]))])))))

  (define (lsp-text-map-offset-at map position)
    (unless (lsp-text-map? map)
      (assertion-violation
        'lsp-text-map-offset-at "expected an LSP text map" map))
    (unless (lsp-position? position)
      (assertion-violation
        'lsp-text-map-offset-at "expected an LSP position" position))
    (let* ((line (lsp-position-line position))
           (target-character (lsp-position-character position))
           (character-starts
             (lsp-text-map-line-character-starts map))
           (byte-starts (lsp-text-map-line-byte-starts map)))
      (if (>= line (vector-length character-starts))
          #f
          (let ((source (lsp-text-map-text map)))
            (let loop
              ((index (vector-ref character-starts line))
               (byte (vector-ref byte-starts line))
               (character 0))
              (cond
                ((= character target-character) byte)
                ((= index (string-length source)) #f)
                ((crlf? source index) #f)
                (else
                 (let ((current (string-ref source index)))
                   (if (char=? current #\newline)
                       #f
                       (let* ((next-character
                                (+ character (utf16-width current)))
                              (next-byte
                                (+ byte (utf8-length current))))
                         (cond
                           ((= target-character next-character) next-byte)
                           ((< target-character next-character) #f)
                           (else
                            (loop
                              (+ index 1)
                              next-byte
                              next-character)))))))))))))

  (define (lsp-buffer-position-at buffer offset)
    (lsp-text-map-position-at
      (lsp-buffer-text-map buffer)
      offset))

  (define (lsp-buffer-offset-at buffer position)
    (lsp-text-map-offset-at
      (lsp-buffer-text-map buffer)
      position))
)
