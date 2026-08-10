(library (soda packages base text-format)
  (export append-bytevectors
          concatenate-bytevectors
          wrap-line-at-fill-column
          bytevector-contains-newline?
          paragraph-bounds
          split-words
          leading-whitespace
          fill-words)
  (import (rnrs)
          (soda kernel document)
          (soda ffi unicode))

  (define (append-bytevectors left right)
    (let* ([left-length (bytevector-length left)]
           [right-length (bytevector-length right)]
           [result (make-bytevector (+ left-length right-length))])
      (bytevector-copy! left 0 result 0 left-length)
      (bytevector-copy! right 0 result left-length right-length)
      result))

  (define (concatenate-bytevectors fragments)
    (let ([length (fold-left (lambda (total bytes)
                               (+ total (bytevector-length bytes)))
                             0 fragments)])
      (let ([result (make-bytevector length)])
        (let loop ([remaining fragments] [offset 0])
          (if (null? remaining)
              result
              (let ([bytes (car remaining)])
                (bytevector-copy! bytes 0 result offset (bytevector-length bytes))
                (loop (cdr remaining) (+ offset (bytevector-length bytes)))))))))

  (define-record-type
    (wrap-token %make-wrap-token wrap-token?)
    (fields (immutable from wrap-token-from)
            (immutable to wrap-token-to)
            (immutable bytes wrap-token-bytes)
            (immutable whitespace? wrap-token-whitespace?)))

  (define (ascii-space-or-tab? bytes)
    (and (= (bytevector-length bytes) 1)
         (memv (bytevector-u8-ref bytes 0) '(9 32))))

  (define (line-wrap-tokens bytes)
    (let ([size (bytevector-length bytes)])
      (let loop ([offset 0] [result '()])
        (if (= offset size)
            (reverse result)
            (let* ([next (unicode-next-grapheme-offset bytes offset)]
                   [fragment
                    (let ([value (make-bytevector (- next offset))])
                      (bytevector-copy! bytes offset value 0 (- next offset))
                      value)])
              (loop next
                    (cons (%make-wrap-token offset next fragment
                                            (ascii-space-or-tab? fragment))
                          result)))))))

  (define (wrap-token-width token column tab-width)
    (let ([bytes (wrap-token-bytes token)])
      (if (and (= (bytevector-length bytes) 1) (= (bytevector-u8-ref bytes 0) 9))
          (- tab-width (mod column tab-width))
          (max 1 (unicode-grapheme-width bytes)))))

  (define (split-through-token tokens target)
    (let loop ([remaining tokens] [before '()])
      (cond [(null? remaining)
             (assertion-violation 'split-through-token "target token is absent" target)]
            [else
             (let ([next (cons (car remaining) before)])
               (if (eq? (car remaining) target)
                   (cons (reverse next) (cdr remaining))
                   (loop (cdr remaining) next)))])))

  ;; Greedy hard wrapping only changes an existing horizontal whitespace token
  ;; into a newline.  A word longer than fill-column remains intact, matching
  ;; normal editor auto-fill behavior rather than silently splitting source
  ;; identifiers.  MARKER is a byte boundary in the input line and maps the
  ;; insertion caret through the generated line replacement.
  (define (wrap-line-at-fill-column line marker column tab-width)
    (let ([fragments '()]
          [output-length 0]
          [mapped-marker #f]
          [changed? #f])
      (define (emit! token replacement?)
        (when (= marker (wrap-token-from token))
          (set! mapped-marker output-length))
        (let ([bytes (if replacement? (string->utf8 "\n") (wrap-token-bytes token))])
          (when replacement? (set! changed? #t))
          (set! fragments (cons bytes fragments))
          (set! output-length (+ output-length (bytevector-length bytes))))
        (when (= marker (wrap-token-to token))
          (set! mapped-marker output-length)))
      (define (emit-list! tokens break-token)
        (for-each (lambda (token) (emit! token (and break-token (eq? token break-token))))
                  tokens))
      (let loop ([remaining (line-wrap-tokens line)] [pending '()]
                 [display-column 0] [last-space #f])
        (cond
          [(null? remaining)
           (emit-list! pending #f)
           (unless mapped-marker
             (when (= marker (bytevector-length line))
               (set! mapped-marker output-length)))]
          [else
           (let* ([token (car remaining)]
                  [next-column (+ display-column
                                  (wrap-token-width token display-column tab-width))])
             (if (and (> next-column column) last-space)
                 (let* ([split (split-through-token pending last-space)]
                        [before (car split)]
                        [after (cdr split)])
                   (emit-list! before last-space)
                   (loop (append after remaining) '() 0 #f))
                 (loop (cdr remaining)
                       (append pending (list token))
                       next-column
                       (if (wrap-token-whitespace? token) token last-space))))]))
      (cons (concatenate-bytevectors (reverse fragments))
            (cons mapped-marker changed?))))

  (define (bytevector-contains-newline? bytes)
    (let loop ([offset 0])
      (and (< offset (bytevector-length bytes))
           (or (= (bytevector-u8-ref bytes offset) 10)
               (loop (+ offset 1))))))

  (define (paragraph-line-blank? text line)
    (let loop ([offset (text-line-start text line)]
               [end (text-line-content-end text line)])
      (or (= offset end)
          (and (memv (text-byte-at text offset) '(9 32))
               (loop (+ offset 1) end)))))

  (define (paragraph-bounds text point)
    (let* ([line (car (text-position text point))]
           [last (- (text-line-count text) 1)])
      (if (paragraph-line-blank? text line)
          (cons (text-line-start text line) (text-line-content-end text line))
          (let ([first
                 (let loop ([current line])
                   (if (or (zero? current)
                           (paragraph-line-blank? text (- current 1)))
                       current
                       (loop (- current 1))))]
                [final
                 (let loop ([current line])
                   (if (or (= current last)
                           (paragraph-line-blank? text (+ current 1)))
                       current
                       (loop (+ current 1))))])
            (cons (text-line-start text first)
                  (text-line-content-end text final))))))

  (define (split-words value)
    (let loop ([characters (string->list value)] [word '()] [words '()])
      (cond [(null? characters)
             (reverse (if (null? word) words
                          (cons (list->string (reverse word)) words)))]
            [(char-whitespace? (car characters))
             (loop (cdr characters) '()
                   (if (null? word) words
                       (cons (list->string (reverse word)) words)))]
            [else (loop (cdr characters) (cons (car characters) word) words)])))

  (define (leading-whitespace value)
    (let loop ([index 0])
      (if (and (< index (string-length value))
               (memv (string-ref value index) '(#\space #\tab)))
          (loop (+ index 1))
          (substring value 0 index))))

  (define (fill-words words prefix width)
    (let-values ([(port extract) (open-string-output-port)])
      (put-string port prefix)
      (let loop ([remaining words] [column (string-length prefix)] [first? #t])
        (unless (null? remaining)
          (let* ([word (car remaining)]
                 [gap (if first? 0 1)]
                 [next (+ column gap (string-length word))])
            (if (and (not first?) (> next width))
                (begin
                  (put-char port #\newline)
                  (put-string port prefix)
                  (put-string port word)
                  (loop (cdr remaining) (+ (string-length prefix) (string-length word)) #f))
                (begin
                  (unless first? (put-char port #\space))
                  (put-string port word)
                  (loop (cdr remaining) next #f))))))
      (extract)))
)

