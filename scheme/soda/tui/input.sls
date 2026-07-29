(library (soda tui input)
  (export make-input-decoder
          input-decoder?
          input-decoder-pending?
          input-decoder-feed!
          input-decoder-flush!
          key-event?
          key-event-key
          key-event-codepoint
          key-event-shifted-codepoint
          key-event-base-layout-codepoint
          key-event-modifiers
          key-event-type
          key-event-text
          key-event-modifier?
          text-input-event?
          text-input-event-kind
          text-input-event-text
          input-event?)
  (import (rnrs)
          (soda editor event))

  (define-record-type (input-decoder %make-input-decoder input-decoder?)
    (fields
      (mutable pending input-decoder-pending input-decoder-pending-set!)
      (mutable paste? input-decoder-paste? input-decoder-paste?-set!)
      (mutable paste-bytes
               input-decoder-paste-bytes
               input-decoder-paste-bytes-set!)))

  (define (make-input-decoder)
    (%make-input-decoder
      (make-bytevector 0)
      #f
      (make-bytevector 0)))

  (define (input-decoder-pending? decoder)
    (unless (input-decoder? decoder)
      (assertion-violation
        'input-decoder-pending?
        "expected an input decoder"
        decoder))
    (positive? (bytevector-length (input-decoder-pending decoder))))

  (define (append-bytevectors left right)
    (let* ([left-size (bytevector-length left)]
           [right-size (bytevector-length right)]
           [output (make-bytevector (+ left-size right-size))])
      (bytevector-copy! left 0 output 0 left-size)
      (bytevector-copy! right 0 output left-size right-size)
      output))

  (define (bytevector-slice bytes start end)
    (let ([output (make-bytevector (- end start))])
      (bytevector-copy! bytes start output 0 (- end start))
      output))

  (define (single-byte value)
    (let ([bytes (make-bytevector 1)])
      (bytevector-u8-set! bytes 0 value)
      bytes))

  (define paste-end (string->utf8 "\x1b;[201~"))

  (define (find-bytevector bytes pattern start)
    (let ([limit
            (- (bytevector-length bytes)
               (bytevector-length pattern))])
      (let search ([index start])
        (cond
          [(> index limit) #f]
          [else
           (let compare ([pattern-index 0])
             (cond
               [(= pattern-index (bytevector-length pattern)) index]
               [(= (bytevector-u8-ref bytes (+ index pattern-index))
                   (bytevector-u8-ref pattern pattern-index))
                (compare (+ pattern-index 1))]
               [else (search (+ index 1))]))]))))

  (define (split-string value delimiter)
    (let loop ([start 0] [index 0] [parts '()])
      (cond
        [(= index (string-length value))
         (reverse (cons (substring value start index) parts))]
        [(char=? (string-ref value index) delimiter)
         (loop (+ index 1)
               (+ index 1)
               (cons (substring value start index) parts))]
        [else (loop start (+ index 1) parts)])))

  (define (optional-number value)
    (and (not (string=? value "")) (string->number value)))

  (define (list-ref/default values index default)
    (if (< index (length values)) (list-ref values index) default))

  (define (codepoints->bytes codepoints)
    (if (null? codepoints)
        (make-bytevector 0)
        (string->utf8
          (list->string
            (map
              (lambda (value)
                    (or (and value
                         (<= 0 value #x10ffff)
                         (not (<= #xd800 value #xdfff))
                         (integer->char value))
                    (integer->char #xfffd)))
              codepoints)))))

  (define (kitty-key codepoint)
    (case codepoint
      [(9) 'tab]
      [(13) 'enter]
      [(27) 'escape]
      [(127) 'backspace]
      [(57358) 'caps-lock]
      [(57359) 'scroll-lock]
      [(57360) 'num-lock]
      [(57361) 'print-screen]
      [(57362) 'pause]
      [(57363) 'menu]
      [else 'character]))

  (define (parse-kitty parameters)
    (let* ([fields (split-string parameters #\;)]
           [key-fields
             (split-string (list-ref/default fields 0 "") #\:)]
           [modifier-fields
             (split-string (list-ref/default fields 1 "1") #\:)]
           [codepoint
             (or (optional-number (list-ref/default key-fields 0 "")) 0)]
           [shifted
             (optional-number (list-ref/default key-fields 1 ""))]
           [base-layout
             (optional-number (list-ref/default key-fields 2 ""))]
           [encoded-modifiers
             (or (optional-number
                   (list-ref/default modifier-fields 0 "1"))
                 1)]
           [event-number
             (or (optional-number
                   (list-ref/default modifier-fields 1 "1"))
                 1)]
           [text-fields
             (split-string (list-ref/default fields 2 "") #\:)]
           [text-codepoints
             (filter
               (lambda (value) value)
               (map optional-number text-fields))])
      (make-key-event
        (kitty-key codepoint)
        codepoint
        shifted
        base-layout
        (max 0 (- encoded-modifiers 1))
        (case event-number
          [(2) 'repeat]
          [(3) 'release]
          [else 'press])
        (codepoints->bytes text-codepoints))))

  (define (legacy-modifiers parameters)
    (let ([fields (split-string parameters #\;)])
      (if (< (length fields) 2)
          0
          (max 0
               (- (or (optional-number (list-ref fields 1)) 1) 1)))))

  (define (legacy-functional final parameters)
    (make-key-event
      (case final
        [(#\A) 'up]
        [(#\B) 'down]
        [(#\C) 'right]
        [(#\D) 'left]
        [(#\H) 'home]
        [(#\F) 'end]
        [(#\P) 'f1]
        [(#\Q) 'f2]
        [(#\R) 'f3]
        [(#\S) 'f4]
        [(#\Z) 'tab]
        [else 'unknown])
      (if (char=? final #\Z) 9 #f)
      #f
      #f
      (let ([modifiers (legacy-modifiers parameters)])
        (if (char=? final #\Z)
            (bitwise-ior modifiers 1)
            modifiers))
      'press
      (make-bytevector 0)))

  (define (legacy-tilde parameters)
    (let* ([fields (split-string parameters #\;)]
           [number (or (optional-number (car fields)) 0)])
      (make-key-event
        (case number
          [(2) 'insert]
          [(3) 'delete]
          [(5) 'page-up]
          [(6) 'page-down]
          [(7) 'home]
          [(8) 'end]
          [(11) 'f1]
          [(12) 'f2]
          [(13) 'f3]
          [(14) 'f4]
          [(15) 'f5]
          [(17) 'f6]
          [(18) 'f7]
          [(19) 'f8]
          [(20) 'f9]
          [(21) 'f10]
          [(23) 'f11]
          [(24) 'f12]
          [else 'unknown])
        #f
        #f
        #f
        (legacy-modifiers parameters)
        'press
        (make-bytevector 0))))

  (define (find-csi-end bytes start)
    (let loop ([index start])
      (cond
        [(>= index (bytevector-length bytes)) #f]
        [(<= #x40 (bytevector-u8-ref bytes index) #x7e) index]
        [else (loop (+ index 1))])))

  (define (parse-csi bytes start end)
    (let* ([final-byte (bytevector-u8-ref bytes end)]
           [final (integer->char final-byte)]
           [parameters
             (utf8->string (bytevector-slice bytes start end))])
      (cond
        [(char=? final #\u) (parse-kitty parameters)]
        [(char=? final #\~) (legacy-tilde parameters)]
        [else (legacy-functional final parameters)])))

  (define (paste-start-csi? bytes start end)
    (and (= (bytevector-u8-ref bytes end) (char->integer #\~))
         (string=?
           (utf8->string (bytevector-slice bytes start end))
           "200")))

  (define (utf8-sequence-size first)
    (cond
      [(< first #x80) 1]
      [(<= #xc2 first #xdf) 2]
      [(<= #xe0 first #xef) 3]
      [(<= #xf0 first #xf4) 4]
      [else 1]))

  (define (continuation-byte? byte)
    (<= #x80 byte #xbf))

  (define (valid-utf8-sequence? bytes start end)
    (let* ([size (- end start)]
           [first (bytevector-u8-ref bytes start)]
           [second
             (and (> size 1) (bytevector-u8-ref bytes (+ start 1)))])
      (case size
        [(1) (< first #x80)]
        [(2)
         (and (<= #xc2 first #xdf)
              (continuation-byte? second))]
        [(3)
         (and
           (cond
             [(= first #xe0) (<= #xa0 second #xbf)]
             [(= first #xed) (<= #x80 second #x9f)]
             [else
              (and (<= #xe1 first #xef)
                   (continuation-byte? second))])
           (continuation-byte?
             (bytevector-u8-ref bytes (+ start 2))))]
        [(4)
         (and
           (cond
             [(= first #xf0) (<= #x90 second #xbf)]
             [(= first #xf4) (<= #x80 second #x8f)]
             [else
              (and (<= #xf1 first #xf3)
                   (continuation-byte? second))])
           (continuation-byte?
             (bytevector-u8-ref bytes (+ start 2)))
           (continuation-byte?
             (bytevector-u8-ref bytes (+ start 3))))]
        [else #f])))

  (define (character-event bytes start end)
    (let ([text
            (if (valid-utf8-sequence? bytes start end)
                (bytevector-slice bytes start end)
                (string->utf8 (string (integer->char #xfffd))))])
      (make-key-event
        'character
        (char->integer (string-ref (utf8->string text) 0))
        #f
        #f
        0
        'press
        text)))

  (define (escape-event)
    (make-key-event
      'escape
      27
      #f
      #f
      0
      'press
      (make-bytevector 0)))

  (define (control-event byte)
    (cond
      [(or (= byte 10) (= byte 13))
       (make-key-event 'enter 13 #f #f 0 'press (make-bytevector 0))]
      [(or (= byte 8) (= byte 127))
       (make-key-event 'backspace 127 #f #f 0 'press (make-bytevector 0))]
      [(= byte 9)
       (make-key-event 'tab 9 #f #f 0 'press (make-bytevector 0))]
      [(= byte 0)
       (make-key-event 'character 32 #f #f 4 'press (make-bytevector 0))]
      [(<= 1 byte 26)
       (make-key-event
         'character
         (+ byte 96)
         #f
         #f
         4
         'press
         (make-bytevector 0))]
      [else
       (make-key-event 'unknown byte #f #f 0 'press (make-bytevector 0))]))

  (define (input-decoder-feed! decoder incoming)
    (unless (input-decoder? decoder)
      (assertion-violation
        'input-decoder-feed!
        "expected an input decoder"
        decoder))
    (unless (bytevector? incoming)
      (assertion-violation
        'input-decoder-feed!
        "expected a bytevector"
        incoming))
    (let ([initial
            (append-bytevectors
              (input-decoder-pending decoder)
              incoming)])
      (input-decoder-pending-set! decoder (make-bytevector 0))
      (letrec
        ([parse-paste
           (lambda (bytes index events)
             (let* ([combined
                      (append-bytevectors
                        (input-decoder-paste-bytes decoder)
                        (bytevector-slice
                          bytes
                          index
                          (bytevector-length bytes)))]
                    [end (find-bytevector combined paste-end 0)])
               (if end
                   (let ([event
                           (make-text-input-event
                             'paste
                             (string->utf8
                               (utf8->string
                                 (bytevector-slice
                                   combined
                                   0
                                   end))))])
                     (input-decoder-paste?-set! decoder #f)
                     (input-decoder-paste-bytes-set!
                       decoder
                       (make-bytevector 0))
                     (parse-normal
                       combined
                       (+ end (bytevector-length paste-end))
                       (cons event events)))
                   (begin
                     (input-decoder-paste-bytes-set! decoder combined)
                     (reverse events)))))]
         [parse-normal
           (lambda (bytes index events)
             (let ([size (bytevector-length bytes)])
               (cond
                 [(= index size) (reverse events)]
                 [else
                  (let ([byte (bytevector-u8-ref bytes index)])
                    (cond
                      [(= byte 27)
                       (cond
                         [(>= (+ index 1) size)
                          (input-decoder-pending-set!
                            decoder
                            (bytevector-slice bytes index size))
                          (reverse events)]
                         [(= (bytevector-u8-ref bytes (+ index 1)) 91)
                          (let ([end
                                  (find-csi-end bytes (+ index 2))])
                            (if end
                                (if (paste-start-csi?
                                      bytes
                                      (+ index 2)
                                      end)
                                    (begin
                                      (input-decoder-paste?-set!
                                        decoder
                                        #t)
                                      (input-decoder-paste-bytes-set!
                                        decoder
                                        (make-bytevector 0))
                                      (parse-paste
                                        bytes
                                        (+ end 1)
                                        events))
                                    (parse-normal
                                      bytes
                                      (+ end 1)
                                      (cons
                                        (parse-csi
                                          bytes
                                          (+ index 2)
                                          end)
                                        events)))
                                (begin
                                  (input-decoder-pending-set!
                                    decoder
                                    (bytevector-slice bytes index size))
                                  (reverse events))))]
                         [(= (bytevector-u8-ref bytes (+ index 1)) 79)
                          (if (>= (+ index 2) size)
                              (begin
                                (input-decoder-pending-set!
                                  decoder
                                  (bytevector-slice bytes index size))
                                (reverse events))
                              (parse-normal
                                bytes
                                (+ index 3)
                                (cons
                                  (legacy-functional
                                    (integer->char
                                      (bytevector-u8-ref
                                        bytes
                                        (+ index 2)))
                                    "")
                                  events)))]
                         [else
                          (let ([next
                                  (bytevector-u8-ref
                                    bytes
                                    (+ index 1))])
                            (cond
                              [(and (>= next 32) (< next 127))
                               (parse-normal
                                 bytes
                                 (+ index 2)
                                 (cons
                                   (make-key-event
                                     'character
                                     next
                                     #f
                                     #f
                                     2
                                     'press
                                     (single-byte next))
                                   events))]
                              [(or (= next 8) (= next 127))
                               (parse-normal
                                 bytes
                                 (+ index 2)
                                 (cons
                                   (make-key-event
                                     'backspace
                                     127
                                     #f
                                     #f
                                     2
                                     'press
                                     (make-bytevector 0))
                                   events))]
                              [else
                               (parse-normal
                                 bytes
                                 (+ index 1)
                                 (cons (escape-event) events))]))])]
                      [(or (< byte 32) (= byte 127))
                       (parse-normal
                         bytes
                         (+ index 1)
                         (cons (control-event byte) events))]
                      [else
                       (let ([character-size
                               (utf8-sequence-size byte)])
                         (if (> (+ index character-size) size)
                             (begin
                               (input-decoder-pending-set!
                                 decoder
                                 (bytevector-slice bytes index size))
                               (reverse events))
                             (parse-normal
                               bytes
                               (+ index character-size)
                               (cons
                                 (character-event
                                   bytes
                                   index
                                   (+ index character-size))
                                 events))))]))])))])
        (if (input-decoder-paste? decoder)
            (parse-paste initial 0 '())
            (parse-normal initial 0 '())))))

  (define (input-decoder-flush! decoder)
    (unless (input-decoder? decoder)
      (assertion-violation
        'input-decoder-flush!
        "expected an input decoder"
        decoder))
    (let ([pending (input-decoder-pending decoder)])
      (input-decoder-pending-set! decoder (make-bytevector 0))
      (cond
        [(zero? (bytevector-length pending)) '()]
        [(and (= (bytevector-length pending) 1)
              (= (bytevector-u8-ref pending 0) 27))
         (list (escape-event))]
        [else
         (list
           (make-key-event
             'unknown
             #f
             #f
             #f
             0
             'press
             (make-bytevector 0)))]))))
