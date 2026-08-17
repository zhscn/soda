(library (soda packages base history)
  (export make-history!
          history?
          history-mark-saved!
          history-modified?
          history-discard-buffer!)
  (import (rnrs)
          (soda kernel change) (soda kernel document) (soda kernel extension) (soda kernel state)
          (soda host command)
          (soda host dispatch) (soda host package)
          (soda host package-context)
          (soda host value))
  (define-record-type history-entry (fields undo redo semantic invocation-id))
  (define-record-type history
    (fields undo redo saved publish-modified!
            (mutable registration history-registration history-registration-set!)))
  (define (stack-ref table id) (hashtable-ref table id '()))

  (define (buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  ;; A save point is the persistent undo-stack value at which the resource was
  ;; last synchronized.  Transactions retain their tail, so undo and redo can
  ;; return to the same save point without assigning document-specific state
  ;; to the kernel.
  (define (history-mark-saved! value buffer-id)
    (unless (and (history? value) (buffer-id? buffer-id))
      (assertion-violation 'history-mark-saved! "expected a history and Buffer id" value buffer-id))
    (hashtable-set! (history-saved value) buffer-id (stack-ref (history-undo value) buffer-id))
    ((history-publish-modified! value) buffer-id #f)
    #t)

  (define (history-modified? value buffer-id)
    (unless (and (history? value) (buffer-id? buffer-id))
      (assertion-violation 'history-modified? "expected a history and Buffer id" value buffer-id))
    (and (hashtable-contains? (history-saved value) buffer-id)
         (not (eq? (hashtable-ref (history-saved value) buffer-id #f)
                   (stack-ref (history-undo value) buffer-id)))))

  (define (history-discard-buffer! value buffer-id)
    (unless (and (history? value) (buffer-id? buffer-id))
      (assertion-violation 'history-discard-buffer! "expected a history and Buffer id" value buffer-id))
    (hashtable-set! (history-undo value) buffer-id '())
    (hashtable-set! (history-redo value) buffer-id '())
    (history-mark-saved! value buffer-id))
  (define (inverse update)
    (let ([changes (editor-update-changes update)]
          [old (editor-update-old-buffer-state update)])
      ;; ChangeSet owns the string/bytevector normalization and multi-range
      ;; coordinate mapping.  History must not reconstruct that protocol.
      (change-set-invert changes (snapshot-bytevector (buffer-state-document old)))))

  (define (annotation-ref annotations key default)
    (let ([entry (find (lambda (item) (eq? (annotation-key item) key)) annotations)])
      (if entry (annotation-value entry) default)))

  (define (push-update! value update)
    (let* ([id (editor-update-buffer-id update)]
           [annotations (editor-update-annotations update)]
           [policy (annotation-ref annotations 'command.undo-policy 'boundary)]
           [semantic (annotation-ref annotations 'command.semantic #f)]
           [invocation-id (annotation-ref annotations 'command.invocation-id #f)]
           [items (stack-ref (history-undo value) id)]
           [current-undo (inverse update)]
           [current-redo (editor-update-changes update)]
           [merge?
            (and (pair? items)
                 ;; A save point is also an undo boundary: amalgamating by
                 ;; replacing its head would make undo skip the saved text.
                 (not (and (hashtable-contains? (history-saved value) id)
                           (eq? items (hashtable-ref (history-saved value) id #f))))
                 (or (and invocation-id
                          (equal? invocation-id
                                  (history-entry-invocation-id (car items))))
                     (and (eq? policy 'amalgamate) semantic
                          (eq? semantic (history-entry-semantic (car items))))))])
      (unless (eq? policy 'ignore)
        (unless (hashtable-contains? (history-saved value) id)
          (history-mark-saved! value id))
        (hashtable-set!
          (history-undo value) id
          (if merge?
              (cons
                (make-history-entry
                  (change-set-compose current-undo (history-entry-undo (car items)))
                  (change-set-compose (history-entry-redo (car items)) current-redo)
                  semantic invocation-id)
                (cdr items))
              (cons (make-history-entry current-undo current-redo semantic invocation-id)
                    items)))
        (hashtable-set! (history-redo value) id '()))
      ((history-publish-modified! value) id (history-modified? value id))))
  (define (replay context changes)
    (make-transaction-spec (command-context-buffer-id context) (command-context-view-id context)
                           (buffer-state-generation (command-context-buffer-state context))
                           changes #f '() (list (make-annotation 'history.replay #t)) #f #f))
  (define (install-history-command! package-context name doc procedure)
    (package-context-register-command!
      package-context
      (make-command-definition
        name procedure (package-context-owner package-context) doc 'history #f)))

  (define (history-package-context host context-or-owner)
    (cond
      [(and (package-context? context-or-owner)
            (package-context-host? context-or-owner host))
       context-or-owner]
      [(owner? context-or-owner)
       ;; Host-internal callers can retain the historical constructor shape
       ;; while every registration still enters through PackageContext.
       (make-package-context host context-or-owner)]
      [else
       (assertion-violation 'make-history!
                            "expected a PackageContext or Owner"
                            context-or-owner)]))

  (define make-history!
    (case-lambda
      [(host context-or-owner)
       (make-history! host context-or-owner (lambda (buffer-id modified?) #f))]
      [(host context-or-owner publish-modified!)
       (unless (procedure? publish-modified!)
         (assertion-violation 'make-history! "expected a presentation publisher"
                              publish-modified!))
       (let* ([package-context (history-package-context host context-or-owner)]
              [owner (package-context-owner package-context)]
              [value (make-history (make-eqv-hashtable) (make-eqv-hashtable)
                                   (make-eqv-hashtable) publish-modified! #f)])
      (history-registration-set! value
        (package-host-add-update-listener! host owner
          (lambda (update)
            (let ([id (editor-update-buffer-id update)])
              (unless (exists (lambda (a) (eq? (annotation-key a) 'history.replay))
                              (editor-update-annotations update))
                (unless (change-set-empty? (editor-update-changes update))
                  (push-update! value update)))))))
      (install-history-command! package-context
                                'history.undo "Undo the last Buffer transaction."
        (lambda (context)
          (let* ([id (command-context-buffer-id context)] [items (stack-ref (history-undo value) id)])
            (if (null? items) (command-handled)
                (begin
                  (hashtable-set! (history-undo value) id (cdr items))
                  (hashtable-set! (history-redo value) id
                                  (cons (car items) (stack-ref (history-redo value) id)))
                  ((history-publish-modified! value) id
                   (history-modified? value id))
                  (replay context (history-entry-undo (car items))))))))
      (install-history-command! package-context
                                'history.redo "Redo the next Buffer transaction."
        (lambda (context)
          (let* ([id (command-context-buffer-id context)] [items (stack-ref (history-redo value) id)])
            (if (null? items) (command-handled)
                (begin
                  (hashtable-set! (history-redo value) id (cdr items))
                  (hashtable-set! (history-undo value) id
                                  (cons (car items) (stack-ref (history-undo value) id)))
                  ((history-publish-modified! value) id
                   (history-modified? value id))
                  (replay context (history-entry-redo (car items))))))))
         value)]))
)
