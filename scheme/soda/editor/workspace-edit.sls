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
          workspace-text-edits-apply!
          editor-undo-workspace-edit!
          editor-redo-workspace-edit!)
  (import (rnrs)
          (soda editor contract)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda document)
          (soda editor buffer)
          (soda editor state))

  (define-record-type workspace-undo-entry
    (fields buffer-id before after))

  (define-record-type
    (workspace-undo-group
      make-workspace-undo-group
      workspace-undo-group?)
    (fields entries
            (mutable state
                     workspace-undo-group-state
                     workspace-undo-group-state-set!)))

  (define editor-workspace-undo-groups (make-weak-eq-hashtable))
  (define workspace-undo-history-limit 64)

  (define-record-type
    (workspace-text-edit %make-workspace-text-edit workspace-text-edit?)
    (fields resource revision start end text))

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

  (define (take values limit)
    (if (or (zero? limit) (null? values))
        '()
        (cons (car values) (take (cdr values) (- limit 1)))))

  (define (record-workspace-undo-group!
            editor buffer-ids undo-positions)
    (when (> (vector-length buffer-ids) 1)
      (let ([entries
              (let loop ([index 0] [result '()])
                (if (= index (vector-length buffer-ids))
                    (reverse result)
                    (let* ([buffer-id (vector-ref buffer-ids index)]
                           [buffer (editor-buffer-ref editor buffer-id)])
                      (loop
                        (+ index 1)
                        (cons
                          (make-workspace-undo-entry
                            buffer-id
                            (hashtable-ref undo-positions buffer-id #f)
                            (document-undo-position
                              (buffer-document buffer)))
                          result)))))])
        (hashtable-set!
          editor-workspace-undo-groups
          editor
          (take
            (cons
              (make-workspace-undo-group entries 'applied)
              (hashtable-ref editor-workspace-undo-groups editor '()))
            workspace-undo-history-limit)))))

  (define (live-entry-buffer editor entry)
    (guard (condition [else #f])
      (editor-buffer-ref editor (workspace-undo-entry-buffer-id entry))))

  (define (group-contains-buffer? group buffer)
    (exists
      (lambda (entry)
        (= (workspace-undo-entry-buffer-id entry) (buffer-id buffer)))
      (workspace-undo-group-entries group)))

  (define (group-at-position? editor group accessor)
    (for-all
      (lambda (entry)
        (let ([buffer (live-entry-buffer editor entry)])
          (and
            buffer
            (=
              (document-undo-position (buffer-document buffer))
              (accessor entry)))))
      (workspace-undo-group-entries group)))

  (define (matching-workspace-undo-group editor buffer state accessor)
    (find
      (lambda (group)
        (and
          (eq? (workspace-undo-group-state group) state)
          (group-contains-buffer? group buffer)
          (group-at-position? editor group accessor)))
      (hashtable-ref editor-workspace-undo-groups editor '())))

  (define (close-change! change)
    (when change (change-close! change)))

  (define (undo-workspace-group! editor group)
    (let ([committed '()])
      (guard
        (condition
          [else
           (for-each
             (lambda (entry)
               (close-change!
                 (buffer-redo! (live-entry-buffer editor entry))))
             committed)
           (raise condition)])
        (for-each
          (lambda (entry)
            (close-change!
              (buffer-undo-to!
                (live-entry-buffer editor entry)
                (workspace-undo-entry-before entry)))
            (set! committed (cons entry committed)))
          (workspace-undo-group-entries group)))
      (workspace-undo-group-state-set! group 'undone)
      (editor-invalidate! editor 'document)
      #t))

  (define (redo-workspace-group! editor group)
    (let ([committed '()])
      (guard
        (condition
          [else
           (for-each
             (lambda (entry)
               (close-change!
                 (buffer-undo-to!
                   (live-entry-buffer editor entry)
                   (workspace-undo-entry-before entry))))
             committed)
           (raise condition)])
        (for-each
          (lambda (entry)
            (let ([change
                    (buffer-redo! (live-entry-buffer editor entry))])
              (unless change
                (assertion-violation
                  'editor-redo-workspace-edit!
                  "workspace edit redo branch is unavailable"
                  (workspace-undo-entry-buffer-id entry)))
              (close-change! change)
              (set! committed (cons entry committed))))
          (workspace-undo-group-entries group)))
      (workspace-undo-group-state-set! group 'applied)
      (editor-invalidate! editor 'document)
      #t))

  (define (editor-undo-workspace-edit! editor buffer)
    (unless (and (editor? editor) (buffer? buffer))
      (assertion-violation
        'editor-undo-workspace-edit!
        "expected an Editor and Buffer"
        editor buffer))
    (let ([group
            (matching-workspace-undo-group
              editor buffer 'applied workspace-undo-entry-after)])
      (and group (undo-workspace-group! editor group))))

  (define (editor-redo-workspace-edit! editor buffer)
    (unless (and (editor? editor) (buffer? buffer))
      (assertion-violation
        'editor-redo-workspace-edit!
        "expected an Editor and Buffer"
        editor buffer))
    (let ([group
            (matching-workspace-undo-group
              editor buffer 'undone workspace-undo-entry-before)])
      (and group (redo-workspace-group! editor group))))

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
              (commit (+ index 1)))))
        (record-workspace-undo-group!
          editor buffer-ids undo-positions))
    (editor-invalidate! editor 'document)
    (length edits))
))
