(library (soda tui terminal-input)
  (export make-terminal-input-decoder
          terminal-input-decoder?
          terminal-input-decoder-pending?
          terminal-input-decoder-feed!
          terminal-input-decoder-flush!
          kitty-keyboard-enable-sequence
          kitty-keyboard-disable-sequence
          bracketed-paste-enable-sequence
          bracketed-paste-disable-sequence
          mouse-reporting-enable-sequence
          mouse-reporting-disable-sequence
          terminal-input-enable-sequence
          terminal-input-disable-sequence)
  (import (rnrs)
          (only (chezscheme) current-time time-second time-nanosecond)
          (soda host input-event))

  (define escape-byte #x1b)
  (define paste-end (string->utf8 "\x1b;[201~"))
  (define paste-overlap (- (bytevector-length paste-end) 1))

  ;; Alternate-key reporting preserves shifted/base-layout codepoints while
  ;; disambiguation makes control keys unambiguous.  Protocol state is stacked
  ;; so a containing terminal application can restore its own flags.
  (define kitty-keyboard-enable-sequence "\x1b;[>7u")
  (define kitty-keyboard-disable-sequence "\x1b;[<u")
  (define bracketed-paste-enable-sequence "\x1b;[?2004h")
  (define bracketed-paste-disable-sequence "\x1b;[?2004l")
  ;; SGR coordinates avoid the byte-range limits of legacy mouse reports.
  ;; Any-motion tracking supplies press, drag, hover, release, and wheel input.
  (define mouse-reporting-enable-sequence "\x1b;[?1003h\x1b;[?1006h")
  (define mouse-reporting-disable-sequence "\x1b;[?1006l\x1b;[?1003l")
  (define terminal-input-enable-sequence
    (string-append
      kitty-keyboard-enable-sequence bracketed-paste-enable-sequence
      mouse-reporting-enable-sequence))
  (define terminal-input-disable-sequence
    (string-append
      mouse-reporting-disable-sequence bracketed-paste-disable-sequence
      kitty-keyboard-disable-sequence))

  (define-record-type
    (terminal-input-decoder %make-terminal-input-decoder
                            terminal-input-decoder?)
    (fields
      (mutable pending decoder-pending decoder-pending-set!)
      (mutable paste? decoder-paste? decoder-paste?-set!)
      (mutable paste-chunks decoder-paste-chunks decoder-paste-chunks-set!)
      (mutable paste-tail decoder-paste-tail decoder-paste-tail-set!)
      (immutable clock decoder-clock)
      (mutable last-click decoder-last-click decoder-last-click-set!)))

  (define (monotonic-milliseconds)
    (let ([time (current-time 'time-monotonic)])
      (+ (* (time-second time) 1000)
         (div (time-nanosecond time) 1000000))))

  (define make-terminal-input-decoder
    (case-lambda
      [() (make-terminal-input-decoder monotonic-milliseconds)]
      [(clock)
       (unless (procedure? clock)
         (assertion-violation
           'make-terminal-input-decoder "clock must be a procedure" clock))
       (%make-terminal-input-decoder
         (make-bytevector 0) #f '() (make-bytevector 0) clock #f)]))

  (define click-interval-ms 500)

  (define (with-click-count decoder event)
    (if (not (and (pointer-event? event)
                  (memq (pointer-event-phase event) '(press release))))
        event
        (let* ([now ((decoder-clock decoder))]
               [previous (decoder-last-click decoder)]
               [same?
                (and previous
                     (eq? (pointer-event-button event) (car previous))
                     (= (pointer-event-row event) (cadr previous))
                     (= (pointer-event-column event) (caddr previous)))]
               [count
                (if (eq? (pointer-event-phase event) 'release)
                    (if same? (list-ref previous 4) 1)
                    (if (and same? (<= 0 (- now (cadddr previous))
                                       click-interval-ms))
                        (+ 1 (list-ref previous 4))
                        1))])
          (when (eq? (pointer-event-phase event) 'press)
            (decoder-last-click-set!
              decoder
              (list (pointer-event-button event)
                    (pointer-event-row event)
                    (pointer-event-column event) now count)))
          (make-pointer-event
            (pointer-event-row event) (pointer-event-column event)
            (pointer-event-button event) (pointer-event-modifiers event)
            count (pointer-event-phase event)))))

  (define (terminal-input-decoder-pending? decoder)
    (unless (terminal-input-decoder? decoder)
      (assertion-violation
        'terminal-input-decoder-pending?
        "expected a terminal input decoder"
        decoder))
    (or (decoder-paste? decoder)
        (positive? (bytevector-length (decoder-pending decoder)))))

  (define (bytevector-slice bytes start end)
    (let ([result (make-bytevector (- end start))])
      (bytevector-copy! bytes start result 0 (- end start))
      result))

  (define (bytevector-append left right)
    (let* ([left-size (bytevector-length left)]
           [right-size (bytevector-length right)]
           [result (make-bytevector (+ left-size right-size))])
      (bytevector-copy! left 0 result 0 left-size)
      (bytevector-copy! right 0 result left-size right-size)
      result))

  (define (assemble-chunks chunks tail)
    (let* ([ordered (reverse (if (zero? (bytevector-length tail))
                                 chunks
                                 (cons tail chunks)))]
           [size (fold-left
                   (lambda (total item) (+ total (bytevector-length item)))
                   0 ordered)]
           [result (make-bytevector size)])
      (let loop ([remaining ordered] [offset 0])
        (if (null? remaining)
            result
            (let ([length (bytevector-length (car remaining))])
              (bytevector-copy! (car remaining) 0 result offset length)
              (loop (cdr remaining) (+ offset length)))))))

  (define (find-bytevector bytes pattern start)
    (let ([limit (- (bytevector-length bytes) (bytevector-length pattern))])
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
         (loop (+ index 1) (+ index 1)
               (cons (substring value start index) parts))]
        [else (loop start (+ index 1) parts)])))

  (define (list-ref/default values index default)
    (if (< index (length values)) (list-ref values index) default))

  (define (optional-number value)
    (and (not (string=? value ""))
         (guard (condition [else #f]) (string->number value))))

  (define (valid-codepoint? value)
    (and (integer? value)
         (exact? value)
         (<= 0 value #x10ffff)
         (not (<= #xd800 value #xdfff))))

  (define (codepoints->bytes codepoints)
    (string->utf8
      (list->string
        (map
          (lambda (value)
            (integer->char (if (valid-codepoint? value) value #xfffd)))
          codepoints))))

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
           [second (and (> size 1) (bytevector-u8-ref bytes (+ start 1)))])
      (case size
        [(1) (< first #x80)]
        [(2) (and (<= #xc2 first #xdf) (continuation-byte? second))]
        [(3)
         (and
           (cond
             [(= first #xe0) (<= #xa0 second #xbf)]
             [(= first #xed) (<= #x80 second #x9f)]
             [else (and (<= #xe1 first #xef) (continuation-byte? second))])
           (continuation-byte? (bytevector-u8-ref bytes (+ start 2))))]
        [(4)
         (and
           (cond
             [(= first #xf0) (<= #x90 second #xbf)]
             [(= first #xf4) (<= #x80 second #x8f)]
             [else (and (<= #xf1 first #xf3) (continuation-byte? second))])
           (continuation-byte? (bytevector-u8-ref bytes (+ start 2)))
           (continuation-byte? (bytevector-u8-ref bytes (+ start 3))))]
        [else #f])))

  (define replacement-bytes (string->utf8 "\xfffd;"))

  (define (sanitize-utf8 bytes)
    (call-with-values
      open-bytevector-output-port
      (lambda (port extract)
        (let loop ([index 0])
          (if (= index (bytevector-length bytes))
              (extract)
              (let* ([size (utf8-sequence-size (bytevector-u8-ref bytes index))]
                     [end (+ index size)])
                (if (and (<= end (bytevector-length bytes))
                         (valid-utf8-sequence? bytes index end))
                    (begin
                      (put-bytevector port bytes index size)
                      (loop end))
                    (begin
                      (put-bytevector port replacement-bytes)
                      (loop (+ index 1))))))))))

  (define empty-bytes (make-bytevector 0))

  (define (character-event bytes start end modifiers committed?)
    (let* ([valid? (valid-utf8-sequence? bytes start end)]
           [text (if valid?
                     (bytevector-slice bytes start end)
                     replacement-bytes)]
           [codepoint (char->integer (string-ref (utf8->string text) 0))])
      (make-key-event
        'character codepoint #f #f modifiers 'press
        (if committed? text empty-bytes))))

  (define (escape-event)
    (make-key-event 'escape 27 #f #f 0 'press empty-bytes))

  (define (unknown-event)
    (make-key-event 'unknown #f #f #f 0 'press empty-bytes))

  (define (control-event byte modifiers)
    (cond
      [(or (= byte 10) (= byte 13))
       (make-key-event 'enter 13 #f #f modifiers 'press empty-bytes)]
      [(= byte 127)
       (make-key-event 'backspace 127 #f #f modifiers 'press empty-bytes)]
      [(= byte 9)
       (make-key-event 'tab 9 #f #f modifiers 'press empty-bytes)]
      [(= byte 0)
       (make-key-event
         'character 32 #f #f (bitwise-ior modifiers 4) 'press empty-bytes)]
      [(<= 1 byte 26)
       (make-key-event
         'character (+ byte 96) #f #f
         (bitwise-ior modifiers 4) 'press empty-bytes)]
      [else (unknown-event)]))

  (define (function-key number)
    (string->symbol (string-append "f" (number->string number))))

  (define (kitty-key codepoint)
    (cond
      [(= codepoint 9) 'tab]
      [(= codepoint 13) 'enter]
      [(= codepoint 27) 'escape]
      [(= codepoint 127) 'backspace]
      [(<= 57344 codepoint 57363)
       (vector-ref
         '#(escape enter tab backspace insert delete left right up down
            page-up page-down home end caps-lock scroll-lock num-lock
            print-screen pause menu)
         (- codepoint 57344))]
      [(<= 57364 codepoint 57398) (function-key (+ 1 (- codepoint 57364)))]
      [else 'character]))

  (define (parse-kitty parameters)
    (if (and (positive? (string-length parameters))
             (char=? (string-ref parameters 0) #\?))
        #f
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
                 (filter valid-codepoint?
                   (map optional-number text-fields))])
          (if (not (valid-codepoint? codepoint))
              (unknown-event)
              (make-key-event
                (kitty-key codepoint)
                codepoint shifted base-layout
                (max 0 (- encoded-modifiers 1))
                (case event-number
                  [(2) 'repeat]
                  [(3) 'release]
                  [else 'press])
                (codepoints->bytes text-codepoints))))))

  (define (legacy-modifiers parameters)
    (let ([fields (split-string parameters #\;)])
      (if (< (length fields) 2)
          0
          (max 0
            (- (or (optional-number (list-ref fields 1)) 1) 1)))))

  (define (legacy-functional final parameters)
    (make-key-event
      (case final
        [(#\A) 'up] [(#\B) 'down] [(#\C) 'right] [(#\D) 'left]
        [(#\H) 'home] [(#\F) 'end]
        [(#\P) 'f1] [(#\Q) 'f2] [(#\R) 'f3] [(#\S) 'f4]
        [(#\Z) 'tab]
        [else 'unknown])
      (if (char=? final #\Z) 9 #f)
      #f #f
      (if (char=? final #\Z)
          (bitwise-ior (legacy-modifiers parameters) 1)
          (legacy-modifiers parameters))
      'press empty-bytes))

  (define (legacy-tilde parameters)
    (let* ([fields (split-string parameters #\;)]
           [number (or (optional-number (car fields)) 0)])
      (make-key-event
        (case number
          [(2) 'insert] [(3) 'delete]
          [(5) 'page-up] [(6) 'page-down]
          [(7) 'home] [(8) 'end]
          [(11) 'f1] [(12) 'f2] [(13) 'f3] [(14) 'f4]
          [(15) 'f5] [(17) 'f6] [(18) 'f7] [(19) 'f8]
          [(20) 'f9] [(21) 'f10] [(23) 'f11] [(24) 'f12]
          [else 'unknown])
        #f #f #f (legacy-modifiers parameters) 'press empty-bytes)))

  (define (sgr-mouse-modifiers encoded)
    (bitwise-ior
      (if (zero? (bitwise-and encoded 4)) 0 1)
      (if (zero? (bitwise-and encoded 8)) 0 2)
      (if (zero? (bitwise-and encoded 16)) 0 4)))

  (define (parse-sgr-mouse parameters final)
    (let* ([body (substring parameters 1 (string-length parameters))]
           [fields (split-string body #\;)]
           [numbers (map optional-number fields)])
      (unless (and (= (length numbers) 3)
                   (for-all
                     (lambda (value)
                       (and (integer? value) (exact? value)
                            (not (negative? value))))
                     numbers)
                   (positive? (cadr numbers))
                   (positive? (caddr numbers)))
        (assertion-violation 'parse-sgr-mouse "invalid SGR mouse report"))
      (let* ([encoded (car numbers)]
           [column (- (cadr numbers) 1)]
           [row (- (caddr numbers) 1)]
           [wheel? (not (zero? (bitwise-and encoded 64)))]
           [motion? (not (zero? (bitwise-and encoded 32)))]
           [button-code (bitwise-and encoded 3)]
           [button (if wheel?
                       (case button-code
                         [(0) 'wheel-up] [(1) 'wheel-down]
                         [(2) 'wheel-left] [else 'wheel-right])
                       (case button-code
                         [(0) 'left] [(1) 'middle] [(2) 'right]
                         [else 'none]))]
           [phase (cond
                   [wheel? 'wheel]
                   [(char=? final #\m) 'release]
                   [motion? 'move]
                   [else 'press])])
      (make-pointer-event
        row column button (sgr-mouse-modifiers encoded)
        (if (memq phase '(press release)) 1 0)
        phase))))

  (define (parse-csi bytes start end)
    (guard (condition [else (unknown-event)])
      (let* ([final (integer->char (bytevector-u8-ref bytes end))]
             [parameters (utf8->string (bytevector-slice bytes start end))])
        (cond
          [(and (memv final '(#\M #\m))
                (positive? (string-length parameters))
                (char=? (string-ref parameters 0) #\<))
           (parse-sgr-mouse parameters final)]
          [(char=? final #\u) (parse-kitty parameters)]
          [(char=? final #\~) (legacy-tilde parameters)]
          [else (legacy-functional final parameters)]))))

  (define (find-csi-end bytes start)
    (let loop ([index start])
      (cond
        [(>= index (bytevector-length bytes)) #f]
        [(<= #x40 (bytevector-u8-ref bytes index) #x7e) index]
        [else (loop (+ index 1))])))

  (define (paste-start-csi? bytes start end)
    (and (= (bytevector-u8-ref bytes end) (char->integer #\~))
         (string=? (utf8->string (bytevector-slice bytes start end)) "200")))

  (define (terminal-input-decoder-feed! decoder incoming)
    (unless (terminal-input-decoder? decoder)
      (assertion-violation
        'terminal-input-decoder-feed!
        "expected a terminal input decoder"
        decoder))
    (unless (bytevector? incoming)
      (assertion-violation
        'terminal-input-decoder-feed! "expected a bytevector" incoming))
    (let ([initial (bytevector-append (decoder-pending decoder) incoming)])
      (decoder-pending-set! decoder empty-bytes)
      (letrec
        ([parse-paste
           (lambda (bytes events)
             (let* ([combined
                      (bytevector-append (decoder-paste-tail decoder) bytes)]
                    [end (find-bytevector combined paste-end 0)])
               (if end
                   (let* ([prefix (bytevector-slice combined 0 end)]
                          [payload (assemble-chunks
                                     (if (zero? (bytevector-length prefix))
                                         (decoder-paste-chunks decoder)
                                         (cons prefix
                                           (decoder-paste-chunks decoder)))
                                     empty-bytes)]
                          [event (make-text-input-event
                                   'paste (sanitize-utf8 payload))]
                          [remaining-start (+ end (bytevector-length paste-end))])
                     (decoder-paste?-set! decoder #f)
                     (decoder-paste-chunks-set! decoder '())
                     (decoder-paste-tail-set! decoder empty-bytes)
                     (parse-normal combined remaining-start (cons event events)))
                   (let* ([size (bytevector-length combined)]
                          [split (max 0 (- size paste-overlap))]
                          [chunk (bytevector-slice combined 0 split)]
                          [tail (bytevector-slice combined split size)])
                     (when (positive? (bytevector-length chunk))
                       (decoder-paste-chunks-set!
                         decoder
                         (cons chunk (decoder-paste-chunks decoder))))
                     (decoder-paste-tail-set! decoder tail)
                     (reverse events)))))]
         [parse-alt
           (lambda (bytes index events)
             (let* ([size (bytevector-length bytes)]
                    [first (bytevector-u8-ref bytes index)])
               (cond
                 [(or (< first 32) (= first 127))
                  (parse-normal
                    bytes (+ index 1)
                    (cons (control-event first 2) events))]
                 [else
                  (let ([width (utf8-sequence-size first)])
                    (if (> (+ index width) size)
                        (begin
                          (decoder-pending-set!
                            decoder (bytevector-slice bytes (- index 1) size))
                          (reverse events))
                        (parse-normal
                          bytes (+ index width)
                          (cons
                            (character-event
                              bytes index (+ index width) 2 #f)
                            events))))])))]
         [parse-normal
           (lambda (bytes index events)
             (let ([size (bytevector-length bytes)])
               (cond
                 [(= index size) (reverse events)]
                 [else
                  (let ([byte (bytevector-u8-ref bytes index)])
                    (cond
                      [(= byte escape-byte)
                       (cond
                         [(>= (+ index 1) size)
                          (decoder-pending-set!
                            decoder (bytevector-slice bytes index size))
                          (reverse events)]
                         [(= (bytevector-u8-ref bytes (+ index 1)) #x5b)
                          (let ([end (find-csi-end bytes (+ index 2))])
                            (if (not end)
                                (begin
                                  (decoder-pending-set!
                                    decoder (bytevector-slice bytes index size))
                                  (reverse events))
                                (if (paste-start-csi?
                                      bytes (+ index 2) end)
                                    (begin
                                      (decoder-paste?-set! decoder #t)
                                      (decoder-paste-chunks-set! decoder '())
                                      (decoder-paste-tail-set! decoder empty-bytes)
                                      (parse-paste
                                        (bytevector-slice bytes (+ end 1) size)
                                        events))
                                    (let ([event
                                            (parse-csi
                                              bytes (+ index 2) end)])
                                      (parse-normal
                                        bytes (+ end 1)
                                        (if event
                                            (cons (with-click-count decoder event) events)
                                            events))))))]
                         [(= (bytevector-u8-ref bytes (+ index 1)) #x4f)
                          (if (>= (+ index 2) size)
                              (begin
                                (decoder-pending-set!
                                  decoder (bytevector-slice bytes index size))
                                (reverse events))
                              (parse-normal
                                bytes (+ index 3)
                                (cons
                                  (legacy-functional
                                    (integer->char
                                      (bytevector-u8-ref bytes (+ index 2)))
                                    "")
                                  events)))]
                         [else (parse-alt bytes (+ index 1) events)])]
                      [(or (< byte 32) (= byte 127))
                       (parse-normal
                         bytes (+ index 1)
                         (cons (control-event byte 0) events))]
                      [else
                       (let ([width (utf8-sequence-size byte)])
                         (if (> (+ index width) size)
                             (begin
                               (decoder-pending-set!
                                 decoder (bytevector-slice bytes index size))
                               (reverse events))
                             (parse-normal
                               bytes (+ index width)
                               (cons
                                 (character-event
                                   bytes index (+ index width) 0 #t)
                                 events))))]))])))])
        (if (decoder-paste? decoder)
            (parse-paste initial '())
            (parse-normal initial 0 '())))))

  ;; The frontend arms an Escape timer only while this decoder is pending.
  ;; Flushing a lone Escape commits it; other incomplete protocol units become
  ;; one controlled unknown event.  Bracketed paste is never timer-flushed.
  (define (terminal-input-decoder-flush! decoder)
    (unless (terminal-input-decoder? decoder)
      (assertion-violation
        'terminal-input-decoder-flush!
        "expected a terminal input decoder"
        decoder))
    (if (decoder-paste? decoder)
        '()
        (let ([pending (decoder-pending decoder)])
          (decoder-pending-set! decoder empty-bytes)
          (cond
            [(zero? (bytevector-length pending)) '()]
            [(and (= (bytevector-length pending) 1)
                  (= (bytevector-u8-ref pending 0) escape-byte))
             (list (escape-event))]
            [else (list (unknown-event))]))))
)
