(library (soda editor lsp-completion-decoder)
  (export decode-lsp-completion-item
          decode-lsp-completion-items
          lsp-completion-result-complete?)
  (import (rnrs)
          (soda editor buffer)
          (soda editor completion)
          (soda editor lsp-position)
          (soda editor lsp-protocol)
          (soda json))

  (define (range-offsets buffer value)
    (guard (condition [else #f])
      (let* ([range (lsp-range-from-json value)]
             [start (lsp-buffer-offset-at buffer (lsp-range-start range))]
             [end (lsp-buffer-offset-at buffer (lsp-range-end range))])
        (and start end (<= start end) (cons start end)))))

  (define (text-edit buffer value)
    (and
      (json-object? value)
      (let ([text (json-object-ref value "newText" #f)]
            [range (range-offsets buffer (json-object-ref value "range" #f))])
        (and range
             (string? text)
             (make-completion-text-edit (car range) (cdr range) text)))))

  (define (insert-replace-edit buffer value)
    (and
      (json-object? value)
      (let ([text (json-object-ref value "newText" #f)]
            [insert (range-offsets buffer (json-object-ref value "insert" #f))]
            [replace (range-offsets buffer (json-object-ref value "replace" #f))])
        (and
          (string? text)
          insert
          replace
          (make-completion-edit
            (make-completion-text-edit (car insert) (cdr insert) text)
            (make-completion-text-edit (car replace) (cdr replace) text)
            '())))))

  (define (additional-text-edits buffer value)
    (if (json-array? value)
        (let loop ([values (json-array-values value)] [edits '()])
          (if (null? values)
              (reverse edits)
              (let ([edit (text-edit buffer (car values))])
                (and edit (loop (cdr values) (cons edit edits))))))
        '()))

  (define (text-edits-disjoint? edits)
    (let ([ordered
            (list-sort
              (lambda (left right)
                (< (completion-text-edit-start left)
                   (completion-text-edit-start right)))
              edits)])
      (let loop ([remaining ordered])
        (or
          (null? remaining)
          (null? (cdr remaining))
          (and
            (<= (completion-text-edit-end (car remaining))
                (completion-text-edit-start (cadr remaining)))
            (loop (cdr remaining)))))))

  (define (text-edit-disjoint-from? edit others)
    (for-all
      (lambda (other)
        (cond
          [(< (completion-text-edit-start edit)
              (completion-text-edit-start other))
           (<= (completion-text-edit-end edit)
               (completion-text-edit-start other))]
          [(< (completion-text-edit-start other)
              (completion-text-edit-start edit))
           (<= (completion-text-edit-end other)
               (completion-text-edit-start edit))]
          [else #f]))
      others))

  (define (completion-edit buffer value)
    (let* ([raw (json-object-ref value "textEdit" #f)]
           [primary
             (or
               (let ([edit (text-edit buffer raw)])
                 (and edit (make-completion-edit edit edit '())))
               (insert-replace-edit buffer raw))]
           [additional
             (additional-text-edits
               buffer
               (json-object-ref value "additionalTextEdits" #f))])
      (and
        primary
        (let ([edit
                (make-completion-edit
                  (completion-edit-insert primary)
                  (completion-edit-replace primary)
                  additional)])
          (and
            (text-edits-disjoint? additional)
            (for-all
              (lambda (candidate)
                (text-edit-disjoint-from?
                  candidate
                  (list
                    (completion-edit-insert edit)
                    (completion-edit-replace edit))))
              additional)
            edit)))))

  (define (completion-documentation value)
    (let ([documentation (json-object-ref value "documentation" #f)])
      (cond
        [(string? documentation)
         (make-completion-documentation 'plaintext documentation)]
        [(json-object? documentation)
         (let ([contents (json-object-ref documentation "value" #f)]
               [kind (json-object-ref documentation "kind" "plaintext")])
           (and
             (string? contents)
             (make-completion-documentation
               (if (string=? kind "markdown") 'markdown 'plaintext)
               contents)))]
        [else #f])))

  (define (completion-item-default value defaults key)
    (if (or
          (json-object-has-key? value key)
          (not (json-object? defaults))
          (not (json-object-has-key? defaults key)))
        '()
        (list (cons key (json-object-ref defaults key #f)))))

  (define (default-text-edit value defaults)
    (and
      (not (json-object-has-key? value "textEdit"))
      (json-object? defaults)
      (let* ([range (json-object-ref defaults "editRange" #f)]
             [label (json-object-ref value "label" #f)]
             [text
               (or
                 (json-object-ref value "textEditText" #f)
                 (json-object-ref value "insertText" #f)
                 label)])
        (and
          (json-object? range)
          (string? text)
          (cond
            [(and
               (json-object-has-key? range "start")
               (json-object-has-key? range "end"))
             (make-json-object
               (list (cons "range" range) (cons "newText" text)))]
            [(and
               (json-object-has-key? range "insert")
               (json-object-has-key? range "replace"))
             (make-json-object
               (list
                 (cons "insert" (json-object-ref range "insert" #f))
                 (cons "replace" (json-object-ref range "replace" #f))
                 (cons "newText" text)))]
            [else #f])))))

  (define (with-defaults value defaults)
    (let ([edit (default-text-edit value defaults)])
      (make-json-object
        (append
          (json-object-entries value)
          (completion-item-default value defaults "insertTextFormat")
          (completion-item-default value defaults "data")
          (if edit (list (cons "textEdit" edit)) '())))))

  (define (decode-lsp-completion-item
            buffer id value resolved? provider-data)
    (let* ([label (json-object-ref value "label" #f)]
           [edit (and buffer (completion-edit buffer value))]
           [insert
             (let ([explicit (json-object-ref value "insertText" #f)])
               (cond
                 [(string? explicit) explicit]
                 [edit
                  (completion-text-edit-new-text
                    (completion-edit-insert edit))]
                 [else label]))]
           [filter (json-object-ref value "filterText" label)]
           [detail (json-object-ref value "detail" #f)]
           [sort (json-object-ref value "sortText" label)]
           [format (json-object-ref value "insertTextFormat" 1)])
      (and
        (integer? format)
        (exact? format)
        (= format 1)
        (string? label)
        (string? insert)
        (string? filter)
        (string? sort)
        (make-completion-item
          id 'lsp filter label insert 'choice detail edit sort #f resolved?
          (completion-documentation value)
          provider-data detail "LSP" 0))))

  (define (completion-values result)
    (cond
      [(json-array? result) (json-array-values result)]
      [(json-object? result)
       (let ([items (json-object-ref result "items" #f)])
         (if (json-array? items) (json-array-values items) '()))]
      [else '()]))

  (define (decode-lsp-completion-items
            buffer result item-context)
    (let ([defaults
            (and
              (json-object? result)
              (json-object-ref result "itemDefaults" #f))])
      (let loop ([values (completion-values result)] [index 0] [items '()])
        (if (null? values)
            (reverse items)
            (let ([value (car values)])
              (if (not (json-object? value))
                  (loop (cdr values) (+ index 1) items)
                  (let* ([effective (with-defaults value defaults)]
                         [label (json-object-ref effective "label" #f)]
                         [insert (json-object-ref effective "insertText" label)])
                    (let-values
                      ([(resolved? provider-data)
                        (item-context index effective)])
                      (let ([item
                              (and
                                (string? label)
                                (string? insert)
                                (decode-lsp-completion-item
                                  buffer
                                  (list index label insert)
                                  effective
                                  resolved?
                                  provider-data))])
                        (loop
                          (cdr values)
                          (+ index 1)
                          (if item (cons item items) items)))))))))))

  (define (lsp-completion-result-complete? result)
    (not
      (and
        (json-object? result)
        (eq? (json-object-ref result "isIncomplete" #f) #t)))))
