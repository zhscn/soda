(library (soda editor workspace-edit)
  (export make-workspace-text-edit
          workspace-text-edit?
          workspace-text-edit-resource
          workspace-text-edit-revision
          workspace-text-edit-start
          workspace-text-edit-end
          workspace-text-edit-text
          workspace-text-edits-missing-resources
          workspace-text-edits-validation-error
          workspace-text-edits-apply!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor state))

  (define-record-type
    (workspace-text-edit %make-workspace-text-edit workspace-text-edit?)
    (fields resource revision start end text))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-workspace-text-edit resource revision start end text)
    (unless (and (string? resource)
                 (positive? (string-length resource))
                 (exact-non-negative-integer? revision)
                 (exact-non-negative-integer? start)
                 (exact-non-negative-integer? end)
                 (<= start end)
                 (string? text))
      (assertion-violation
        'make-workspace-text-edit
        "workspace text edit is invalid"
        resource revision start end text))
    (%make-workspace-text-edit resource revision start end text))

  (define (workspace-text-edits-missing-resources editor edits)
    (unless (and (list? edits) (for-all workspace-text-edit? edits))
      (assertion-violation
        'workspace-text-edits-missing-resources
        "expected workspace text edits"
        edits))
    (reverse
      (fold-left
        (lambda (resources edit)
          (let ([resource (workspace-text-edit-resource edit)])
            (if (or (editor-buffer-for-resource editor resource)
                    (member resource resources))
                resources
                (cons resource resources))))
        '()
        edits)))

  (define (edit-before? left right)
    (> (workspace-text-edit-start left) (workspace-text-edit-start right)))

  (define (buffer-edits-validation-error buffer edits)
    (let ([revision (workspace-text-edit-revision (car edits))])
      (cond
        [(not (= (buffer-revision buffer) revision))
         "workspace edit target changed"]
        [(not
           (for-all
             (lambda (edit)
               (= (workspace-text-edit-revision edit)
                  (buffer-revision buffer)))
             edits))
         "workspace edit group has inconsistent revisions"]
        [(buffer-setting-ref buffer 'read-only? #f)
         "workspace edit target is read-only"]
        [else
         (let loop ([ordered (list-sort edit-before? edits)])
           (if (pair? (cdr ordered))
               (let ([later (car ordered)] [earlier (cadr ordered)])
                 (if (or (> (workspace-text-edit-end earlier)
                            (workspace-text-edit-start later))
                         (= (workspace-text-edit-start earlier)
                            (workspace-text-edit-start later)))
                     "workspace edits overlap"
                     (loop (cdr ordered))))
               #f))])))

  (define (validate-edits! buffer edits)
    (let ([message (buffer-edits-validation-error buffer edits)])
      (when message
        (assertion-violation
          'workspace-text-edits-apply!
          message
          (buffer-resource buffer)))))

  (define (group-edits editor edits)
    (let ([groups (make-eqv-hashtable)])
      (for-each
        (lambda (edit)
          (let ([buffer
                  (editor-buffer-for-resource
                    editor (workspace-text-edit-resource edit))])
            (unless buffer
              (assertion-violation
                'workspace-text-edits-apply!
                "workspace edit target is not open"
                (workspace-text-edit-resource edit)))
            (hashtable-set!
              groups
              (buffer-id buffer)
              (cons edit (hashtable-ref groups (buffer-id buffer) '())))))
        edits)
      groups))

  (define (workspace-text-edits-validation-error editor edits)
    (unless (and (editor? editor)
                 (list? edits) (pair? edits)
                 (for-all workspace-text-edit? edits))
      (assertion-violation
        'workspace-text-edits-validation-error
        "expected an Editor and non-empty workspace text edits"
        editor edits))
    (let ([missing (workspace-text-edits-missing-resources editor edits)])
      (if (pair? missing)
          (string-append
            "workspace edit target is not open: " (car missing))
          (let ([groups (group-edits editor edits)])
            (let-values ([(buffer-ids edit-vectors)
                          (hashtable-entries groups)])
              (let loop ([index 0])
                (if (= index (vector-length buffer-ids))
                    #f
                    (let* ([buffer
                             (editor-buffer-ref
                               editor (vector-ref buffer-ids index))]
                           [message
                             (buffer-edits-validation-error
                               buffer (vector-ref edit-vectors index))])
                      (if message
                          (string-append
                            message ": " (buffer-resource buffer))
                          (loop (+ index 1)))))))))))

  (define (apply-buffer-edits! buffer edits)
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (for-each
                    (lambda (edit)
                      (transaction-replace!
                        transaction
                        (workspace-text-edit-start edit)
                        (workspace-text-edit-end edit)
                        (string->utf8 (workspace-text-edit-text edit))))
                    (list-sort edit-before? edits)))))
            (lambda (result committed-change) (set! change committed-change))))
        (lambda () (when change (change-close! change))))))

  (define (workspace-text-edits-apply! editor edits)
    (unless (and (list? edits) (pair? edits)
                 (for-all workspace-text-edit? edits))
      (assertion-violation
        'workspace-text-edits-apply!
        "expected a non-empty list of workspace text edits"
        edits))
    (let ([groups (group-edits editor edits)]
          [undo-positions (make-eqv-hashtable)]
          [committed '()])
      (let-values ([(buffer-ids edit-vectors) (hashtable-entries groups)])
        (let validate ([index 0])
          (when (< index (vector-length buffer-ids))
            (let* ([buffer-id (vector-ref buffer-ids index)]
                   [buffer (editor-buffer-ref editor buffer-id)]
                   [buffer-edits (vector-ref edit-vectors index)])
              (validate-edits! buffer buffer-edits)
              (hashtable-set!
                undo-positions buffer-id
                (document-undo-position (buffer-document buffer))))
            (validate (+ index 1))))
        (guard
          (condition
            [else
             (for-each
               (lambda (buffer-id)
                 (guard (rollback-condition [else #f])
                   (buffer-undo-to!
                     (editor-buffer-ref editor buffer-id)
                     (hashtable-ref undo-positions buffer-id #f))))
               committed)
             (raise condition)])
          (let commit ([index 0])
            (when (< index (vector-length buffer-ids))
              (let ([buffer-id (vector-ref buffer-ids index)])
                (apply-buffer-edits!
                  (editor-buffer-ref editor buffer-id)
                  (vector-ref edit-vectors index))
                (set! committed (cons buffer-id committed)))
              (commit (+ index 1))))))
    (editor-invalidate! editor 'document)
    (length edits))
))
