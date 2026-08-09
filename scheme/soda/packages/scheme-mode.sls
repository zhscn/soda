(library (soda packages scheme-mode)
  (export make-scheme-mode!
          scheme-mode-service?
          scheme-mode-spec
          scheme-mode-syntax-profile
          scheme-mode-keymap
          scheme-highlight-provider-key)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host analysis)
          (soda host buffer)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value)
          (soda packages analysis-ui)
          (soda packages buffer-mode)
          (soda packages file)
          (soda view decoration)
          (soda view plugin))

  (define-record-type
    (scheme-mode-service %make-scheme-mode-service scheme-mode-service?)
    (fields (immutable spec scheme-mode-spec)
            (immutable syntax-profile scheme-mode-syntax-profile)
            (immutable keymap scheme-mode-keymap)))

  (define scheme-symbol-characters
    (string->list "!$%&*/:<=>?^_~+-.@#"))

  (define scheme-highlight-provider-key 'scheme.syntax)

  (define scheme-keywords
    '("and" "begin" "case" "cond" "define" "define-record-type"
      "define-syntax" "delay" "do" "else" "guard" "if" "import"
      "lambda" "let" "let*" "let-values" "letrec" "letrec*"
      "letrec-values" "library" "or" "parameterize" "quasiquote"
      "quote" "set!" "syntax-rules" "unless" "unquote"
      "unquote-splicing" "when"))

  (define (ascii-whitespace? byte)
    (or (= byte 9) (= byte 10) (= byte 11) (= byte 12) (= byte 13) (= byte 32)))

  (define (token-delimiter? byte)
    (or (ascii-whitespace? byte)
        (memv byte '(34 39 40 41 44 59 91 93 96 123 125))))

  (define (digit-byte? byte)
    (and (<= 48 byte) (<= byte 57)))

  (define (token-number? bytes from to)
    (and (< from to)
         (or (digit-byte? (bytevector-u8-ref bytes from))
             (and (< (+ from 1) to)
                  (memv (bytevector-u8-ref bytes from) '(43 45))
                  (digit-byte? (bytevector-u8-ref bytes (+ from 1)))))))

  (define (token-string bytes from to)
    (guard (ignored [else #f])
      (let ([copy (make-bytevector (- to from))])
        (bytevector-copy! bytes from copy 0 (- to from))
        (utf8->string copy))))

  (define (keyword-token? bytes from to)
    (let ([token (token-string bytes from to)])
      (and token (member token scheme-keywords))))

  (define (definition-keyword? bytes from to)
    (let ([token (token-string bytes from to)])
      (and token (or (string=? token "define")
                     (string=? token "define-syntax")
                     (string=? token "define-record-type")))))

  (define (line-start-before bytes offset)
    (let loop ([position (min offset (bytevector-length bytes))])
      (if (or (zero? position)
              (= (bytevector-u8-ref bytes (- position 1)) 10))
          position
          (loop (- position 1)))))

  (define (changed-start request bytes)
    (let ([ranges
           (range-set-ranges (analysis-request-changed-ranges request))])
      (if (null? ranges)
          0
          (line-start-before bytes (range-value-from (car ranges))))))

  (define (scan-line-comment bytes start)
    (let ([length (bytevector-length bytes)])
      (let loop ([position (+ start 1)])
        (if (or (= position length)
                (= (bytevector-u8-ref bytes position) 10))
            position
            (loop (+ position 1))))))

  (define (scan-string bytes start)
    (let ([length (bytevector-length bytes)])
      (let loop ([position (+ start 1)] [escaped? #f])
        (if (= position length)
            position
            (let ([byte (bytevector-u8-ref bytes position)])
              (cond
                [escaped? (loop (+ position 1) #f)]
                [(= byte 92) (loop (+ position 1) #t)]
                [(= byte 34) (+ position 1)]
                [else (loop (+ position 1) #f)]))))))

  (define (scan-block-comment bytes start)
    (let ([length (bytevector-length bytes)])
      (let loop ([position (+ start 2)] [depth 1])
        (cond
          [(>= position length) length]
          [(and (< (+ position 1) length)
                (= (bytevector-u8-ref bytes position) 35)
                (= (bytevector-u8-ref bytes (+ position 1)) 124))
           (loop (+ position 2) (+ depth 1))]
          [(and (< (+ position 1) length)
                (= (bytevector-u8-ref bytes position) 124)
                (= (bytevector-u8-ref bytes (+ position 1)) 35))
           (if (= depth 1)
               (+ position 2)
               (loop (+ position 2) (- depth 1)))]
          [else (loop (+ position 1) depth)]))))

  (define (scan-token bytes start)
    (let ([length (bytevector-length bytes)])
      (let loop ([position (+ start 1)])
        (if (or (= position length)
                (token-delimiter? (bytevector-u8-ref bytes position))
                (and (< (+ position 1) length)
                     (= (bytevector-u8-ref bytes position) 35)
                     (= (bytevector-u8-ref bytes (+ position 1)) 124)))
            position
            (loop (+ position 1))))))

  (define (highlight-range from to kind)
    (make-range-value from to kind 'after 'before 'drop #f))

  ;; Lexical state is replayed from the start so a multiline string or nested
  ;; block comment remains correct.  Only ranges at and after REPLACE-FROM are
  ;; constructed; the previous immutable prefix is retained by identity.
  (define (scan-scheme-ranges bytes replace-from)
    (let ([length (bytevector-length bytes)])
      (let loop ([position 0] [definition? #f] [ranges '()])
        (if (= position length)
            (reverse ranges)
            (let ([byte (bytevector-u8-ref bytes position)])
              (define (continue to next-definition kind)
                (loop to next-definition
                      (if (and kind (> to replace-from))
                          (cons (highlight-range position to kind) ranges)
                          ranges)))
              (cond
                [(ascii-whitespace? byte)
                 (loop (+ position 1) definition? ranges)]
                [(= byte 59)
                 (continue (scan-line-comment bytes position) definition? 'comment)]
                [(and (< (+ position 1) length) (= byte 35)
                      (= (bytevector-u8-ref bytes (+ position 1)) 124))
                 (continue (scan-block-comment bytes position) definition? 'comment)]
                [(= byte 34)
                 (continue (scan-string bytes position) #f 'string)]
                [(memv byte '(40 91 123))
                 (loop (+ position 1) definition? ranges)]
                [(memv byte '(39 41 44 96 93 125))
                 (loop (+ position 1) #f ranges)]
                [else
                 (let* ([to (scan-token bytes position)]
                        [kind
                         (cond
                           [definition? 'definition]
                           [(token-number? bytes position to) 'number]
                           [(keyword-token? bytes position to) 'keyword]
                           [else 'symbol])])
                   (continue
                     to (and (definition-keyword? bytes position to) #t) kind))]))))))

  (define (make-scheme-highlight-provider host)
    (make-analysis-provider
      scheme-highlight-provider-key
      (lambda (request publish!)
        (let* ([bytes (snapshot-bytevector (analysis-request-snapshot request))]
               [replace-from (changed-start request bytes)]
               [previous
                (package-host-analysis-result
                  host (analysis-request-buffer-id request)
                  scheme-highlight-provider-key #f)]
               [prefix
                (if previous
                    (filter
                      (lambda (range) (<= (range-value-to range) replace-from))
                      (range-set-ranges (analysis-result-ranges previous)))
                    '())]
               [ranges
                (make-range-set
                  (append prefix (scan-scheme-ranges bytes replace-from)))])
          (publish!
            (make-analysis-result
              scheme-highlight-provider-key
              (analysis-request-buffer-id request)
              (analysis-request-revision request)
              ranges
              (list (cons 'language 'scheme)
                    (cons 'replaced-from replace-from))))
          #f))))

  (define (scheme-highlight-decoration range metadata)
    (make-face-decoration
      (case (range-value-value range)
        [(comment) 'syntax.comment]
        [(string) 'syntax.string]
        [(number) 'syntax.number]
        [(keyword) 'syntax.keyword]
        [(definition) 'syntax.definition]
        [else 'syntax.symbol])
      10))

  (define (scheme-classifier character)
    (let ([category (char-general-category character)])
      (cond
        [(char-whitespace? character) 'whitespace]
        [(or (char-alphabetic? character) (char-numeric? character)
             (memq category '(Mn Mc Me Pc)))
         'word]
        [(memv character scheme-symbol-characters) 'symbol]
        [else 'punctuation])))

  (define (make-scheme-syntax-profile)
    (make-syntax-profile
      'scheme scheme-classifier
      (list (cons #\( #\)) (cons #\[ #\]) (cons #\{ #\}))
      (list ";") (list (cons "#|" "|#")) (list #\") #\\))

  (define (activate-scheme-mode context spec)
    (let* ([state (command-context-buffer-state context)]
           [length (snapshot-byte-size (buffer-state-document state))])
      (make-transaction-spec
        (command-context-buffer-id context) (command-context-view-id context)
        (buffer-state-generation state) (make-change-set length '()) #f
        (list (set-buffer-major-mode-effect spec)) '())))

  (define (make-scheme-mode! host files owner parent)
    (unless (and (package-host? host) (file-service? files)
                 (owner? owner) (mode-spec? parent)
                 (eq? (mode-spec-kind parent) 'major))
      (assertion-violation 'make-scheme-mode!
                           "expected PackageHost, FileService, owner, and parent major mode"))
    (let* ([runtime (package-host-command-runtime host)]
           [profile (make-scheme-syntax-profile)]
           [keymap (make-keymap 'scheme-mode)]
           [highlight-plugin
            (make-analysis-decoration-plugin
              host scheme-highlight-provider-key scheme-highlight-decoration)]
           [spec
            (make-mode-spec
              'scheme-mode 'major "Scheme" parent
              (list
                (make-buffer-syntax-profile-extension profile)
                (make-facet-provider view-plugins-facet (list highlight-plugin))
                (make-buffer-input-layer-extension
                  (list (make-input-layer 'major keymap #f 'accept))))
              '(scheme) "Scheme"
              (lambda (buffer instance-owner)
                (package-host-request-analysis!
                  host (buffer-id buffer) scheme-highlight-provider-key))
              (lambda (buffer instance-owner)
                (package-host-stop-analysis!
                  host (buffer-id buffer) scheme-highlight-provider-key))
              (make-comment-syntax "; " "#|" "|#"))]
           [service (%make-scheme-mode-service spec profile keymap)])
      (package-host-register-analysis-provider!
        host owner (make-scheme-highlight-provider host))
      (define-command
        runtime owner 'scheme-mode.activate (context)
        "Select Scheme major mode for the active Buffer." 'mode
        (activate-scheme-mode context spec))
      (for-each
        (lambda (suffix) (file-service-register-mode! files owner suffix spec))
        '(".scm" ".ss" ".sls"))
      service))
)
