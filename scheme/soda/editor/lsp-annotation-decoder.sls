(library (soda editor lsp-annotation-decoder)
  (export decode-lsp-diagnostic
          decode-lsp-semantic-tokens)
  (import (rnrs)
          (soda editor annotation)
          (soda editor buffer)
          (soda editor contract)
          (soda editor lsp-position)
          (soda editor lsp-protocol)
          (soda json))

  (define (diagnostic-severity value)
    (case value
      [(1) 'error]
      [(2) 'warning]
      [(3) 'info]
      [else 'hint]))

  (define (diagnostic-message value)
    (let ([message (json-object-ref value "message" #f)])
      (if (string? message) message "Language server diagnostic")))

  (define (decode-lsp-diagnostic buffer index value)
    (guard (condition [else #f])
      (let* ([range
               (lsp-range-from-json
                 (json-object-ref value "range" #f))]
             [start (lsp-buffer-offset-at buffer (lsp-range-start range))]
             [end (lsp-buffer-offset-at buffer (lsp-range-end range))]
             [message (diagnostic-message value)])
        (and
          start
          end
          (make-diagnostic
            (list
              index start end
              (json-object-ref value "code" json-null)
              message)
            start
            end
            (diagnostic-severity
              (json-object-ref value "severity" 4))
            message
            value)))))

  (define (semantic-token-face type)
    (cond
      [(member type '("namespace" "type" "class" "enum" "interface" "struct"))
       'type]
      [(string=? type "typeParameter") 'type.parameter]
      [(string=? type "parameter") 'variable.parameter]
      [(member type '("variable" "enumMember")) 'variable]
      [(member type '("property" "event")) 'property]
      [(member type '("function" "method" "macro")) 'function]
      [(member type '("keyword" "modifier")) 'keyword]
      [(string=? type "comment") 'comment]
      [(member type '("string" "regexp")) 'string]
      [(member type '("number" "boolean")) 'number]
      [(string=? type "operator") 'operator]
      [(string=? type "decorator") 'attribute]
      [else 'default]))

  (define (decode-lsp-semantic-tokens text-map types data)
    (and
      (list? types)
      (json-array? data)
      (let loop ([values (json-array-values data)]
                 [line 0]
                 [character 0]
                 [index 0]
                 [annotations '()])
        (cond
          [(null? values) (reverse annotations)]
          [(or
             (not (pair? values))
             (not (pair? (cdr values)))
             (not (pair? (cddr values)))
             (not (pair? (cdddr values)))
             (not (pair? (cddddr values))))
           #f]
          [else
           (let* ([delta-line (car values)]
                  [delta-start (cadr values)]
                  [token-length (caddr values)]
                  [type-index (cadddr values)]
                  [modifiers (car (cddddr values))]
                  [remaining (cdr (cddddr values))])
             (if
               (not
                 (and
                   (exact-non-negative-integer? delta-line)
                   (exact-non-negative-integer? delta-start)
                   (exact-non-negative-integer? token-length)
                   (exact-non-negative-integer? type-index)
                   (exact-non-negative-integer? modifiers)
                   (< type-index (length types))))
               #f
               (let* ([next-line (+ line delta-line)]
                      [next-character
                        (if (zero? delta-line)
                            (+ character delta-start)
                            delta-start)]
                      [start
                        (lsp-text-map-offset-at
                          text-map
                          (make-lsp-position next-line next-character))]
                      [end
                        (lsp-text-map-offset-at
                          text-map
                          (make-lsp-position
                            next-line
                            (+ next-character token-length)))])
                 (if
                   (or (not start) (not end))
                   #f
                   (let ([type (list-ref types type-index)])
                     (loop
                       remaining
                       next-line
                       next-character
                       (+ index 1)
                       (if
                         (zero? token-length)
                         annotations
                         (cons
                           (make-annotation
                             (list index start end type modifiers)
                             start end
                             'semantic-token
                             (semantic-token-face type)
                             #f #f
                             (list type modifiers))
                           annotations))))))))])))))
