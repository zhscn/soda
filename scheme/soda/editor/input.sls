(library (soda editor input)
  (export make-input-decoder
          input-decoder?
          input-decoder-feed!
          key-event?
          key-event-key
          key-event-codepoint
          key-event-shifted-codepoint
          key-event-base-layout-codepoint
          key-event-modifiers
          key-event-type
          key-event-text
          key-event-modifier?)
  (import (rnrs))

  (define-record-type (input-decoder %make-input-decoder input-decoder?)
    (fields (mutable pending input-decoder-pending input-decoder-pending-set!)))

  (define-record-type key-event
    (fields key
            codepoint
            shifted-codepoint
            base-layout-codepoint
            modifiers
            type
            text))

  (define modifier-bits
    '((shift . 1)
      (alt . 2)
      (ctrl . 4)
      (super . 8)
      (hyper . 16)
      (meta . 32)
      (caps-lock . 64)
      (num-lock . 128)))

  (define (make-input-decoder)
    (%make-input-decoder (make-bytevector 0)))

  (define (key-event-modifier? event modifier)
    (unless (key-event? event)
      (assertion-violation 'key-event-modifier? "expected a key event" event))
    (let ([entry (assq modifier modifier-bits)])
      (unless entry
        (assertion-violation
          'key-event-modifier?
          "unknown modifier"
          modifier))
      (not (zero? (bitwise-and (key-event-modifiers event) (cdr entry))))))

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
        [(#\S) 'f4]
        [(#\Z) 'tab]
        [else 'unknown])
      #f
      #f
      #f
      (legacy-modifiers parameters)
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

  (define (utf8-sequence-size first)
    (cond
      [(< first #x80) 1]
      [(= (bitwise-and first #xe0) #xc0) 2]
      [(= (bitwise-and first #xf0) #xe0) 3]
      [(= (bitwise-and first #xf8) #xf0) 4]
      [else 1]))

  (define (text-event bytes start end)
    (make-key-event
      'text
      #f
      #f
      #f
      0
      'press
      (bytevector-slice bytes start end)))

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
    (let* ([bytes
             (append-bytevectors
               (input-decoder-pending decoder)
               incoming)]
           [size (bytevector-length bytes)])
      (let loop ([index 0] [events '()])
        (cond
          [(= index size)
           (input-decoder-pending-set! decoder (make-bytevector 0))
           (reverse events)]
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
                   (let ([end (find-csi-end bytes (+ index 2))])
                     (if end
                         (loop
                           (+ end 1)
                           (cons
                             (parse-csi bytes (+ index 2) end)
                             events))
                         (begin
                           (input-decoder-pending-set!
                             decoder
                             (bytevector-slice bytes index size))
                           (reverse events))))]
                  [else
                   (loop
                     (+ index 1)
                     (cons
                       (make-key-event
                         'escape
                         27
                         #f
                         #f
                         0
                         'press
                         (make-bytevector 0))
                       events))])]
               [(or (< byte 32) (= byte 127))
                (loop (+ index 1) (cons (control-event byte) events))]
               [else
                (let ([character-size (utf8-sequence-size byte)])
                  (if (> (+ index character-size) size)
                      (begin
                        (input-decoder-pending-set!
                          decoder
                          (bytevector-slice bytes index size))
                        (reverse events))
                      (loop
                        (+ index character-size)
                        (cons
                          (text-event bytes index (+ index character-size))
                          events))))]))])))))
