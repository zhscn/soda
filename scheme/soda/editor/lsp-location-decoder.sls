(library (soda editor lsp-location-decoder)
  (export lsp-first-location
          decode-lsp-location-item
          decode-lsp-location-items
          decode-lsp-document-symbol-items
          decode-lsp-workspace-symbol-items)
  (import (rnrs)
          (soda editor buffer)
          (soda editor file)
          (soda editor location)
          (soda editor lsp-position)
          (soda editor lsp-protocol)
          (soda json))

  (define (lsp-first-location value)
    (cond
      [(json-array? value)
       (and (pair? (json-array-values value))
            (car (json-array-values value)))]
      [(json-object? value) value]
      [else #f]))

  (define (location-range location)
    (and
      (json-object? location)
      (let ([range
              (or (json-object-ref location "range" #f)
                  (json-object-ref location "targetSelectionRange" #f))])
        (guard (condition [else #f])
          (lsp-range-from-json range)))))

  (define (location-resource location)
    (and
      (json-object? location)
      (let ([uri
              (or (json-object-ref location "uri" #f)
                  (json-object-ref location "targetUri" #f))])
        (and (string? uri)
             (guard (condition [else #f])
               (lsp-uri-file-path uri))))))

  (define decode-lsp-location-item
    (case-lambda
      [(buffer-for-resource location)
       (decode-lsp-location-item buffer-for-resource location #f)]
      [(buffer-for-resource location language-context)
       (guard (condition [else #f])
         (let* ([path (location-resource location)]
                [range (location-range location)]
                [buffer (and path (buffer-for-resource path))])
           (and path range
             (if buffer
                 (let ([start
                         (lsp-buffer-offset-at buffer (lsp-range-start range))]
                       [end
                         (lsp-buffer-offset-at buffer (lsp-range-end range))])
                   (and start end
                        (make-location-item
                          (buffer-id buffer)
                          path
                          (buffer-revision buffer)
                          start
                          end
                          #f
                          location
                          language-context)))
                 (make-location-item
                   #f
                   path
                   0
                   0
                   0
                   #f
                   (list
                     (cons
                       'file-open-position
                       (make-file-utf16-position
                         (lsp-position-line (lsp-range-start range))
                         (lsp-position-character (lsp-range-start range))))
                     (cons
                       'file-open-end-position
                       (make-file-utf16-position
                         (lsp-position-line (lsp-range-end range))
                         (lsp-position-character (lsp-range-end range)))))
                   language-context)))))]))

  (define decode-lsp-location-items
    (case-lambda
      [(buffer-for-resource value)
       (decode-lsp-location-items buffer-for-resource value #f)]
      [(buffer-for-resource value language-context)
       (if (json-array? value)
           (let loop ([locations (json-array-values value)] [items '()])
             (if (null? locations)
                 (reverse items)
                 (let ([item
                         (decode-lsp-location-item
                           buffer-for-resource
                           (car locations)
                           language-context)])
                   (loop
                     (cdr locations)
                     (if item (cons item items) items)))))
           '())]))

  (define (document-symbol-location document-uri value)
    (and
      (json-object? value)
      (let ([range
              (or (json-object-ref value "selectionRange" #f)
                  (json-object-ref value "range" #f))])
        (and
          (json-object? range)
          (make-json-object
            (list
              (cons "uri" document-uri)
              (cons "range" range)))))))

  (define (decode-lsp-document-symbol-items
            buffer-for-resource document-uri value)
    (define (walk items value)
      (if (not (json-object? value))
          items
          (let* ([location
                   (or
                     (json-object-ref value "location" #f)
                     (document-symbol-location document-uri value))]
                 [item
                   (decode-lsp-location-item buffer-for-resource location)]
                 [with-item (if item (cons item items) items)]
                 [children (json-object-ref value "children" #f)])
            (if (json-array? children)
                (fold-left walk with-item (json-array-values children))
                with-item))))
    (if (json-array? value)
        (reverse
          (fold-left walk '() (json-array-values value)))
        '()))

  (define (decode-lsp-workspace-symbol-items buffer-for-resource value)
    (if (json-array? value)
        (let loop ([symbols (json-array-values value)] [items '()])
          (if (null? symbols)
              (reverse items)
              (let* ([symbol (car symbols)]
                     [location
                       (and
                         (json-object? symbol)
                         (json-object-ref symbol "location" #f))]
                     [item
                       (decode-lsp-location-item
                         buffer-for-resource location)])
                (loop
                  (cdr symbols)
                  (if item (cons item items) items)))))
        '())))
