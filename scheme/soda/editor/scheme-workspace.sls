(library (soda editor scheme-workspace)
  (export make-scheme-workspace-index
          scheme-workspace-index?
          scheme-workspace-generation
          scheme-workspace-sync-editor!
          scheme-workspace-refresh-buffer!
          scheme-workspace-index-source!
          scheme-workspace-remove-source!
          scheme-workspace-snapshot-for-buffer
          scheme-workspace-references
          scheme-workspace-reference?
          scheme-workspace-reference-buffer-id
          scheme-workspace-reference-resource
          scheme-workspace-reference-revision
          scheme-workspace-reference-use
          scheme-workspace-diagnostics
          scheme-workspace-diagnostic?
          scheme-workspace-diagnostic-buffer-id
          scheme-workspace-diagnostic-resource
          scheme-workspace-diagnostic-revision
          scheme-workspace-diagnostic-excerpt
          scheme-workspace-diagnostic-diagnostic
          scheme-workspace-text-edit?
          scheme-workspace-text-edit-buffer-id
          scheme-workspace-text-edit-resource
          scheme-workspace-text-edit-revision
          scheme-workspace-text-edit-start
          scheme-workspace-text-edit-end
          scheme-workspace-text-edit-text
          scheme-workspace-rename-edits
          scheme-workspace-document-symbols
          scheme-workspace-symbols
          scheme-workspace-symbol?
          scheme-workspace-symbol-key
          scheme-workspace-symbol-name
          scheme-workspace-symbol-kind
          scheme-workspace-symbol-buffer-id
          scheme-workspace-symbol-resource
          scheme-workspace-symbol-revision
          scheme-workspace-symbol-start
          scheme-workspace-symbol-end
          scheme-workspace-symbol-definition)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor scheme-api-indexer)
          (soda editor scheme-query)
          (soda editor scheme-semantics)
          (soda editor state))

  (define-record-type scheme-workspace-document
    (fields
      buffer-id
      resource
      document-id
      revision
      bytes
      (mutable snapshot)
      (mutable needs-analysis?)))

  (define-record-type
    (scheme-workspace-index
      %make-scheme-workspace-index
      scheme-workspace-index?)
    (fields
      documents
      sources
      references
      (mutable generation)
      (mutable library-index)
      (mutable library-catalog)
      (mutable catalog-dirty?)
      (mutable dirty?
               scheme-workspace-index-dirty?
               scheme-workspace-index-dirty?-set!)))

  (define-record-type scheme-workspace-reference
    (fields buffer-id resource revision use))

  (define-record-type scheme-workspace-diagnostic
    (fields buffer-id resource revision excerpt diagnostic))

  (define-record-type scheme-workspace-text-edit
    (fields buffer-id resource revision start end text))

  (define-record-type scheme-workspace-symbol
    (fields
      key
      name
      kind
      buffer-id
      resource
      revision
      start
      end
      definition))

  (define (make-scheme-workspace-index)
    (%make-scheme-workspace-index
      (make-eqv-hashtable)
      (make-hashtable string-hash string=?)
      (make-hashtable
        equal-hash
        scheme-definition-id=?)
      0
      '()
      '()
      #t
      #t))

  (define (scheme-workspace-generation index)
    (require-index 'scheme-workspace-generation index)
    (scheme-workspace-index-generation index))

  (define (require-index who value)
    (unless (scheme-workspace-index? value)
      (assertion-violation
        who
        "expected a Scheme workspace index"
        value)))

  (define (current-document? document buffer)
    (and
      document
      (=
        (scheme-workspace-document-revision document)
        (buffer-revision buffer))
      (=
        (scheme-workspace-document-document-id document)
        (document-id (buffer-document buffer)))
      (equal?
        (scheme-workspace-document-resource document)
        (buffer-resource buffer))))

  (define (all-workspace-documents index)
    (let-values
      ([(ids buffer-documents)
        (hashtable-entries
          (scheme-workspace-index-documents index))]
       [(resources source-documents)
        (hashtable-entries
          (scheme-workspace-index-sources index))])
      (append
        (vector->list buffer-documents)
        (vector->list source-documents))))

  (define (workspace-documents index)
    (let-values
      ([(ids buffer-documents)
        (hashtable-entries
          (scheme-workspace-index-documents index))]
       [(resources source-documents)
        (hashtable-entries
          (scheme-workspace-index-sources index))])
      (let* ([buffers (vector->list buffer-documents)]
             [open-resources
               (make-hashtable string-hash string=?)])
        (for-each
          (lambda (document)
            (let ([resource
                    (scheme-workspace-document-resource
                      document)])
              (when (string? resource)
                (hashtable-set!
                  open-resources resource #t))))
          buffers)
        (append
          buffers
          (filter
            (lambda (document)
              (let ([resource
                      (scheme-workspace-document-resource
                        document)])
                (or
                  (not (string? resource))
                  (not
                    (hashtable-contains?
                      open-resources
                      resource)))))
            (vector->list source-documents))))))

  (define (sync-buffer! index buffer)
    (let* ([table
             (scheme-workspace-index-documents index)]
           [id (buffer-id buffer)]
           [current (hashtable-ref table id #f)])
      (cond
        [(not (scheme-buffer? buffer))
         (when current
           (hashtable-delete! table id)
           (scheme-workspace-index-catalog-dirty?-set!
             index #t)
           (scheme-workspace-index-dirty?-set!
             index #t))]
        [(not (current-document? current buffer))
         (let* ([bytes
                  (buffer-scheme-source-bytes buffer)]
                [snapshot
                  (make-scheme-semantic-snapshot-with-library-index
                    (document-id (buffer-document buffer))
                    (buffer-revision buffer)
                    bytes
                    (scheme-workspace-index-library-index
                      index)
                    (scheme-workspace-index-library-catalog
                      index))])
           (hashtable-set!
             table
             id
             (make-scheme-workspace-document
               id
               (buffer-resource buffer)
               (scheme-semantic-snapshot-document-id snapshot)
               (scheme-semantic-snapshot-revision snapshot)
               bytes
               snapshot
               #t))
           (scheme-workspace-index-catalog-dirty?-set!
             index #t)
           (scheme-workspace-index-dirty?-set!
             index #t))])))

  (define (buffer-scheme-source-bytes buffer)
    (let ([snapshot
            (document-snapshot
              (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text->bytevector text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (catalog-sources index)
    (filter
      (lambda (source) source)
      (map
        (lambda (document)
          (let ([resource
                  (scheme-workspace-document-resource
                    document)])
            (and
              (string? resource)
              (cons
                resource
                (scheme-workspace-document-bytes
                  document)))))
        (workspace-documents index))))

  (define (refresh-document-snapshot!
            document
            library-index
            library-catalog)
    (scheme-workspace-document-snapshot-set!
      document
      (make-scheme-semantic-snapshot-with-library-index
        (scheme-workspace-document-document-id document)
        (scheme-workspace-document-revision document)
        (scheme-workspace-document-bytes document)
        library-index
        library-catalog))
    (scheme-workspace-document-needs-analysis?-set!
      document #f))

  (define (library-index-table index-entries)
    (let ([table (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (entry)
          (let ([library (caddr entry)])
            (hashtable-set!
              table library
              (append
                (hashtable-ref table library '())
                (list entry)))))
        index-entries)
      table))

  (define (changed-library-names
            old-index
            new-index
            old-catalog
            new-catalog)
    (let ([old-table (library-index-table old-index)]
          [new-table (library-index-table new-index)]
          [names (make-hashtable equal-hash equal?)]
          [result '()])
      (for-each
        (lambda (entry)
          (hashtable-set! names (caddr entry) #t))
        (append old-index new-index))
      (for-each
        (lambda (library)
          (hashtable-set! names library #t))
        (append old-catalog new-catalog))
      (let-values ([(keys values) (hashtable-entries names)])
        (let loop ([position 0])
          (when (< position (vector-length keys))
            (let ([library (vector-ref keys position)])
              (unless
                (and
                  (equal?
                    (hashtable-ref old-table library '())
                    (hashtable-ref new-table library '()))
                  (eq?
                    (and (member library old-catalog) #t)
                    (and (member library new-catalog) #t)))
                (set! result (cons library result))))
            (loop (+ position 1)))))
      result))

  (define (document-imports-library?
            document
            libraries)
    (exists
      (lambda (library)
        (member
          library
          (scheme-semantic-snapshot-imports
            (scheme-workspace-document-snapshot
              document))))
      libraries))

  (define (ensure-library-index! index)
    (when
      (scheme-workspace-index-catalog-dirty? index)
      (let* ([sources (catalog-sources index)]
             [library-index
              (scheme-sources-api-index
                sources)]
             [library-catalog
              (scheme-sources-library-index
                sources)])
        (let ([changed-libraries
                (changed-library-names
                  (scheme-workspace-index-library-index index)
                  library-index
                  (scheme-workspace-index-library-catalog index)
                  library-catalog)]
              [active-documents
                (workspace-documents index)])
          (scheme-workspace-index-library-index-set!
            index library-index)
          (scheme-workspace-index-library-catalog-set!
            index library-catalog)
          (when (pair? changed-libraries)
            (scheme-workspace-index-generation-set!
              index
              (+ 1
                (scheme-workspace-index-generation
                  index))))
          (for-each
            (lambda (document)
              (when
                (or
                  (scheme-workspace-document-needs-analysis?
                    document)
                  (document-imports-library?
                    document
                    changed-libraries))
                (if
                  (memq document active-documents)
                  (refresh-document-snapshot!
                    document
                    library-index
                    library-catalog)
                  (scheme-workspace-document-needs-analysis?-set!
                    document #t))))
            (all-workspace-documents index))
          (scheme-workspace-index-catalog-dirty?-set!
            index #f)
          (scheme-workspace-index-dirty?-set!
            index #t)))))

  (define (add-reference! table id reference)
    (hashtable-set!
      table
      id
      (cons
        reference
        (hashtable-ref table id '()))))

  (define (rebuild-references! index)
    (let ([table
            (scheme-workspace-index-references index)])
      (hashtable-clear! table)
      (for-each
        (lambda (document)
          (for-each
            (lambda (use)
              (let ([reference
                      (make-scheme-workspace-reference
                        (scheme-workspace-document-buffer-id
                          document)
                        (scheme-workspace-document-resource
                          document)
                        (scheme-workspace-document-revision
                          document)
                        use)])
                (for-each
                  (lambda (id)
                    (add-reference! table id reference))
                  (scheme-use-resolution use))))
            (scheme-semantic-snapshot-uses
              (scheme-workspace-document-snapshot
                document))))
        (workspace-documents index))
      (scheme-workspace-index-dirty?-set!
        index #f)))

  (define (scheme-workspace-sync-editor! index editor)
    (require-index 'scheme-workspace-sync-editor! index)
    (let ([live (make-eqv-hashtable)])
      (for-each
        (lambda (buffer)
          (hashtable-set! live (buffer-id buffer) #t)
          (sync-buffer! index buffer))
        (editor-buffers editor))
      (let-values
        ([(ids documents)
          (hashtable-entries
            (scheme-workspace-index-documents index))])
        (let loop ([position 0])
          (when (< position (vector-length ids))
            (let ([id (vector-ref ids position)])
              (unless (hashtable-contains? live id)
                (hashtable-delete!
                  (scheme-workspace-index-documents index)
                  id)
                (scheme-workspace-index-catalog-dirty?-set!
                  index #t)
                (scheme-workspace-index-dirty?-set!
                  index #t)))
            (loop (+ position 1))))))
    (ensure-library-index! index)
    (when (scheme-workspace-index-dirty? index)
      (rebuild-references! index))
    index)

  (define (scheme-workspace-refresh-buffer! index buffer)
    (require-index 'scheme-workspace-refresh-buffer! index)
    (unless (buffer? buffer)
      (assertion-violation
        'scheme-workspace-refresh-buffer!
        "expected a buffer"
        buffer))
    (sync-buffer! index buffer)
    (let ([document
            (hashtable-ref
              (scheme-workspace-index-documents index)
              (buffer-id buffer)
              #f)])
      (and
        document
        (scheme-workspace-document-snapshot document))))

  (define (scheme-workspace-index-source!
            index
            resource
            document-id
            revision
            bytes)
    (require-index 'scheme-workspace-index-source! index)
    (unless
      (and
        (string? resource)
        (integer? document-id)
        (exact? document-id)
        (not (negative? document-id))
        (integer? revision)
        (exact? revision)
        (not (negative? revision))
        (bytevector? bytes))
      (assertion-violation
        'scheme-workspace-index-source!
        "invalid Scheme project source"
        resource
        document-id
        revision))
    (let* ([snapshot
             (make-scheme-semantic-snapshot-with-library-index
               document-id
               revision
               bytes
               (scheme-workspace-index-library-index
                 index)
               (scheme-workspace-index-library-catalog
                 index))]
           [document
             (make-scheme-workspace-document
               #f
               resource
               document-id
               revision
               bytes
               snapshot
               #t)])
      (hashtable-set!
        (scheme-workspace-index-sources index)
        resource
        document)
      (scheme-workspace-index-dirty?-set! index #t)
      (scheme-workspace-index-catalog-dirty?-set!
        index #t)
      snapshot))

  (define (scheme-workspace-remove-source! index resource)
    (require-index 'scheme-workspace-remove-source! index)
    (unless (string? resource)
      (assertion-violation
        'scheme-workspace-remove-source!
        "resource must be a string"
        resource))
    (when
      (hashtable-contains?
        (scheme-workspace-index-sources index)
        resource)
      (hashtable-delete!
        (scheme-workspace-index-sources index)
        resource)
      (scheme-workspace-index-catalog-dirty?-set!
        index #t)
      (scheme-workspace-index-dirty?-set! index #t))
    index)

  (define (scheme-workspace-snapshot-for-buffer
            index
            buffer)
    (require-index
      'scheme-workspace-snapshot-for-buffer
      index)
    (sync-buffer! index buffer)
    (ensure-library-index! index)
    (let ([document
            (hashtable-ref
              (scheme-workspace-index-documents index)
              (buffer-id buffer)
              #f)])
      (and
        document
        (scheme-workspace-document-snapshot document))))

  (define (index-definition-equivalent?
            definition
            resource
            candidate)
    (let ([id (scheme-definition-id candidate)])
      (and
        (eq? (scheme-definition-id-source id) 'index)
        (string? resource)
        (equal?
          (scheme-definition-id-document-id id)
          resource)
        (equal?
          (scheme-definition-start candidate)
          (scheme-definition-start definition))
        (string=?
          (scheme-definition-id-name id)
          (scheme-definition-id-name
            (scheme-definition-id definition))))))

  (define (document-definition-equivalent?
            definition
            resource
            candidate-document)
    (and
      (string? resource)
      (equal?
        resource
        (scheme-workspace-document-resource
          candidate-document))
      (exists
        (lambda (candidate)
          (and
            (=
              (scheme-definition-start candidate)
              (scheme-definition-start definition))
            (string=?
              (scheme-definition-name candidate)
              (scheme-definition-id-name
                (scheme-definition-id definition)))))
        (scheme-semantic-snapshot-root-definitions
          (scheme-workspace-document-snapshot
            candidate-document)))))

  (define (equivalent-definition-ids
            index
            definition)
    (let* ([id (scheme-definition-id definition)]
           [source (scheme-definition-id-source id)]
           [resource
             (and
               (eq? source 'index)
               (scheme-definition-id-document-id id))]
           [result (list id)])
      (when (eq? source 'document)
        (let ([document
                (find
                  (lambda (candidate)
                    (=
                      (scheme-workspace-document-document-id
                        candidate)
                      (scheme-definition-id-document-id id)))
                  (workspace-documents index))])
          (when document
            (set! resource
              (scheme-workspace-document-resource document))
            (for-each
              (lambda (candidate)
                (when
                  (index-definition-equivalent?
                    definition resource candidate)
                  (set! result
                    (cons
                      (scheme-definition-id candidate)
                      result))))
              (append
                scheme-index-definitions
                (apply
                  append
                  (map
                    (lambda (candidate-document)
                      (scheme-semantic-snapshot-visible-index-definitions
                        (scheme-workspace-document-snapshot
                          candidate-document)))
                    (workspace-documents index))))))))
      (when (and (eq? source 'index) (string? resource))
        (for-each
          (lambda (document)
            (when
              (document-definition-equivalent?
                definition resource document)
              (let ([candidate
                      (find
                        (lambda (candidate)
                          (and
                            (=
                              (scheme-definition-start candidate)
                              (scheme-definition-start definition))
                            (string=?
                              (scheme-definition-name candidate)
                              (scheme-definition-id-name
                                (scheme-definition-id definition)))))
                        (scheme-semantic-snapshot-root-definitions
                          (scheme-workspace-document-snapshot
                            document)))])
                (set! result
                  (cons
                    (scheme-definition-id candidate)
                    result)))))
          (workspace-documents index)))
      result))

  (define (same-reference? left right)
    (let ([left-use
            (scheme-workspace-reference-use left)]
          [right-use
            (scheme-workspace-reference-use right)])
      (and
        (equal?
          (scheme-workspace-reference-buffer-id left)
          (scheme-workspace-reference-buffer-id right))
        (equal?
          (scheme-workspace-reference-resource left)
          (scheme-workspace-reference-resource right))
        (=
          (scheme-use-start left-use)
          (scheme-use-start right-use))
        (=
          (scheme-use-end left-use)
          (scheme-use-end right-use)))))

  (define (deduplicate-references references)
    (fold-left
      (lambda (result reference)
        (if
          (exists
            (lambda (candidate)
              (same-reference? candidate reference))
            result)
          result
          (cons reference result)))
      '()
      references))

  (define (scheme-workspace-references
            index
            editor
            definition)
    (require-index 'scheme-workspace-references index)
    (scheme-workspace-sync-editor! index editor)
    (let ([ids
            (equivalent-definition-ids index definition)])
      (deduplicate-references
        (apply
          append
          (map
            (lambda (id)
              (hashtable-ref
                (scheme-workspace-index-references index)
                id
                '()))
            ids)))))

  (define (line-start-in-bytes bytes offset)
    (let loop ([position (min offset (bytevector-length bytes))])
      (if
        (or
          (zero? position)
          (memv
            (bytevector-u8-ref bytes (- position 1))
            '(10 13)))
        position
        (loop (- position 1)))))

  (define (line-end-in-bytes bytes offset)
    (let ([size (bytevector-length bytes)])
      (let loop ([position (min offset size)])
        (if
          (or
            (= position size)
            (memv
              (bytevector-u8-ref bytes position)
              '(10 13)))
          position
          (loop (+ position 1))))))

  (define (diagnostic-excerpt bytes diagnostic)
    (let* ([start
             (line-start-in-bytes
               bytes
               (scheme-diagnostic-start diagnostic))]
           [end
             (line-end-in-bytes
               bytes
               (scheme-diagnostic-end diagnostic))]
           [result
             (make-bytevector (- end start))])
      (bytevector-copy!
        bytes start result 0 (- end start))
      (guard (condition [else #f])
        (utf8->string result))))

  (define (workspace-document-diagnostics document)
    (map
      (lambda (diagnostic)
        (make-scheme-workspace-diagnostic
          (scheme-workspace-document-buffer-id document)
          (scheme-workspace-document-resource document)
          (scheme-workspace-document-revision document)
          (diagnostic-excerpt
            (scheme-workspace-document-bytes document)
            diagnostic)
          diagnostic))
      (scheme-semantic-snapshot-diagnostics
        (scheme-workspace-document-snapshot document))))

  (define (diagnostic-source-before? left right)
    (let ([left-resource
            (scheme-workspace-diagnostic-resource left)]
          [right-resource
            (scheme-workspace-diagnostic-resource right)])
      (cond
        [(and
           (string? left-resource)
           (string? right-resource)
           (not (string=? left-resource right-resource)))
         (string<? left-resource right-resource)]
        [(string? left-resource)
         (not (string? right-resource))]
        [(string? right-resource) #f]
        [(not
           (equal?
             (scheme-workspace-diagnostic-buffer-id left)
             (scheme-workspace-diagnostic-buffer-id right)))
         (<
           (scheme-workspace-diagnostic-buffer-id left)
           (scheme-workspace-diagnostic-buffer-id right))]
        [else
         (let ([left-diagnostic
                 (scheme-workspace-diagnostic-diagnostic left)]
               [right-diagnostic
                 (scheme-workspace-diagnostic-diagnostic right)])
           (or
             (<
               (scheme-diagnostic-start left-diagnostic)
               (scheme-diagnostic-start right-diagnostic))
             (and
               (=
                 (scheme-diagnostic-start left-diagnostic)
                 (scheme-diagnostic-start right-diagnostic))
               (<
                 (scheme-diagnostic-end left-diagnostic)
                 (scheme-diagnostic-end right-diagnostic)))))])))

  (define (scheme-workspace-diagnostics index editor)
    (require-index 'scheme-workspace-diagnostics index)
    (scheme-workspace-sync-editor! index editor)
    (list-sort
      diagnostic-source-before?
      (apply
        append
        (map
          workspace-document-diagnostics
          (workspace-documents index)))))

  (define (definition-owner-document index definition)
    (let* ([id (scheme-definition-id definition)]
           [documents (workspace-documents index)])
      (case (scheme-definition-id-source id)
        [(document)
         (or
           (find
             (lambda (document)
               (and
                 (=
                   (scheme-workspace-document-document-id document)
                   (scheme-definition-id-document-id id))
                 (=
                   (scheme-workspace-document-revision document)
                   (scheme-definition-id-revision id))))
             documents)
           (let ([indexed-document
                   (find
                     (lambda (document)
                       (and
                         (=
                           (scheme-workspace-document-document-id document)
                           (scheme-definition-id-document-id id))
                         (=
                           (scheme-workspace-document-revision document)
                           (scheme-definition-id-revision id))))
                     (all-workspace-documents index))])
             (and
               indexed-document
               (let ([resource
                       (scheme-workspace-document-resource
                         indexed-document)])
                 (and
                   (string? resource)
                   (find
                     (lambda (document)
                       (and
                         (equal?
                           resource
                           (scheme-workspace-document-resource document))
                         (document-definition-equivalent?
                           definition resource document)))
                     documents))))))]
        [(index)
         (let ([resource
                 (scheme-definition-id-document-id id)])
           (and
             (string? resource)
             (find
               (lambda (document)
                 (and
                   (equal?
                     resource
                     (scheme-workspace-document-resource document))
                   (document-definition-equivalent?
                     definition resource document)))
               documents)))]
        [else #f])))

  (define (definition-in-document document definition)
    (find
      (lambda (candidate)
        (and
          (=
            (scheme-definition-start candidate)
            (scheme-definition-start definition))
          (string=?
            (scheme-definition-name candidate)
            (scheme-definition-id-name
              (scheme-definition-id definition)))))
      (scheme-semantic-snapshot-definitions
        (scheme-workspace-document-snapshot document))))

  (define (definition-library-name
            index
            definition
            owner)
    (or
      (scheme-definition-library definition)
      (let ([resource
              (scheme-workspace-document-resource owner)])
        (and
          (string? resource)
          (let ([entry
                  (find
                    (lambda (entry)
                      (and
                        (string=?
                          (list-ref entry 0)
                          (scheme-definition-id-name
                            (scheme-definition-id definition)))
                        (equal? (list-ref entry 3) resource)
                        (equal?
                          (list-ref entry 4)
                          (scheme-definition-start definition))))
                    (scheme-workspace-index-library-index index))])
            (and entry (list-ref entry 2)))))))

  (define (document-for-reference index reference)
    (let ([buffer-id
            (scheme-workspace-reference-buffer-id reference)]
          [resource
            (scheme-workspace-reference-resource reference)]
          [revision
            (scheme-workspace-reference-revision reference)])
      (find
        (lambda (document)
          (and
            (=
              revision
              (scheme-workspace-document-revision document))
            (if
              buffer-id
              (equal?
                buffer-id
                (scheme-workspace-document-buffer-id document))
              (and
                (string? resource)
                (equal?
                  resource
                  (scheme-workspace-document-resource document))))))
        (workspace-documents index))))

  (define (document-text-edit
            document
            start
            end
            text)
    (make-scheme-workspace-text-edit
      (scheme-workspace-document-buffer-id document)
      (scheme-workspace-document-resource document)
      (scheme-workspace-document-revision document)
      start
      end
      text))

  (define (document-range-string document start end)
    (let ([bytes
            (scheme-workspace-document-bytes document)])
      (unless
        (and
          (integer? start)
          (exact? start)
          (>= start 0)
          (integer? end)
          (exact? end)
          (>= end 0)
          (<= start end)
          (<= end (bytevector-length bytes)))
        (assertion-violation
          'scheme-workspace-rename-edits
          "definition source range is stale"
          start end))
      (let* ([size (- end start)]
             [range (make-bytevector size)])
        (bytevector-copy! bytes start range 0 size)
        (utf8->string range))))

  (define (replacement-text-edit document replacement)
    (document-text-edit
      document
      (scheme-rename-replacement-start replacement)
      (scheme-rename-replacement-end replacement)
      (scheme-rename-replacement-text replacement)))

  (define (mapping-ref mappings name)
    (let loop ([remaining mappings] [result #f])
      (if
        (null? remaining)
        result
        (let ([mapping (car remaining)])
          (if
            (string=? (car mapping) name)
            (if
              (or
                (not result)
                (string=? result (cdr mapping)))
              (loop (cdr remaining) (cdr mapping))
              (assertion-violation
                'scheme-workspace-rename-edits
                "rename has conflicting imported names"
                name result (cdr mapping)))
            (loop (cdr remaining) result))))))

  (define (id-in? id ids)
    (exists
      (lambda (candidate)
        (scheme-definition-id=? id candidate))
      ids))

  (define (resolution-belongs-to-target? resolution ids)
    (and
      (pair? resolution)
      (for-all
        (lambda (id) (id-in? id ids))
        resolution)))

  (define (visible-name-conflict?
            document
            point
            name
            ids)
    (exists
      (lambda (candidate)
        (and
          (string=?
            (scheme-definition-name candidate)
            name)
          (not
            (id-in?
              (scheme-definition-id candidate)
              ids))))
      (scheme-semantic-visible-definitions-at
        (scheme-workspace-document-snapshot document)
        point)))

  (define (declaration-name-conflict?
            document
            definition
            name
            ids)
    (let ([scope
            (find
              (lambda (scope)
                (memq
                  definition
                  (scheme-scope-definitions scope)))
              (scheme-semantic-snapshot-scopes
                (scheme-workspace-document-snapshot document)))])
      (and
        scope
        (exists
          (lambda (candidate)
            (and
              (string=?
                (scheme-definition-name candidate)
                name)
              (not
                (id-in?
                  (scheme-definition-id candidate)
                  ids))))
          (scheme-scope-definitions scope)))))

  (define (same-text-edit? left right)
    (and
      (equal?
        (scheme-workspace-text-edit-buffer-id left)
        (scheme-workspace-text-edit-buffer-id right))
      (equal?
        (scheme-workspace-text-edit-resource left)
        (scheme-workspace-text-edit-resource right))
      (=
        (scheme-workspace-text-edit-start left)
        (scheme-workspace-text-edit-start right))
      (=
        (scheme-workspace-text-edit-end left)
        (scheme-workspace-text-edit-end right))))

  (define (deduplicate-text-edits edits)
    (reverse
      (fold-left
        (lambda (result edit)
          (let ([existing
                  (find
                    (lambda (candidate)
                      (same-text-edit? edit candidate))
                    result)])
            (cond
              [(not existing) (cons edit result)]
              [(string=?
                 (scheme-workspace-text-edit-text existing)
                 (scheme-workspace-text-edit-text edit))
               result]
              [else
               (assertion-violation
                 'scheme-workspace-rename-edits
                 "rename produced conflicting edits"
                 existing edit)])))
        '()
        edits)))

  (define (scheme-workspace-rename-edits
            index
            editor
            definition
            new-name)
    (require-index 'scheme-workspace-rename-edits index)
    (unless (scheme-definition? definition)
      (assertion-violation
        'scheme-workspace-rename-edits
        "expected a Scheme definition"
        definition))
    (unless (string? new-name)
      (assertion-violation
        'scheme-workspace-rename-edits
        "new name must be a string"
        new-name))
    (scheme-workspace-sync-editor! index editor)
    (let* ([id (scheme-definition-id definition)]
           [owner
             (definition-owner-document index definition)])
      (when
        (eq? (scheme-definition-id-source id) 'primitive)
        (assertion-violation
          'scheme-workspace-rename-edits
          "primitive metadata is immutable"
          (scheme-definition-name definition)))
      (unless owner
        (assertion-violation
          'scheme-workspace-rename-edits
          "definition source is outside the editable workspace"
          (scheme-definition-name definition)))
      (let* ([owner-definition
               (or
                 (definition-in-document owner definition)
                 (assertion-violation
                   'scheme-workspace-rename-edits
                   "definition source is stale"
                   definition))]
             [ids
               (equivalent-definition-ids
                 index owner-definition)]
             [old-name
               (scheme-definition-name owner-definition)]
             [library
               (definition-library-name
                 index owner-definition owner)]
             [documents (workspace-documents index)]
             [import-plans
               (make-eq-hashtable)]
             [references
               (scheme-workspace-references
                 index editor owner-definition)])
        (unless
          (string=?
            (document-range-string
              owner
              (scheme-definition-start owner-definition)
              (scheme-definition-end owner-definition))
            old-name)
          (assertion-violation
            'scheme-workspace-rename-edits
            "definition has no explicit declaration spelling"
            old-name))
        (when
          (declaration-name-conflict?
            owner owner-definition new-name ids)
          (assertion-violation
            'scheme-workspace-rename-edits
            "new name conflicts in the definition scope"
            new-name))
        (when library
          (for-each
            (lambda (document)
              (hashtable-set!
                import-plans
                document
                (scheme-semantic-import-rename-plan
                  (scheme-workspace-document-snapshot document)
                  library
                  old-name
                  new-name)))
            documents))
        (let ([edits
                (list
                  (document-text-edit
                    owner
                    (scheme-definition-start owner-definition)
                    (scheme-definition-end owner-definition)
                    new-name))])
          (when library
            (set! edits
              (append
                edits
                (map
                  (lambda (replacement)
                    (replacement-text-edit owner replacement))
                  (scheme-semantic-export-rename-replacements
                    (scheme-workspace-document-snapshot owner)
                    old-name
                    new-name))))
            (for-each
              (lambda (document)
                (set! edits
                  (append
                    edits
                    (map
                      (lambda (replacement)
                        (replacement-text-edit
                          document replacement))
                      (scheme-import-rename-plan-replacements
                        (hashtable-ref
                          import-plans document #f))))))
              documents))
          (for-each
            (lambda (reference)
              (let* ([document
                       (or
                         (document-for-reference
                           index reference)
                         (assertion-violation
                           'scheme-workspace-rename-edits
                           "reference source is stale"
                           reference))]
                     [use
                       (scheme-workspace-reference-use reference)]
                     [replacement
                       (if
                         (or
                           (not library)
                           (eq? document owner))
                         new-name
                         (mapping-ref
                           (scheme-import-rename-plan-mappings
                             (hashtable-ref
                               import-plans document #f))
                           (scheme-use-name use)))])
                (unless
                  (resolution-belongs-to-target?
                    (scheme-use-resolution use)
                    ids)
                  (assertion-violation
                    'scheme-workspace-rename-edits
                    "reference resolution is ambiguous"
                    (scheme-use-name use)))
                (unless replacement
                  (assertion-violation
                    'scheme-workspace-rename-edits
                    "cannot map imported reference to its renamed binding"
                    (scheme-use-name use)))
                (unless
                  (string=? replacement (scheme-use-name use))
                  (when
                    (visible-name-conflict?
                      document
                      (scheme-use-start use)
                      replacement
                      ids)
                    (assertion-violation
                      'scheme-workspace-rename-edits
                      "new name conflicts at a reference"
                      replacement))
                  (set! edits
                    (cons
                      (document-text-edit
                        document
                        (scheme-use-start use)
                        (scheme-use-end use)
                        replacement)
                      edits)))))
            references)
          (deduplicate-text-edits edits)))))

  (define (document-symbol document definition)
    (let ([buffer-id
            (scheme-workspace-document-buffer-id document)]
          [revision
            (scheme-workspace-document-revision document)]
          [resource
            (scheme-workspace-document-resource document)])
      (make-scheme-workspace-symbol
        (if
          buffer-id
          (list
            'buffer
            buffer-id
            revision
            (scheme-definition-start definition)
            (scheme-definition-name definition))
          (list
            'resource
            resource
            revision
            (scheme-definition-start definition)
            (scheme-definition-name definition)))
        (scheme-definition-name definition)
        (scheme-definition-kind definition)
        buffer-id
        resource
        revision
        (scheme-definition-start definition)
        (scheme-definition-end definition)
        definition)))

  (define (index-symbol definition)
    (let* ([id (scheme-definition-id definition)]
           [resource
             (scheme-definition-id-document-id id)])
      (make-scheme-workspace-symbol
        (list
          'resource
          resource
          (scheme-definition-start definition)
          (scheme-definition-name definition))
        (scheme-definition-name definition)
        (scheme-definition-kind definition)
        #f
        resource
        #f
        (scheme-definition-start definition)
        (scheme-definition-end definition)
        definition)))

  (define (symbol-source-key symbol)
    (let ([resource
            (scheme-workspace-symbol-resource symbol)])
      (if
        (string? resource)
        (list
          resource
          (scheme-workspace-symbol-start symbol)
          (scheme-workspace-symbol-name symbol))
        (scheme-workspace-symbol-key symbol))))

  (define (deduplicate-symbols symbols)
    (let ([seen (make-hashtable equal-hash equal?)])
      (fold-left
        (lambda (result symbol)
          (let ([key (symbol-source-key symbol)])
            (if
              (hashtable-contains? seen key)
              result
              (begin
                (hashtable-set! seen key #t)
                (cons symbol result)))))
        '()
        symbols)))

  (define (symbol-before? left right)
    (let ([left-name
            (scheme-workspace-symbol-name left)]
          [right-name
            (scheme-workspace-symbol-name right)])
      (or
        (string<? left-name right-name)
        (and
          (string=? left-name right-name)
          (<
            (scheme-workspace-symbol-start left)
            (scheme-workspace-symbol-start right))))))

  (define (document-symbol-before? left right)
    (or
      (<
        (scheme-workspace-symbol-start left)
        (scheme-workspace-symbol-start right))
      (and
        (=
          (scheme-workspace-symbol-start left)
          (scheme-workspace-symbol-start right))
        (string<?
          (scheme-workspace-symbol-name left)
          (scheme-workspace-symbol-name right)))))

  (define (scheme-workspace-document-symbols
            index
            editor
            buffer)
    (require-index
      'scheme-workspace-document-symbols
      index)
    (unless (buffer? buffer)
      (assertion-violation
        'scheme-workspace-document-symbols
        "expected a buffer"
        buffer))
    (scheme-workspace-sync-editor! index editor)
    (let ([document
            (hashtable-ref
              (scheme-workspace-index-documents index)
              (buffer-id buffer)
              #f)])
      (if
        (not document)
        '()
        (list-sort
          document-symbol-before?
          (map
            (lambda (definition)
              (document-symbol document definition))
            (scheme-semantic-snapshot-root-definitions
              (scheme-workspace-document-snapshot
                document)))))))

  (define (scheme-workspace-symbols index editor)
    (require-index 'scheme-workspace-symbols index)
    (scheme-workspace-sync-editor! index editor)
    (let* ([documents (workspace-documents index)]
           [open-resources
             (let ([resources
                     (make-hashtable
                       string-hash
                       string=?)])
               (for-each
                 (lambda (document)
                   (let ([resource
                           (scheme-workspace-document-resource
                             document)])
                     (when
                       (and
                         (scheme-workspace-document-buffer-id
                           document)
                         (string? resource))
                       (hashtable-set!
                         resources
                         resource
                         #t))))
                 documents)
               resources)]
           [document-symbols
             (apply
               append
               (map
                 (lambda (document)
                   (map
                     (lambda (definition)
                       (document-symbol document definition))
                     (scheme-semantic-snapshot-root-definitions
                       (scheme-workspace-document-snapshot
                         document))))
                 (filter
                   (lambda (document)
                     (let ([resource
                             (scheme-workspace-document-resource
                               document)])
                       (or
                         (scheme-workspace-document-buffer-id
                           document)
                         (not (string? resource))
                         (not
                           (hashtable-contains?
                             open-resources
                             resource)))))
                   documents)))]
           [index-symbols
             (map
               index-symbol
               (filter
                 (lambda (definition)
                   (let* ([id
                            (scheme-definition-id definition)]
                          [resource
                            (scheme-definition-id-document-id id)])
                     (and
                       (integer?
                         (scheme-definition-start definition))
                       (integer?
                         (scheme-definition-end definition))
                       (or
                         (not (string? resource))
                         (not
                           (hashtable-contains?
                             open-resources
                             resource))))))
                 scheme-index-definitions))])
      (list-sort
        symbol-before?
        (deduplicate-symbols
          (append
            document-symbols
            index-symbols))))))
