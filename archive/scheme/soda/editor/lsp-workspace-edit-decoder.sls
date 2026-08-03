(library (soda editor lsp-workspace-edit-decoder)
  (export make-lsp-workspace-text-edit
          lsp-workspace-text-edit?
          lsp-workspace-text-edit-resource
          lsp-workspace-text-edit-range
          lsp-workspace-text-edit-text
          decode-lsp-workspace-edits-for-resource
          decode-lsp-workspace-edits
          lsp-workspace-edit-resources)
  (import (rnrs)
          (soda editor lsp-protocol)
          (soda json))

  (define-record-type lsp-workspace-text-edit
    (fields resource range text))

  (define (decode-lsp-workspace-edits-for-resource uri values)
    (let ([resource
            (and
              (string? uri)
              (guard (condition [else #f])
                (lsp-uri-file-path uri)))])
      (and
        resource
        (json-array? values)
        (let loop ([remaining (json-array-values values)] [edits '()])
          (if (null? remaining)
              (reverse edits)
              (let ([value (car remaining)])
                (and
                  (json-object? value)
                  (let ([range
                          (guard (condition [else #f])
                            (lsp-range-from-json
                              (json-object-ref value "range" #f)))]
                        [text (json-object-ref value "newText" #f)])
                    (and
                      range
                      (string? text)
                      (loop
                        (cdr remaining)
                        (cons
                          (make-lsp-workspace-text-edit resource range text)
                          edits)))))))))))

  (define (decode-changes changes)
    (and
      (json-object? changes)
      (let loop ([entries (json-object-entries changes)] [edits '()])
        (if (null? entries)
            (reverse edits)
            (let ([resource-edits
                    (decode-lsp-workspace-edits-for-resource
                      (caar entries)
                      (cdar entries))])
              (and
                resource-edits
                (loop
                  (cdr entries)
                  (append (reverse resource-edits) edits))))))))

  (define (decode-document-changes changes)
    (and
      (json-array? changes)
      (let loop ([remaining (json-array-values changes)] [edits '()])
        (if (null? remaining)
            (reverse edits)
            (let ([change (car remaining)])
              (and
                (json-object? change)
                (let ([document (json-object-ref change "textDocument" #f)]
                      [document-edits (json-object-ref change "edits" #f)])
                  (and
                    (json-object? document)
                    (let ([resource-edits
                            (decode-lsp-workspace-edits-for-resource
                              (json-object-ref document "uri" #f)
                              document-edits)])
                      (and
                        resource-edits
                        (loop
                          (cdr remaining)
                          (append (reverse resource-edits) edits))))))))))))

  (define (decode-lsp-workspace-edits value)
    (and
      (json-object? value)
      (let ([changes (json-object-ref value "changes" #f)]
            [document-changes (json-object-ref value "documentChanges" #f)])
        (cond
          [(json-object? changes) (decode-changes changes)]
          [(json-array? document-changes)
           (decode-document-changes document-changes)]
          [else #f]))))

  (define (lsp-workspace-edit-resources edits)
    (reverse
      (fold-left
        (lambda (resources edit)
          (let ([resource (lsp-workspace-text-edit-resource edit)])
            (if (member resource resources)
                resources
                (cons resource resources))))
        '()
        edits))))
